#if targetEnvironment(simulator)

import Accelerate
import CoreVideo
import UIKit

@MainActor
final class SimulatorVideoImageConverter {
    struct Failure: Error {
        let stage: String
        let status: Int
    }

    private static let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
    )

    private static let formatKeys: [CFString] = {
        var keys = [
            kCVImageBufferCGColorSpaceKey, kCVImageBufferICCProfileKey,
            kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey, kCVImageBufferGammaLevelKey,
            kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaSubsamplingKey, kCVImageBufferAlphaChannelIsOpaque,
            kCVImageBufferAlphaChannelModeKey, kCVImageBufferFieldCountKey, kCVImageBufferFieldDetailKey
        ]
        if #available(iOS 17.2, *) { keys.append(kCVImageBufferLogTransferFunctionKey) }
        return keys
    }()

    @MainActor
    private struct InputFormat {
        let code: OSType
        let attachments: [CFTypeRef?]

        init(_ pixelBuffer: CVPixelBuffer) {
            code = CVPixelBufferGetPixelFormatType(pixelBuffer)
            attachments = formatKeys.map { key in
                guard let value = CVBufferCopyAttachment(pixelBuffer, key, nil) else { return nil }
                if CFGetTypeID(value) == CGColorSpace.typeID { return value }
                guard CFPropertyListIsValid(value, .binaryFormat_v1_0) else { return nil }
                return CFPropertyListCreateDeepCopy(nil, value, CFOptionFlags(0))
            }
        }

        func matches(_ pixelBuffer: CVPixelBuffer) -> Bool {
            guard code == CVPixelBufferGetPixelFormatType(pixelBuffer) else { return false }
            for (index, key) in formatKeys.enumerated() {
                let current = CVBufferCopyAttachment(pixelBuffer, key, nil)
                switch (attachments[index], current) {
                case (nil, nil): continue
                case let (cached?, current?) where CFEqual(cached, current): continue
                default: return false
                }
            }
            return true
        }
    }

    @MainActor
    private final class Setup {
        let converter: vImageConverter
        let colorSpace: CGColorSpace
        var sources: [vImage_Buffer]

        init(converter: vImageConverter, colorSpace: CGColorSpace, sourceCount: Int) {
            self.converter = converter
            self.colorSpace = colorSpace
            sources = Array(repeating: vImage_Buffer(), count: sourceCount)
        }
    }

    private var inputFormat: InputFormat?
    private var setup: Setup?
    private var setupFailure: Failure?
    private var scratch: SimulatorVideoConversionScratch?

    func reset() {
        inputFormat = nil
        setup = nil
        setupFailure = nil
        scratch = nil
    }

    func makeImage(from pixelBuffer: CVPixelBuffer) throws(Failure) -> CGImage {
        if inputFormat?.matches(pixelBuffer) != true {
            reset()
            inputFormat = InputFormat(pixelBuffer)
            do {
                setup = try makeSetup(for: pixelBuffer)
            } catch {
                setupFailure = error
            }
        }
        if let setupFailure { throw setupFailure }
        guard let setup else { throw Failure(stage: "setup", status: kvImageInvalidCVImageFormat) }
        return try makeImage(from: pixelBuffer, using: setup)
    }

    private func makeSetup(for pixelBuffer: CVPixelBuffer) throws(Failure) -> Setup {
        guard let sourceFormat = vImageCVImageFormat_CreateWithCVPixelBuffer(pixelBuffer)?.takeRetainedValue(),
              let colorSpace = sourceFormat.colorSpace,
              colorSpace.model == .rgb
        else {
            throw Failure(stage: "source-color-space", status: kvImageCVImageFormat_ColorSpace)
        }
        var destination = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(colorSpace), bitmapInfo: Self.bitmapInfo,
            version: 0, decode: nil, renderingIntent: .defaultIntent
        )
        var status: vImage_Error = kvImageNoError
        guard let converter = vImageConverter_CreateForCVToCGImageFormat(
            sourceFormat, &destination, nil, vImage_Flags(kvImageNoFlags), &status
        )?.takeRetainedValue() else {
            throw Failure(stage: "converter", status: status)
        }
        let count = Int(vImageConverter_GetNumberOfSourceBuffers(converter))
        guard count > 0 else { throw Failure(stage: "source-planes", status: kvImageInvalidImageFormat) }
        return Setup(converter: converter, colorSpace: colorSpace, sourceCount: count)
    }

    private func makeImage(
        from pixelBuffer: CVPixelBuffer, using setup: Setup
    ) throws(Failure) -> CGImage {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !rowOverflow, !sizeOverflow,
              let bytes = malloc(byteCount) else {
            throw Failure(stage: "image-allocation", status: kvImageMemoryAllocationError)
        }
        var ownsBytes = true
        defer { if ownsBytes { free(bytes) } }
        var destination = vImage_Buffer(data: bytes, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: rowBytes)
        try convert(pixelBuffer, using: setup, destination: &destination)
        guard let provider = CGDataProvider(dataInfo: nil, data: bytes, size: byteCount, releaseData: { _, data, _ in
            free(UnsafeMutableRawPointer(mutating: data))
        }) else {
            throw Failure(stage: "image-provider", status: kvImageMemoryAllocationError)
        }
        ownsBytes = false
        guard let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: setup.colorSpace, bitmapInfo: Self.bitmapInfo, provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        ) else {
            throw Failure(stage: "rgb-image", status: kvImageInvalidImageFormat)
        }
        return image
    }

    private func convert(
        _ pixelBuffer: CVPixelBuffer, using setup: Setup, destination: inout vImage_Buffer
    ) throws(Failure) {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw Failure(stage: "pixel-lock", status: Int(lockStatus))
        }
        defer {
            for index in setup.sources.indices { setup.sources[index] = vImage_Buffer() }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        let sourceStatus = vImageBuffer_InitForCopyFromCVPixelBuffer(
            &setup.sources, setup.converter, pixelBuffer, vImage_Flags(kvImageNoAllocate)
        )
        guard sourceStatus == kvImageNoError else { throw Failure(stage: "source-planes", status: sourceStatus) }
        let required = vImageConvert_AnyToAny(
            setup.converter, &setup.sources, &destination, nil, vImage_Flags(kvImageGetTempBufferSize)
        )
        guard required >= 0 else { throw Failure(stage: "scratch-size", status: required) }
        if required > (scratch?.capacity ?? 0) {
            guard let replacement = SimulatorVideoConversionScratch(capacity: required) else {
                throw Failure(stage: "scratch-allocation", status: kvImageMemoryAllocationError)
            }
            scratch = replacement
        }
        let status = vImageConvert_AnyToAny(
            setup.converter, &setup.sources, &destination, scratch?.bytes, vImage_Flags(kvImageNoFlags)
        )
        guard status == kvImageNoError else { throw Failure(stage: "convert", status: status) }
    }

    static func colorSummary(_ pixelBuffer: CVPixelBuffer) -> String {
        let keys = [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey,
                    kCVImageBufferTransferFunctionKey, kCVImageBufferChromaLocationTopFieldKey]
        return keys.map { key in
            let value = CVBufferCopyAttachment(pixelBuffer, key, nil)
            return "\(key)=\(value.map { String(describing: $0) } ?? "absent")"
        }.joined(separator: " ")
    }
}

private final class SimulatorVideoConversionScratch {
    let bytes: UnsafeMutableRawPointer
    let capacity: Int

    init?(capacity: Int) {
        guard let bytes = malloc(capacity) else { return nil }
        self.bytes = bytes
        self.capacity = capacity
    }

    deinit { free(bytes) }
}

#endif
