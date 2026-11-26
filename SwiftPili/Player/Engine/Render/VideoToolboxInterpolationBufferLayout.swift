import CoreVideo
import Foundation
import Metal

#if !targetEnvironment(simulator)
struct VTInterpolationRaster: Equatable {
    let width: Int
    let height: Int
    let format: OSType

    init(width: Int, height: Int, format: OSType) {
        self.width = width
        self.height = height
        self.format = format
    }

    init(_ buffer: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        format = CVPixelBufferGetPixelFormatType(buffer)
    }

    var description: String { "\(Self.fourCC(format)) \(width)x\(height)" }

    var attributes: [String: Any] {
        [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
    }

    static func fourCC(_ format: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: format >> $0) }
        let hex = "0x\(String(format, radix: 16))"
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return hex }
        return String(bytes: bytes, encoding: .ascii) ?? hex
    }
}

struct VTInterpolationPadding: CustomStringConvertible {
    let left: Int
    let right: Int
    let top: Int
    let bottom: Int

    init(_ buffer: CVPixelBuffer) {
        var left = 0
        var right = 0
        var top = 0
        var bottom = 0
        CVPixelBufferGetExtendedPixels(buffer, &left, &right, &top, &bottom)
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    init(attributes: [String: Any]) {
        left = attributes[kCVPixelBufferExtendedPixelsLeftKey as String] as? Int ?? 0
        right = attributes[kCVPixelBufferExtendedPixelsRightKey as String] as? Int ?? 0
        top = attributes[kCVPixelBufferExtendedPixelsTopKey as String] as? Int ?? 0
        bottom = attributes[kCVPixelBufferExtendedPixelsBottomKey as String] as? Int ?? 0
    }

    var isEmpty: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }
    var description: String { "[l=\(left),r=\(right),t=\(top),b=\(bottom)]" }
}

struct VTInterpolationBufferRequirements {
    private static let formatKey = kCVPixelBufferPixelFormatTypeKey as String

    let raster: VTInterpolationRaster
    let compatibilityAttributes: CFDictionary
    let poolAttributes: CFDictionary
    let padding: VTInterpolationPadding

    static func resolve(
        _ requirements: [String: Any], for raster: VTInterpolationRaster
    ) -> (status: CVReturn, requirements: Self?) {
        var resolved: CFDictionary?
        let candidates = [requirements, raster.attributes] as CFArray
        let status = CVPixelBufferCreateResolvedAttributesDictionary(kCFAllocatorDefault, candidates, &resolved)
        guard status == kCVReturnSuccess, let resolved, var attributes = resolved as? [String: Any],
              formats(attributes).contains(raster.format) else { return (status, nil) }
        let padding = VTInterpolationPadding(attributes: attributes)
        attributes[formatKey] = raster.format
        return (status, Self(
            raster: raster, compatibilityAttributes: resolved,
            poolAttributes: attributes as CFDictionary, padding: padding
        ))
    }

    static func formatsDescription(_ attributes: [String: Any]) -> String {
        let formats = formats(attributes)
        return formats.isEmpty ? "unspecified" : formats.map(VTInterpolationRaster.fourCC).joined(separator: ",")
    }

    private static func formats(_ attributes: [String: Any]) -> [OSType] {
        if let values = attributes[formatKey] as? [NSNumber] { return values.map(\.uint32Value) }
        if let value = attributes[formatKey] as? NSNumber { return [value.uint32Value] }
        return []
    }

    func metalCompatiblePoolAttributes() -> CFDictionary {
        var resolved: CFDictionary?
        let metalAttrs = [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
        let status = CVPixelBufferCreateResolvedAttributesDictionary(
            kCFAllocatorDefault, [poolAttributes, metalAttrs] as CFArray, &resolved
        )
        if status == kCVReturnSuccess, let resolved {
            return resolved
        }
        return poolAttributes
    }

    func accepts(_ buffer: CVPixelBuffer) -> Bool {
        VTInterpolationRaster(buffer) == raster && CVPixelBufferGetIOSurface(buffer) != nil
            && CVPixelBufferIsCompatibleWithAttributes(buffer, compatibilityAttributes)
    }
}

struct VTInterpolationPool {
    let requirements: VTInterpolationBufferRequirements
    private let role: String
    private let pool: CVPixelBufferPool
    private let limit: () -> Int

    init(
        requirements: VTInterpolationBufferRequirements,
        role: String,
        limit: Int,
        metalCompatible: Bool = false
    ) throws {
        try self.init(
            requirements: requirements, role: role, metalCompatible: metalCompatible, dynamicLimit: { limit }
        )
    }

    /// `dynamicLimit` is evaluated per allocation so output pools follow the display lookahead.
    init(
        requirements: VTInterpolationBufferRequirements,
        role: String,
        metalCompatible: Bool = false,
        dynamicLimit: @escaping () -> Int
    ) throws {
        var pool: CVPixelBufferPool?
        var status: CVReturn = kCVReturnError
        if metalCompatible {
            status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, requirements.metalCompatiblePoolAttributes(), &pool
            )
        }
        if status != kCVReturnSuccess || pool == nil {
            pool = nil
            status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, requirements.poolAttributes, &pool)
        }
        guard status == kCVReturnSuccess, let pool else {
            throw VTInterpolationFailure(reason: "VT FI \(role) pool failed", detail: "poolCreate=\(status)")
        }
        self.requirements = requirements
        self.role = role
        self.pool = pool
        limit = dynamicLimit
    }

    func allocate() throws -> CVPixelBuffer {
        let allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: limit()] as CFDictionary
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, allocationAttributes, &buffer
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            throw VTInterpolationFailure(reason: "VT FI \(role) pool busy", preservesReference: true)
        }
        guard status == kCVReturnSuccess, let buffer else {
            throw VTInterpolationFailure(reason: "VT FI \(role) buffer unavailable", detail: "poolAllocate=\(status)")
        }
        guard requirements.accepts(buffer) else {
            throw VTInterpolationFailure(
                reason: "VT FI \(role) buffer incompatible",
                detail: "poolAllocate=0 actual=\(VTInterpolationRaster(buffer).description) " +
                    "padding=\(VTInterpolationPadding(buffer)) requiredPadding=\(requirements.padding) " +
                    "iosurface=\(CVPixelBufferGetIOSurface(buffer) != nil)"
            )
        }
        return buffer
    }
}

enum VTNV12StagingCopy {
    /// Zero-stall GPU NV12 staging copy via `VideoEnhancementMetalContext.shared`, clamp-filling
    /// extended right/bottom padding directly in Metal when exposed by the destination IOSurface
    /// and falling back to CPU `copyPlanes` only when Metal texture mapping is unavailable.
    static func copyAsync(from source: CVPixelBuffer, to destination: CVPixelBuffer) async throws {
        let layout = try validateNV12Layout(from: source, to: destination)
        let srcPadding = VTInterpolationPadding(source)
        let dstPadding = VTInterpolationPadding(destination)

        var copiedOnGPU = false
        var paddingCoveredByGPU = dstPadding.isEmpty

        if srcPadding.left == 0, srcPadding.top == 0,
           CVPixelBufferGetIOSurface(source) != nil,
           CVPixelBufferGetIOSurface(destination) != nil {
            let gpuResult = await copyPlanesGPU(
                from: source, to: destination, layout: layout, dstPadding: dstPadding
            )
            copiedOnGPU = gpuResult.succeeded
            paddingCoveredByGPU = gpuResult.paddingCovered
        }

        if !copiedOnGPU {
            try copyPlanes(from: source, to: destination)
            paddingCoveredByGPU = dstPadding.isEmpty
        }

        if !dstPadding.isEmpty, !paddingCoveredByGPU {
            let status = CVPixelBufferFillExtendedPixels(destination)
            guard status == kCVReturnSuccess else {
                throw VTInterpolationFailure(
                    reason: "VT FI staging padding failed", detail: "fillExtendedPixels=\(status)"
                )
            }
        }
        VideoFramePairFormat.copyInterpretation(from: source, to: destination)
    }

    static func copy(from source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        _ = try validateNV12Layout(from: source, to: destination)
        try copyPlanes(from: source, to: destination)
        if !VTInterpolationPadding(destination).isEmpty {
            let status = CVPixelBufferFillExtendedPixels(destination)
            guard status == kCVReturnSuccess else {
                throw VTInterpolationFailure(
                    reason: "VT FI staging padding failed", detail: "fillExtendedPixels=\(status)"
                )
            }
        }
        VideoFramePairFormat.copyInterpretation(from: source, to: destination)
    }

    private struct NV12Layout {
        let lumaWidth: Int
        let lumaHeight: Int
        let chromaWidth: Int
        let chromaHeight: Int
        let lumaFormat: MTLPixelFormat
        let chromaFormat: MTLPixelFormat
        let bytesPerComponent: Int
    }

    private static func validateNV12Layout(
        from source: CVPixelBuffer, to destination: CVPixelBuffer
    ) throws -> NV12Layout {
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard let planes = MetalNV12PixelConverter.biPlanarFormats(for: pixelFormat),
              VideoFramePairFormat.hasSameStorageFormat(source, destination),
              CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(destination) == 2 else {
            throw VTInterpolationFailure(reason: "VT FI staging layout incompatible")
        }
        let lumaW = CVPixelBufferGetWidthOfPlane(source, 0)
        let lumaH = CVPixelBufferGetHeightOfPlane(source, 0)
        let chromaW = CVPixelBufferGetWidthOfPlane(source, 1)
        let chromaH = CVPixelBufferGetHeightOfPlane(source, 1)
        guard lumaW > 0, lumaH > 0, chromaW > 0, chromaH > 0,
              lumaW == CVPixelBufferGetWidthOfPlane(destination, 0),
              lumaH == CVPixelBufferGetHeightOfPlane(destination, 0),
              chromaW == CVPixelBufferGetWidthOfPlane(destination, 1),
              chromaH == CVPixelBufferGetHeightOfPlane(destination, 1) else {
            throw VTInterpolationFailure(reason: "VT FI staging layout incompatible")
        }
        let bpc = MetalNV12PixelConverter.is10BitBiPlanarYUV(pixelFormat) ? 2 : 1
        return NV12Layout(
            lumaWidth: lumaW, lumaHeight: lumaH,
            chromaWidth: chromaW, chromaHeight: chromaH,
            lumaFormat: planes.luma, chromaFormat: planes.chroma,
            bytesPerComponent: bpc
        )
    }

    private static func copyPlanesGPU(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        layout: NV12Layout,
        dstPadding: VTInterpolationPadding
    ) async -> (succeeded: Bool, paddingCovered: Bool) {
        let metal = VideoEnhancementMetalContext.shared
        guard let resources = try? metal.resources(),
              let commandBuffer = resources.commandQueue.makeCommandBuffer(),
              let srcY = metal.makeTexture(
                buffer: source, format: layout.lumaFormat, width: layout.lumaWidth, height: layout.lumaHeight, plane: 0
              ),
              let srcCbCr = metal.makeTexture(
                buffer: source, format: layout.chromaFormat, width: layout.chromaWidth, height: layout.chromaHeight, plane: 1
              ) else {
            return (false, false)
        }

        // Fast DMA blit when destination has no extended pixels.
        if dstPadding.isEmpty,
           let dstY = metal.makeTexture(
            buffer: destination, format: layout.lumaFormat, width: layout.lumaWidth, height: layout.lumaHeight, plane: 0
           ),
           let dstCbCr = metal.makeTexture(
            buffer: destination, format: layout.chromaFormat, width: layout.chromaWidth, height: layout.chromaHeight, plane: 1
           ),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: srcY.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: layout.lumaWidth, height: layout.lumaHeight, depth: 1),
                to: dstY.texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.copy(
                from: srcCbCr.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: layout.chromaWidth, height: layout.chromaHeight, depth: 1),
                to: dstCbCr.texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            let retained = [srcY.bridge, srcCbCr.bridge, dstY.bridge, dstCbCr.bridge]
            let succeeded = await VideoEnhancementMetalContext.commitAndWait(commandBuffer)
            withExtendedLifetime(retained) {}
            return (succeeded, true)
        }

        // Compute copy + extended right/bottom pixel clamp-fill in a single GPU pass when exposed by IOSurface.
        guard let yPipe = try? metal.pipeline(for: .nv12StageCopyY),
              let cbcrPipe = try? metal.pipeline(for: .nv12StageCopyCbCr) else {
            return (false, false)
        }

        let lumaTarget = VideoEnhancementMetalContext.gpuPaddedPlaneSize(
            for: destination, plane: 0,
            activeWidth: layout.lumaWidth, activeHeight: layout.lumaHeight,
            padLeft: dstPadding.left, padRight: dstPadding.right,
            padTop: dstPadding.top, padBottom: dstPadding.bottom
        )
        let chromaTarget = VideoEnhancementMetalContext.gpuPaddedPlaneSize(
            for: destination, plane: 1,
            activeWidth: layout.chromaWidth, activeHeight: layout.chromaHeight,
            padLeft: dstPadding.left, padRight: dstPadding.right,
            padTop: dstPadding.top, padBottom: dstPadding.bottom
        )

        var dstY: VideoEnhancementMetalContext.MappedTexture?
        var dstCbCr: VideoEnhancementMetalContext.MappedTexture?
        var paddingCovered = false

        if lumaTarget.coversAllPadding, chromaTarget.coversAllPadding,
           let paddedY = metal.makeTexture(
            buffer: destination, format: layout.lumaFormat,
            width: lumaTarget.width, height: lumaTarget.height, plane: 0, usage: .shaderWrite
           ),
           let paddedCbCr = metal.makeTexture(
            buffer: destination, format: layout.chromaFormat,
            width: chromaTarget.width, height: chromaTarget.height, plane: 1, usage: .shaderWrite
           ),
           paddedY.texture.width == lumaTarget.width, paddedY.texture.height == lumaTarget.height,
           paddedCbCr.texture.width == chromaTarget.width, paddedCbCr.texture.height == chromaTarget.height {
            dstY = paddedY
            dstCbCr = paddedCbCr
            paddingCovered = true
        }

        if dstY == nil || dstCbCr == nil {
            dstY = metal.makeTexture(
                buffer: destination, format: layout.lumaFormat,
                width: layout.lumaWidth, height: layout.lumaHeight, plane: 0, usage: .shaderWrite
            )
            dstCbCr = metal.makeTexture(
                buffer: destination, format: layout.chromaFormat,
                width: layout.chromaWidth, height: layout.chromaHeight, plane: 1, usage: .shaderWrite
            )
            paddingCovered = dstPadding.isEmpty
        }

        guard let dstY, let dstCbCr, let compute = commandBuffer.makeComputeCommandEncoder() else {
            return (false, false)
        }

        var yParams = VideoEnhancementNV12StageCopyParams(
            activeWidth: UInt32(layout.lumaWidth),
            activeHeight: UInt32(layout.lumaHeight),
            padLeft: 0,
            padTop: 0
        )
        compute.setComputePipelineState(yPipe)
        compute.setTexture(srcY.texture, index: 0)
        compute.setTexture(dstY.texture, index: 1)
        compute.setBytes(&yParams, length: MemoryLayout<VideoEnhancementNV12StageCopyParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: compute, pipeline: yPipe, width: dstY.texture.width, height: dstY.texture.height
        )

        var cbcrParams = VideoEnhancementNV12StageCopyParams(
            activeWidth: UInt32(layout.chromaWidth),
            activeHeight: UInt32(layout.chromaHeight),
            padLeft: 0,
            padTop: 0
        )
        compute.setComputePipelineState(cbcrPipe)
        compute.setTexture(srcCbCr.texture, index: 0)
        compute.setTexture(dstCbCr.texture, index: 1)
        compute.setBytes(&cbcrParams, length: MemoryLayout<VideoEnhancementNV12StageCopyParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: compute, pipeline: cbcrPipe, width: dstCbCr.texture.width, height: dstCbCr.texture.height
        )
        compute.endEncoding()

        let retained = [srcY.bridge, srcCbCr.bridge, dstY.bridge, dstCbCr.bridge]
        let succeeded = await VideoEnhancementMetalContext.commitAndWait(commandBuffer)
        withExtendedLifetime(retained) {}
        return (succeeded, paddingCovered)
    }

    private static func copyPlanes(from source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        let bpc = MetalNV12PixelConverter.is10BitBiPlanarYUV(CVPixelBufferGetPixelFormatType(source)) ? 2 : 1
        let read = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard read == kCVReturnSuccess else {
            throw VTInterpolationFailure(reason: "VT FI staging read failed", detail: "lock=\(read)")
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let write = CVPixelBufferLockBaseAddress(destination, [])
        guard write == kCVReturnSuccess else {
            throw VTInterpolationFailure(reason: "VT FI staging write failed", detail: "lock=\(write)")
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        try copyPlane(0, bytesPerSample: bpc, from: source, to: destination)
        try copyPlane(1, bytesPerSample: bpc * 2, from: source, to: destination)
    }

    private static func copyPlane(
        _ plane: Int, bytesPerSample: Int, from source: CVPixelBuffer, to destination: CVPixelBuffer
    ) throws {
        let width = CVPixelBufferGetWidthOfPlane(source, plane)
        let height = CVPixelBufferGetHeightOfPlane(source, plane)
        let bytes = width * bytesPerSample
        let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
        guard width > 0, height > 0, width == CVPixelBufferGetWidthOfPlane(destination, plane),
              height == CVPixelBufferGetHeightOfPlane(destination, plane),
              bytes <= min(sourceStride, destinationStride),
              let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
              let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
            throw VTInterpolationFailure(reason: "VT FI staging layout incompatible", detail: "plane=\(plane)")
        }
        for row in 0..<height {
            destinationBase.advanced(by: row * destinationStride).copyMemory(
                from: sourceBase.advanced(by: row * sourceStride), byteCount: bytes
            )
        }
    }
}
#endif
