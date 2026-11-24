import CoreVideo
import Foundation
import IOSurface
import Metal

struct VideoEnhancementNV12ConvertParams {
    var fullRange: UInt32
    var colorMatrix: UInt32
    var chromaOffsetX: Float
    var chromaOffsetY: Float
}

struct VideoEnhancementNV12RangeConvertParams {
    var fullToVideo: UInt32
}

struct VideoEnhancementNV12StageCopyParams {
    var activeWidth: UInt32
    var activeHeight: UInt32
    var padLeft: UInt32
    var padTop: UInt32
}

struct VideoEnhancementRCASParams {
    var strength: Float
}

/// Shared GPU infrastructure for all video enhancement backends (MetalFX SR, VideoToolbox SR/FI
/// staging & format conversion, and Vision FI).
///
/// Shares a single `MTLDevice`, `MTLCommandQueue`, precompiled default `MTLLibrary`,
/// `CVMetalTextureCache`, and lazily-cached `MTLComputePipelineState`s so enabling or switching
/// enhancement modes incurs zero runtime shader compilation and avoids duplicate Metal queues.
final class VideoEnhancementMetalContext: @unchecked Sendable {
    static let shared = VideoEnhancementMetalContext()

    struct Resources {
        let device: any MTLDevice
        let commandQueue: any MTLCommandQueue
        let library: any MTLLibrary
        let textureCache: CVMetalTextureCache
    }

    struct MappedTexture {
        let texture: any MTLTexture
        let bridge: CVMetalTexture
    }

    enum Kernel: String, Hashable, Sendable {
        // VideoEnhancementShaders.metal
        case nv12ToBGRA
        case nv12RangeConvertY
        case nv12RangeConvertCbCr
        case nv12StageCopyY
        case nv12StageCopyCbCr
        case rcasSharpen

        // VisionFrameInterpolation.metal
        case visionInterpolationPrepare
        case visionInterpolationValidate
        case visionInterpolationSynthesize
    }

    struct SetupFailure: Error, Sendable {
        let stage: String
        let status: Int?

        init(stage: String, status: Int? = nil) {
            self.stage = stage
            self.status = status
        }
    }

    private let stateLock = NSLock()
    private let cacheLock = NSLock()
    private var cachedResources: Resources?
    private var pipelines: [Kernel: any MTLComputePipelineState] = [:]

    private init() {}

    func resources() throws(SetupFailure) -> Resources {
        let result: Result<Resources, SetupFailure> = stateLock.withLock {
            do throws(SetupFailure) {
                return .success(try resourcesLocked())
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    func pipeline(for kernel: Kernel) throws(SetupFailure) -> any MTLComputePipelineState {
        let result: Result<any MTLComputePipelineState, SetupFailure> = stateLock.withLock {
            if let cached = pipelines[kernel] {
                return .success(cached)
            }
            do throws(SetupFailure) {
                let res = try resourcesLocked()
                guard let function = res.library.makeFunction(name: kernel.rawValue) else {
                    throw SetupFailure(stage: "missing shader \(kernel.rawValue)")
                }
                let pipeline: any MTLComputePipelineState
                do {
                    pipeline = try res.device.makeComputePipelineState(function: function)
                } catch {
                    throw SetupFailure(stage: "compute pipeline \(kernel.rawValue)", status: (error as NSError).code)
                }
                pipelines[kernel] = pipeline
                return .success(pipeline)
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    func makeCVTexture(
        buffer: CVPixelBuffer,
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        plane: Int = 0,
        usage: MTLTextureUsage? = nil
    ) -> CVMetalTexture? {
        guard width > 0, height > 0, let res = try? resources() else { return nil }
        let attributes: CFDictionary? = usage.map { [kCVMetalTextureUsage: $0.rawValue] as CFDictionary }
        return cacheLock.withLock {
            var textureOut: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                res.textureCache,
                buffer,
                attributes,
                format,
                width,
                height,
                plane,
                &textureOut
            )
            return status == kCVReturnSuccess ? textureOut : nil
        }
    }

    func makeTexture(
        buffer: CVPixelBuffer,
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        plane: Int = 0,
        usage: MTLTextureUsage? = nil
    ) -> MappedTexture? {
        guard let bridge = makeCVTexture(
            buffer: buffer,
            format: format,
            width: width,
            height: height,
            plane: plane,
            usage: usage
        ), let texture = CVMetalTextureGetTexture(bridge) else {
            return nil
        }
        if let usage, !texture.usage.contains(usage) {
            return nil
        }
        return MappedTexture(texture: texture, bridge: bridge)
    }

    func flushTextureCache() {
        let cache = stateLock.withLock { cachedResources?.textureCache }
        guard let cache else { return }
        cacheLock.withLock {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    static func dispatchThreads(
        encoder: any MTLComputeCommandEncoder,
        pipeline: any MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        guard width > 0, height > 0 else { return }
        let tgW = min(16, max(1, pipeline.threadExecutionWidth))
        let tgH = min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / tgW))
        let tgSize = MTLSize(width: tgW, height: tgH, depth: 1)
        let gridSize = MTLSize(
            width: (width + tgW - 1) / tgW,
            height: (height + tgH - 1) / tgH,
            depth: 1
        )
        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: tgSize)
    }

    static func commitAndWait(_ commandBuffer: any MTLCommandBuffer) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            commandBuffer.addCompletedHandler { buffer in
                continuation.resume(returning: buffer.status == .completed)
            }
            commandBuffer.commit()
        }
    }

    /// Returns the destination Metal texture dimensions for `plane` when `buffer` has only
    /// right/bottom extended pixels exposed by its backing IOSurface (`padLeft == 0 && padTop == 0`),
    /// allowing GPU kernels to clamp-fill extended padding without a CPU `CVPixelBufferFillExtendedPixels` sync.
    static func gpuPaddedPlaneSize(
        for buffer: CVPixelBuffer,
        plane: Int,
        activeWidth: Int,
        activeHeight: Int,
        padLeft: Int,
        padRight: Int,
        padTop: Int,
        padBottom: Int
    ) -> (width: Int, height: Int, coversAllPadding: Bool) {
        if padLeft == 0, padRight == 0, padTop == 0, padBottom == 0 {
            return (activeWidth, activeHeight, true)
        }
        guard padLeft == 0, padTop == 0,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
            return (activeWidth, activeHeight, false)
        }
        let targetWidth: Int
        let targetHeight: Int
        let surfaceWidth: Int
        let surfaceHeight: Int
        if CVPixelBufferIsPlanar(buffer) {
            if plane == 0 {
                targetWidth = activeWidth + padRight
                targetHeight = activeHeight + padBottom
            } else {
                let lumaFullW = CVPixelBufferGetWidthOfPlane(buffer, 0) + padRight
                let lumaFullH = CVPixelBufferGetHeightOfPlane(buffer, 0) + padBottom
                targetWidth = max(activeWidth, (lumaFullW + 1) / 2)
                targetHeight = max(activeHeight, (lumaFullH + 1) / 2)
            }
            surfaceWidth = IOSurfaceGetWidthOfPlane(surface, plane)
            surfaceHeight = IOSurfaceGetHeightOfPlane(surface, plane)
        } else {
            targetWidth = activeWidth + padRight
            targetHeight = activeHeight + padBottom
            surfaceWidth = IOSurfaceGetWidth(surface)
            surfaceHeight = IOSurfaceGetHeight(surface)
        }
        if surfaceWidth >= targetWidth, surfaceHeight >= targetHeight {
            return (targetWidth, targetHeight, true)
        }
        return (activeWidth, activeHeight, false)
    }

    private func resourcesLocked() throws(SetupFailure) -> Resources {
        if let cachedResources {
            return cachedResources
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SetupFailure(stage: "Metal device unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw SetupFailure(stage: "Metal command queue unavailable")
        }
        let library = device.makeDefaultLibrary()
            ?? (try? device.makeDefaultLibrary(bundle: Bundle(for: VideoEnhancementMetalContext.self)))
        guard let library else {
            throw SetupFailure(stage: "default Metal library unavailable")
        }
        var cacheOut: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cacheOut)
        guard cacheStatus == kCVReturnSuccess else {
            throw SetupFailure(stage: "texture cache creation failed", status: Int(cacheStatus))
        }
        guard let cache = cacheOut else {
            throw SetupFailure(stage: "texture cache missing result", status: Int(cacheStatus))
        }
        let created = Resources(device: device, commandQueue: queue, library: library, textureCache: cache)
        cachedResources = created
        return created
    }
}
