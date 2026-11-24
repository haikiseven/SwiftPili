import CoreVideo
import Foundation
import Metal
import os
#if canImport(MetalFX)
import MetalFX
#endif

/// Shared GPU pixel-format converter used by both MetalFX Spatial (NV12→BGRA input preparation)
/// and VideoToolbox ML SR (cross-format staging such as 420v/420f→32BGRA and 420f↔420v).
final class MetalNV12PixelConverter {
    deinit {
        tearDown()
    }

    func flush() {
        VideoEnhancementMetalContext.shared.flushTextureCache()
    }

    func tearDown() {
        flush()
    }

    /// Converts `source` into `destination` on the GPU (supports NV12→BGRA, 420f↔420v, and BGRA→BGRA),
    /// clamp-filling destination right/bottom extended pixels on GPU when exposed by IOSurface.
    func convert(from source: CVPixelBuffer, to destination: CVPixelBuffer) async -> Bool {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let metal = VideoEnhancementMetalContext.shared
        guard width > 0, height > 0,
              width == CVPixelBufferGetWidth(destination),
              height == CVPixelBufferGetHeight(destination),
              let resources = try? metal.resources(),
              let commandBuffer = resources.commandQueue.makeCommandBuffer() else {
            return false
        }

        var padLeft = 0
        var padRight = 0
        var padTop = 0
        var padBottom = 0
        CVPixelBufferGetExtendedPixels(destination, &padLeft, &padRight, &padTop, &padBottom)
        let hasPadding = padLeft != 0 || padRight != 0 || padTop != 0 || padBottom != 0

        let srcFormat = CVPixelBufferGetPixelFormatType(source)
        let dstFormat = CVPixelBufferGetPixelFormatType(destination)
        let size = (width, height)
        let retained: [CVMetalTexture]
        let paddingCoveredByGPU: Bool

        if Self.isNV12(srcFormat), dstFormat == kCVPixelFormatType_32BGRA {
            guard let encoded = encodeNV12ToBGRA(
                commandBuffer: commandBuffer, metal: metal,
                source: source, destination: destination, size: size,
                padding: (padLeft, padRight, padTop, padBottom)
            ) else { return false }
            retained = encoded.retained
            paddingCoveredByGPU = encoded.paddingCovered
        } else if Self.isNV12(srcFormat), Self.isNV12(dstFormat), srcFormat != dstFormat {
            guard let encoded = encodeNV12RangeConvert(
                commandBuffer: commandBuffer, metal: metal,
                source: source, destination: destination, size: size,
                fullToVideo: srcFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                padding: (padLeft, padRight, padTop, padBottom)
            ) else { return false }
            retained = encoded.retained
            paddingCoveredByGPU = encoded.paddingCovered
        } else if srcFormat == kCVPixelFormatType_32BGRA, dstFormat == kCVPixelFormatType_32BGRA {
            guard let srcMapped = metal.makeTexture(
                buffer: source, format: .bgra8Unorm, width: width, height: height, plane: 0
            ), let dstMapped = metal.makeTexture(
                buffer: destination, format: .bgra8Unorm, width: width, height: height, plane: 0
            ), let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
            blit.copy(
                from: srcMapped.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: dstMapped.texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            retained = [srcMapped.bridge, dstMapped.bridge]
            paddingCoveredByGPU = !hasPadding
        } else {
            return false
        }

        let succeeded = await VideoEnhancementMetalContext.commitAndWait(commandBuffer)
        withExtendedLifetime(retained) {}
        guard succeeded else { return false }

        if hasPadding, !paddingCoveredByGPU {
            guard CVPixelBufferFillExtendedPixels(destination) == kCVReturnSuccess else {
                return false
            }
        }
        return true
    }

    private func encodeNV12ToBGRA(
        commandBuffer: any MTLCommandBuffer,
        metal: VideoEnhancementMetalContext,
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        size: (Int, Int),
        padding: (left: Int, right: Int, top: Int, bottom: Int)
    ) -> (retained: [CVMetalTexture], paddingCovered: Bool)? {
        guard let nv12ToBGRAPipeline = try? metal.pipeline(for: .nv12ToBGRA) else { return nil }
        let chromaSize = (max(1, size.0 / 2), max(1, size.1 / 2))
        guard let yMapped = metal.makeTexture(
            buffer: source, format: .r8Unorm, width: size.0, height: size.1, plane: 0
        ), let cbcrMapped = metal.makeTexture(
            buffer: source, format: .rg8Unorm, width: chromaSize.0, height: chromaSize.1, plane: 1
        ) else { return nil }

        let target = VideoEnhancementMetalContext.gpuPaddedPlaneSize(
            for: destination, plane: 0, activeWidth: size.0, activeHeight: size.1,
            padLeft: padding.left, padRight: padding.right, padTop: padding.top, padBottom: padding.bottom
        )
        var outMapped: VideoEnhancementMetalContext.MappedTexture?
        var paddingCovered = false
        if target.coversAllPadding,
           let padded = metal.makeTexture(
            buffer: destination, format: .bgra8Unorm, width: target.width, height: target.height,
            plane: 0, usage: .shaderWrite
           ), padded.texture.width == target.width, padded.texture.height == target.height {
            outMapped = padded
            paddingCovered = true
        }
        if outMapped == nil {
            outMapped = metal.makeTexture(
                buffer: destination, format: .bgra8Unorm, width: size.0, height: size.1,
                plane: 0, usage: .shaderWrite
            )
            paddingCovered = padding.left == 0 && padding.right == 0 && padding.top == 0 && padding.bottom == 0
        }

        guard let outMapped, let compute = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        let chromaOffset = Self.chromaOffset(for: source)
        var params = VideoEnhancementNV12ConvertParams(
            fullRange: CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ? 1 : 0,
            colorMatrix: Self.colorMatrixIndex(for: source, width: size.0, height: size.1),
            chromaOffsetX: chromaOffset.0,
            chromaOffsetY: chromaOffset.1
        )
        compute.setComputePipelineState(nv12ToBGRAPipeline)
        compute.setTexture(yMapped.texture, index: 0)
        compute.setTexture(cbcrMapped.texture, index: 1)
        compute.setTexture(outMapped.texture, index: 2)
        compute.setBytes(&params, length: MemoryLayout<VideoEnhancementNV12ConvertParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: compute, pipeline: nv12ToBGRAPipeline,
            width: outMapped.texture.width, height: outMapped.texture.height
        )
        compute.endEncoding()
        return ([yMapped.bridge, cbcrMapped.bridge, outMapped.bridge], paddingCovered)
    }

    private func encodeNV12RangeConvert(
        commandBuffer: any MTLCommandBuffer,
        metal: VideoEnhancementMetalContext,
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        size: (Int, Int),
        fullToVideo: Bool,
        padding: (left: Int, right: Int, top: Int, bottom: Int)
    ) -> (retained: [CVMetalTexture], paddingCovered: Bool)? {
        guard let rangeYPipeline = try? metal.pipeline(for: .nv12RangeConvertY),
              let rangeCbCrPipeline = try? metal.pipeline(for: .nv12RangeConvertCbCr) else {
            return nil
        }
        let chromaSize = (max(1, size.0 / 2), max(1, size.1 / 2))
        guard let srcYMapped = metal.makeTexture(
            buffer: source, format: .r8Unorm, width: size.0, height: size.1, plane: 0
        ), let srcCbCrMapped = metal.makeTexture(
            buffer: source, format: .rg8Unorm, width: chromaSize.0, height: chromaSize.1, plane: 1
        ) else { return nil }

        let lumaTarget = VideoEnhancementMetalContext.gpuPaddedPlaneSize(
            for: destination, plane: 0, activeWidth: size.0, activeHeight: size.1,
            padLeft: padding.left, padRight: padding.right, padTop: padding.top, padBottom: padding.bottom
        )
        let chromaTarget = VideoEnhancementMetalContext.gpuPaddedPlaneSize(
            for: destination, plane: 1, activeWidth: chromaSize.0, activeHeight: chromaSize.1,
            padLeft: padding.left, padRight: padding.right, padTop: padding.top, padBottom: padding.bottom
        )

        var dstYMapped: VideoEnhancementMetalContext.MappedTexture?
        var dstCbCrMapped: VideoEnhancementMetalContext.MappedTexture?
        var paddingCovered = false

        if lumaTarget.coversAllPadding, chromaTarget.coversAllPadding,
           let paddedY = metal.makeTexture(
            buffer: destination, format: .r8Unorm, width: lumaTarget.width, height: lumaTarget.height,
            plane: 0, usage: .shaderWrite
           ),
           let paddedCbCr = metal.makeTexture(
            buffer: destination, format: .rg8Unorm, width: chromaTarget.width, height: chromaTarget.height,
            plane: 1, usage: .shaderWrite
           ),
           paddedY.texture.width == lumaTarget.width, paddedY.texture.height == lumaTarget.height,
           paddedCbCr.texture.width == chromaTarget.width, paddedCbCr.texture.height == chromaTarget.height {
            dstYMapped = paddedY
            dstCbCrMapped = paddedCbCr
            paddingCovered = true
        }

        if dstYMapped == nil || dstCbCrMapped == nil {
            dstYMapped = metal.makeTexture(
                buffer: destination, format: .r8Unorm, width: size.0, height: size.1,
                plane: 0, usage: .shaderWrite
            )
            dstCbCrMapped = metal.makeTexture(
                buffer: destination, format: .rg8Unorm, width: chromaSize.0, height: chromaSize.1,
                plane: 1, usage: .shaderWrite
            )
            paddingCovered = padding.left == 0 && padding.right == 0 && padding.top == 0 && padding.bottom == 0
        }

        guard let dstYMapped, let dstCbCrMapped, let compute = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        var params = VideoEnhancementNV12RangeConvertParams(fullToVideo: fullToVideo ? 1 : 0)
        compute.setComputePipelineState(rangeYPipeline)
        compute.setTexture(srcYMapped.texture, index: 0)
        compute.setTexture(dstYMapped.texture, index: 1)
        compute.setBytes(&params, length: MemoryLayout<VideoEnhancementNV12RangeConvertParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: compute, pipeline: rangeYPipeline,
            width: dstYMapped.texture.width, height: dstYMapped.texture.height
        )

        compute.setComputePipelineState(rangeCbCrPipeline)
        compute.setTexture(srcCbCrMapped.texture, index: 0)
        compute.setTexture(dstCbCrMapped.texture, index: 1)
        compute.setBytes(&params, length: MemoryLayout<VideoEnhancementNV12RangeConvertParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: compute, pipeline: rangeCbCrPipeline,
            width: dstCbCrMapped.texture.width, height: dstCbCrMapped.texture.height
        )
        compute.endEncoding()
        return ([srcYMapped.bridge, srcCbCrMapped.bridge, dstYMapped.bridge, dstCbCrMapped.bridge], paddingCovered)
    }

    static func isNV12(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    static func colorMatrixIndex(for pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> UInt32 {
        if let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) {
            if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
                || CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995) {
                return 1
            }
            if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
                return 2
            }
            if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
                return 0
            }
        }
        return (width <= 720 && height <= 576) ? 1 : 0
    }

    /// Returns luma-grid chroma sampling offset `(offsetX, offsetY)` for normalized sampling
    /// `uv = (float2(gid) + offset) / float2(width, height)`. Defaults to MPEG-2 / H.264 / HEVC / AV1
    /// left-sited 4:2:0 `(1.0, 0.5)` so even luma columns align exactly with chroma texel centers.
    static func chromaOffset(for pixelBuffer: CVPixelBuffer) -> (Float, Float) {
        if let loc = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, nil) {
            if CFEqual(loc, kCVImageBufferChromaLocation_Center) {
                return (0.5, 0.5)
            }
            if CFEqual(loc, kCVImageBufferChromaLocation_TopLeft) {
                return (1.0, 1.0)
            }
            if CFEqual(loc, kCVImageBufferChromaLocation_Top) {
                return (0.5, 1.0)
            }
            if CFEqual(loc, kCVImageBufferChromaLocation_BottomLeft) {
                return (1.0, 0.0)
            }
            if CFEqual(loc, kCVImageBufferChromaLocation_Bottom) {
                return (0.5, 0.0)
            }
        }
        return (1.0, 0.5)
    }

    static func makeCVTexture(
        cache: CVMetalTextureCache,
        buffer: CVPixelBuffer,
        format: MTLPixelFormat,
        size: (Int, Int),
        plane: Int
    ) -> CVMetalTexture? {
        var textureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format, size.0, size.1, plane, &textureOut
        )
        return status == kCVReturnSuccess ? textureOut : nil
    }

    static func dispatchThreads(
        encoder: any MTLComputeCommandEncoder,
        pipeline: any MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: encoder, pipeline: pipeline, width: width, height: height
        )
    }
}

final class MetalFXSuperResolutionBackend {
    private var inputRGBATexture: (any MTLTexture)?
    private var privateOutputTexture: (any MTLTexture)?
    private var outputPool: VideoSuperResolutionPool?
    private var configuredOutput: (width: Int, height: Int)?

    #if canImport(MetalFX)
    private var scaler: (any MTLFXSpatialScaler)?
    #endif

    deinit {
        tearDown()
    }

    func flush() {
        VideoEnhancementMetalContext.shared.flushTextureCache()
    }

    func tearDown() {
        flush()
        #if canImport(MetalFX)
        scaler = nil
        #endif
        inputRGBATexture = nil
        privateOutputTexture = nil
        outputPool = nil
        configuredOutput = nil
    }

    /// - Parameters:
    ///   - maxScale: may be fractional in Auto mode; the caller caps it to the on-screen
    ///     magnification so output never exceeds the display's pixel size.
    ///   - targetDimensions: explicit output dimensions (even, within raster budget) when the user
    ///     configured a manual MetalFX target resolution; bypasses the Auto magnification floor.
    ///   - sharpness: AMD RCAS contrast-adaptive sharpening strength applied during the output pass.
    func upscale(
        pixelBuffer: CVPixelBuffer,
        maxScale: Float = 2,
        targetDimensions: VideoSuperResolutionDimensions? = nil,
        sharpness: VideoSuperResolutionSharpness = .standard
    ) async -> VideoEnhancementBackendOutcome {
        let outcomes = await upscaleBatch(
            pixelBuffers: [pixelBuffer],
            maxScale: maxScale,
            targetDimensions: targetDimensions,
            sharpness: sharpness
        )
        return outcomes.first ?? .bypassed(reason: "MetalFX empty batch")
    }

    /// Upscales a batch of frames (e.g. interpolated midpoints + original) in a single pipelined
    /// GPU submission with zero intermediate CPU round-trips.
    func upscaleBatch(
        pixelBuffers: [CVPixelBuffer],
        maxScale: Float = 2,
        targetDimensions: VideoSuperResolutionDimensions? = nil,
        sharpness: VideoSuperResolutionSharpness = .standard
    ) async -> [VideoEnhancementBackendOutcome] {
        guard !pixelBuffers.isEmpty else { return [] }
        #if !canImport(MetalFX)
        return Array(repeating: .bypassed(reason: "MetalFX unavailable"), count: pixelBuffers.count)
        #else
        let width = CVPixelBufferGetWidth(pixelBuffers[0])
        let height = CVPixelBufferGetHeight(pixelBuffers[0])

        // Defensive fallback if caller ever passes heterogeneous rasters in one batch.
        if pixelBuffers.count > 1,
           pixelBuffers.contains(where: { CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height }) {
            var outcomes: [VideoEnhancementBackendOutcome] = []
            outcomes.reserveCapacity(pixelBuffers.count)
            for buffer in pixelBuffers {
                let single = await upscaleUniformBatch(
                    pixelBuffers: [buffer],
                    width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer),
                    maxScale: maxScale,
                    targetDimensions: targetDimensions,
                    sharpness: sharpness
                )
                outcomes.append(single.first ?? .bypassed(reason: "MetalFX empty batch"))
            }
            return outcomes
        }

        return await upscaleUniformBatch(
            pixelBuffers: pixelBuffers,
            width: width,
            height: height,
            maxScale: maxScale,
            targetDimensions: targetDimensions,
            sharpness: sharpness
        )
        #endif
    }

    private static func evenSize(_ width: Int, _ height: Int, _ scale: Float) -> (Int, Int) {
        func even(_ value: Float) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Float(width) * scale), even(Float(height) * scale))
    }

    #if canImport(MetalFX)
    private struct EncodedFrame {
        let index: Int
        let commandBuffer: any MTLCommandBuffer
        let sourceBuffer: CVPixelBuffer
        let destBuffer: CVPixelBuffer
    }

    private final class BatchCompletionTracker: @unchecked Sendable {
        private struct State {
            var remaining: Int
            var statuses: [Bool]
            var continuation: CheckedContinuation<[Bool], Never>?
        }

        private let lock: OSAllocatedUnfairLock<State>

        init(count: Int) {
            lock = OSAllocatedUnfairLock(initialState: State(
                remaining: count,
                statuses: Array(repeating: false, count: count),
                continuation: nil
            ))
        }

        func markCompleted(slot: Int, succeeded: Bool) {
            let ready: (CheckedContinuation<[Bool], Never>, [Bool])? = lock.withLock { state in
                state.statuses[slot] = succeeded
                state.remaining -= 1
                if state.remaining == 0, let continuation = state.continuation {
                    state.continuation = nil
                    return (continuation, state.statuses)
                }
                return nil
            }
            if let (continuation, statuses) = ready {
                continuation.resume(returning: statuses)
            }
        }

        func awaitAll(commit: () -> Void) async -> [Bool] {
            await withCheckedContinuation { continuation in
                let alreadyFinished: [Bool]? = lock.withLock { state in
                    if state.remaining == 0 {
                        return state.statuses
                    }
                    state.continuation = continuation
                    return nil
                }
                if let alreadyFinished {
                    continuation.resume(returning: alreadyFinished)
                    return
                }
                commit()
            }
        }
    }

    private func upscaleUniformBatch(
        pixelBuffers: [CVPixelBuffer],
        width: Int,
        height: Int,
        maxScale: Float,
        targetDimensions: VideoSuperResolutionDimensions?,
        sharpness: VideoSuperResolutionSharpness
    ) async -> [VideoEnhancementBackendOutcome] {
        func bypassAll(_ reason: String) -> [VideoEnhancementBackendOutcome] {
            Array(repeating: .bypassed(reason: reason), count: pixelBuffers.count)
        }

        let output: (Int, Int)
        if let targetDimensions {
            guard targetDimensions.width > width, targetDimensions.height > height else {
                return bypassAll("Target resolution reached")
            }
            guard VideoSuperResolutionRasterBudget.contains(width: width, height: height),
                  VideoSuperResolutionRasterBudget.contains(
                    width: targetDimensions.width, height: targetDimensions.height
                  ) else {
                return bypassAll("MetalFX output exceeds raster budget")
            }
            output = (targetDimensions.width, targetDimensions.height)
        } else {
            guard maxScale.isFinite, maxScale >= VideoEnhancementDisplaySurface.minimumUsefulMagnification else {
                return bypassAll("Display resolution reached")
            }
            let scale = min(maxScale, 4)
            let candidates = [Self.evenSize(width, height, scale)]
                + [4, 3, 2].filter { Float($0) < scale }.map { (width * $0, height * $0) }
            guard VideoSuperResolutionRasterBudget.contains(width: width, height: height),
                  let resolved = candidates.first(where: {
                      VideoSuperResolutionRasterBudget.contains(width: $0.0, height: $0.1)
                  }) else {
                return bypassAll("MetalFX output exceeds raster budget")
            }
            output = resolved
        }

        let metal = VideoEnhancementMetalContext.shared
        let resources: VideoEnhancementMetalContext.Resources
        let convertPipeline: any MTLComputePipelineState
        let rcasPipeline: any MTLComputePipelineState
        do {
            resources = try metal.resources()
            guard MTLFXSpatialScalerDescriptor.supportsDevice(resources.device) else {
                return bypassAll("MetalFX unsupported")
            }
            convertPipeline = try metal.pipeline(for: .nv12ToBGRA)
            rcasPipeline = try metal.pipeline(for: .rcasSharpen)
        } catch {
            return bypassAll(error.stage)
        }

        if scaler?.inputWidth != width || scaler?.inputHeight != height
            || configuredOutput?.width != output.0 || configuredOutput?.height != output.1,
           let configReason = configureScaler(device: resources.device, width: width, height: height, output: output) {
            return bypassAll(configReason)
        }

        guard let outputPool, let scaler else {
            return bypassAll("MetalFX not configured")
        }

        let outSize = (scaler.outputWidth, scaler.outputHeight)
        var outcomes = Array<VideoEnhancementBackendOutcome>(
            repeating: .bypassed(reason: "MetalFX GPU error"),
            count: pixelBuffers.count
        )
        var pending: [EncodedFrame] = []
        pending.reserveCapacity(pixelBuffers.count)
        var retainedTextures: [CVMetalTexture] = []
        retainedTextures.reserveCapacity(pixelBuffers.count * 3)

        for (index, pixelBuffer) in pixelBuffers.enumerated() {
            let destBuffer: CVPixelBuffer
            do throws(VideoSuperResolutionPool.Failure) {
                destBuffer = try outputPool.allocate()
            } catch {
                outcomes[index] = .bypassed(reason: error.isBusy ? error.reason : "BGRA output alloc failed")
                continue
            }
            guard let outputMapped = metal.makeTexture(
                buffer: destBuffer, format: .bgra8Unorm, width: outSize.0, height: outSize.1, plane: 0
            ) else {
                outcomes[index] = .bypassed(reason: "Output Metal texture failed")
                continue
            }
            guard let commandBuffer = resources.commandQueue.makeCommandBuffer() else {
                outcomes[index] = .bypassed(reason: "MetalFX command buffer failed")
                continue
            }
            guard let retainedInputs = encodeInputToBGRA(
                commandBuffer: commandBuffer,
                metal: metal,
                convertPipeline: convertPipeline,
                pixelBuffer: pixelBuffer,
                size: (width, height)
            ) else {
                outcomes[index] = .bypassed(reason: "Input texture bind failed")
                continue
            }
            guard encodeScaleAndOutput(
                commandBuffer: commandBuffer,
                scaler: scaler,
                rcasPipeline: rcasPipeline,
                inputSize: (width, height),
                outputSize: outSize,
                destination: outputMapped.texture,
                sharpness: sharpness
            ) else {
                outcomes[index] = .bypassed(reason: "MetalFX encode failed")
                continue
            }
            retainedTextures.append(contentsOf: retainedInputs)
            retainedTextures.append(outputMapped.bridge)
            pending.append(EncodedFrame(
                index: index,
                commandBuffer: commandBuffer,
                sourceBuffer: pixelBuffer,
                destBuffer: destBuffer
            ))
        }

        guard !pending.isEmpty else { return outcomes }

        // Commit all command buffers back-to-back on the shared serial queue and suspend only ONCE.
        let statuses: [Bool]
        if pending.count == 1 {
            let ok = await VideoEnhancementMetalContext.commitAndWait(pending[0].commandBuffer)
            statuses = [ok]
        } else {
            let tracker = BatchCompletionTracker(count: pending.count)
            statuses = await tracker.awaitAll {
                for (slot, item) in pending.enumerated() {
                    item.commandBuffer.addCompletedHandler { buffer in
                        tracker.markCompleted(slot: slot, succeeded: buffer.status == .completed)
                    }
                    item.commandBuffer.commit()
                }
            }
        }
        withExtendedLifetime(retainedTextures) {}

        for (slot, item) in pending.enumerated() {
            if statuses[slot] {
                ScaledVideoOutputMetadata.copy(from: item.sourceBuffer, to: item.destBuffer, colorSpace: .rgbConverted)
                outcomes[item.index] = .processed(item.destBuffer)
            } else {
                outcomes[item.index] = .bypassed(reason: "MetalFX GPU error")
            }
        }
        return outcomes
    }

    private func configureScaler(device: any MTLDevice, width: Int, height: Int, output: (Int, Int)) -> String? {
        guard let createdScaler = Self.makeScaler(
            device: device, width: width, height: height, output: output
        ) else {
            return "MetalFX scaler init failed"
        }
        let outWidth = createdScaler.outputWidth
        let outHeight = createdScaler.outputHeight

        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        inputDesc.storageMode = .private
        inputDesc.usage = createdScaler.colorTextureUsage.union([.shaderWrite, .shaderRead])

        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outWidth, height: outHeight, mipmapped: false
        )
        outputDesc.storageMode = .private
        outputDesc.usage = createdScaler.outputTextureUsage.union([.shaderRead])

        guard let inTex = device.makeTexture(descriptor: inputDesc),
              let outTex = device.makeTexture(descriptor: outputDesc),
              let pool = Self.makeBGRAOutputPool(width: outWidth, height: outHeight) else {
            return "MetalFX textures alloc failed"
        }

        scaler = createdScaler
        inputRGBATexture = inTex
        privateOutputTexture = outTex
        outputPool = pool
        configuredOutput = output
        return nil
    }

    private static func makeScaler(
        device: any MTLDevice, width: Int, height: Int, output: (Int, Int)
    ) -> (any MTLFXSpatialScaler)? {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.inputWidth = width
        descriptor.inputHeight = height
        descriptor.colorProcessingMode = .perceptual
        descriptor.outputWidth = output.0
        descriptor.outputHeight = output.1
        if let scaler = descriptor.makeSpatialScaler(device: device) { return scaler }
        // Fallback if a fractional ratio is rejected: largest integer scale that fits.
        let ratio = Float(output.0) / Float(max(1, width))
        for scale in [4, 3, 2] where Float(scale) <= max(2, ratio.rounded(.down)) {
            let candidateWidth = width * scale
            let candidateHeight = height * scale
            guard VideoSuperResolutionRasterBudget.contains(
                width: candidateWidth, height: candidateHeight
            ) else { continue }
            descriptor.outputWidth = candidateWidth
            descriptor.outputHeight = candidateHeight
            if let scaler = descriptor.makeSpatialScaler(device: device) { return scaler }
        }
        return nil
    }

    private func encodeInputToBGRA(
        commandBuffer: any MTLCommandBuffer,
        metal: VideoEnhancementMetalContext,
        convertPipeline: any MTLComputePipelineState,
        pixelBuffer: CVPixelBuffer,
        size: (Int, Int)
    ) -> [CVMetalTexture]? {
        guard let inputRGBATexture else { return nil }
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if pixelFormat == kCVPixelFormatType_32BGRA {
            guard let bgraMapped = metal.makeTexture(
                buffer: pixelBuffer, format: .bgra8Unorm, width: size.0, height: size.1, plane: 0
            ), let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
            blit.copy(
                from: bgraMapped.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: size.0, height: size.1, depth: 1),
                to: inputRGBATexture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            return [bgraMapped.bridge]
        }

        let chromaSize = (max(1, size.0 / 2), max(1, size.1 / 2))
        guard let yMapped = metal.makeTexture(
            buffer: pixelBuffer, format: .r8Unorm, width: size.0, height: size.1, plane: 0
        ), let cbcrMapped = metal.makeTexture(
            buffer: pixelBuffer, format: .rg8Unorm, width: chromaSize.0, height: chromaSize.1, plane: 1
        ), let compute = commandBuffer.makeComputeCommandEncoder() else { return nil }

        let chromaOffset = MetalNV12PixelConverter.chromaOffset(for: pixelBuffer)
        var params = VideoEnhancementNV12ConvertParams(
            fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0,
            colorMatrix: MetalNV12PixelConverter.colorMatrixIndex(
                for: pixelBuffer, width: size.0, height: size.1
            ),
            chromaOffsetX: chromaOffset.0,
            chromaOffsetY: chromaOffset.1
        )
        compute.setComputePipelineState(convertPipeline)
        compute.setTexture(yMapped.texture, index: 0)
        compute.setTexture(cbcrMapped.texture, index: 1)
        compute.setTexture(inputRGBATexture, index: 2)
        compute.setBytes(&params, length: MemoryLayout<VideoEnhancementNV12ConvertParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: compute, pipeline: convertPipeline, width: size.0, height: size.1
        )
        compute.endEncoding()
        return [yMapped.bridge, cbcrMapped.bridge]
    }

    private func encodeScaleAndOutput(
        commandBuffer: any MTLCommandBuffer,
        scaler: any MTLFXSpatialScaler,
        rcasPipeline: any MTLComputePipelineState,
        inputSize: (Int, Int),
        outputSize: (Int, Int),
        destination: any MTLTexture,
        sharpness: VideoSuperResolutionSharpness
    ) -> Bool {
        guard let inputRGBATexture, let privateOutputTexture else { return false }
        scaler.colorTexture = inputRGBATexture
        scaler.inputContentWidth = inputSize.0
        scaler.inputContentHeight = inputSize.1
        scaler.outputTexture = privateOutputTexture
        scaler.encode(commandBuffer: commandBuffer)

        if sharpness.rcasStrength > 0.001, destination.usage.contains(.shaderWrite) {
            guard let compute = commandBuffer.makeComputeCommandEncoder() else { return false }
            var params = VideoEnhancementRCASParams(strength: sharpness.rcasStrength)
            compute.setComputePipelineState(rcasPipeline)
            compute.setTexture(privateOutputTexture, index: 0)
            compute.setTexture(destination, index: 1)
            compute.setBytes(&params, length: MemoryLayout<VideoEnhancementRCASParams>.size, index: 0)
            VideoEnhancementMetalContext.dispatchThreads(
                encoder: compute, pipeline: rcasPipeline, width: outputSize.0, height: outputSize.1
            )
            compute.endEncoding()
            return true
        }

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.copy(
            from: privateOutputTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: outputSize.0, height: outputSize.1, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        return true
    }

    private static func makeBGRAOutputPool(width: Int, height: Int) -> VideoSuperResolutionPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        return try? VideoSuperResolutionPool(
            attributes: attrs as CFDictionary, label: "MetalFX destination", followsDisplayLookahead: true
        )
    }
    #endif
}

enum VideoEnhancementBackendOutcome {
    case processed(CVPixelBuffer)
    case bypassed(reason: String)
}

enum VideoSuperResolutionRasterBudget {
    static let longestEdge = 3840
    static let pixelCount = 3840 * 2160

    static func contains(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && max(width, height) <= longestEdge && width * height <= pixelCount
    }
}

struct VideoSuperResolutionPool {
    struct Failure: Error {
        let reason: String
        var isBusy = false
    }

    private let pool: CVPixelBufferPool
    private let label: String
    private let limit: Int
    private let followsDisplayLookahead: Bool
    private let isCompatible: (CVPixelBuffer) -> Bool

    /// - Parameter followsDisplayLookahead: destination pools whose buffers wait in the display
    ///   queue; their limit tracks `VideoEnhancementPoolLimits` so deeper lookahead doesn't starve them.
    init(
        attributes: CFDictionary, label: String, limit: Int = 8, followsDisplayLookahead: Bool = false,
        isCompatible: @escaping (CVPixelBuffer) -> Bool = { _ in true }
    ) throws(Failure) {
        var result: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &result)
        guard status == kCVReturnSuccess, let result else {
            throw Failure(reason: "\(label) pool unavailable (\(status))")
        }
        pool = result
        self.label = label
        self.limit = limit
        self.followsDisplayLookahead = followsDisplayLookahead
        self.isCompatible = isCompatible
    }

    func allocate() throws(Failure) -> CVPixelBuffer {
        let threshold = followsDisplayLookahead ? max(limit, VideoEnhancementPoolLimits.superResolutionFrames) : limit
        let allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: threshold] as CFDictionary
        var result: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, allocationAttributes, &result
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            throw Failure(reason: "\(label) pool busy", isBusy: true)
        }
        guard status == kCVReturnSuccess, let result else {
            throw Failure(reason: "\(label) buffer unavailable (\(status))")
        }
        guard isCompatible(result) else { throw Failure(reason: "\(label) buffer layout unsupported") }
        return result
    }
}
