import CoreVideo
import Foundation

#if !targetEnvironment(simulator)
struct VTInterpolationRaster: Equatable {
    let width: Int
    let height: Int
    let format: OSType

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
    private var left = 0
    private var right = 0
    private var top = 0
    private var bottom = 0

    init(_ buffer: CVPixelBuffer) {
        CVPixelBufferGetExtendedPixels(buffer, &left, &right, &top, &bottom)
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

    func accepts(_ buffer: CVPixelBuffer) -> Bool {
        VTInterpolationRaster(buffer) == raster && CVPixelBufferGetIOSurface(buffer) != nil
            && CVPixelBufferIsCompatibleWithAttributes(buffer, compatibilityAttributes)
    }
}

struct VTInterpolationPool {
    let requirements: VTInterpolationBufferRequirements
    private let role: String
    private let pool: CVPixelBufferPool
    private let allocationAttributes: CFDictionary

    init(requirements: VTInterpolationBufferRequirements, role: String, limit: Int) throws {
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, requirements.poolAttributes, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw VTInterpolationFailure(reason: "VT FI \(role) pool failed", detail: "poolCreate=\(status)")
        }
        self.requirements = requirements
        self.role = role
        self.pool = pool
        allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: limit] as CFDictionary
    }

    func allocate() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, allocationAttributes, &buffer
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            throw VTInterpolationFailure(reason: "VT FI \(role) pool busy")
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
    static func copy(from source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        guard VideoFramePairFormat.hasSameStorageFormat(source, destination),
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(destination) == 2 else {
            throw VTInterpolationFailure(reason: "VT FI staging layout incompatible")
        }
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

    private static func copyPlanes(from source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
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
        try copyPlane(0, bytesPerSample: 1, from: source, to: destination)
        try copyPlane(1, bytesPerSample: 2, from: source, to: destination)
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
