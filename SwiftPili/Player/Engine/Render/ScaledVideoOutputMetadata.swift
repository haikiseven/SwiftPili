import CoreVideo
import Foundation

enum ScaledVideoOutputMetadata {
    enum OutputColorSpace {
        case yuvSameAsSource
        case rgbConverted
    }

    nonisolated(unsafe) private static let rgbKeys: [CFString] = [
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferGammaLevelKey,
        kCVImageBufferICCProfileKey,
        kCVImageBufferCGColorSpaceKey,
        kCVImageBufferPixelAspectRatioKey,
        kCVImageBufferLogTransferFunctionKey,
        kCVImageBufferMasteringDisplayColorVolumeKey,
        kCVImageBufferContentLightLevelInfoKey,
        kCVImageBufferAmbientViewingEnvironmentKey,
        kCVImageBufferAlphaChannelModeKey,
        kCVImageBufferAlphaChannelIsOpaque,
    ]

    nonisolated(unsafe) private static let yuvOnlyKeys: [CFString] = [
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey,
    ]

    nonisolated(unsafe) private static let yuvAllKeys: [CFString] = rgbKeys + yuvOnlyKeys

    nonisolated(unsafe) private static let cleanApertureKeys: [CFString] = [
        kCVImageBufferCleanApertureKey,
        kCVImageBufferPreferredCleanApertureKey,
    ]

    private static let cleanApertureWidthKey = kCVImageBufferCleanApertureWidthKey as String
    private static let cleanApertureHeightKey = kCVImageBufferCleanApertureHeightKey as String
    private static let cleanApertureHorizontalOffsetKey = kCVImageBufferCleanApertureHorizontalOffsetKey as String
    private static let cleanApertureVerticalOffsetKey = kCVImageBufferCleanApertureVerticalOffsetKey as String
    private static let displayWidthKey = kCVImageBufferDisplayWidthKey as String
    private static let displayHeightKey = kCVImageBufferDisplayHeightKey as String

    static func copy(
        from source: CVPixelBuffer,
        to output: CVPixelBuffer,
        colorSpace: OutputColorSpace
    ) {
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(source, output)

        let keysToCopy = colorSpace == .yuvSameAsSource ? yuvAllKeys : rgbKeys
        for key in keysToCopy {
            var mode = CVAttachmentMode.shouldPropagate
            if let value = CVBufferCopyAttachment(source, key, &mode) {
                CVBufferSetAttachment(output, key, value, mode)
            }
        }

        if colorSpace == .rgbConverted {
            for key in yuvOnlyKeys {
                CVBufferRemoveAttachment(output, key)
            }
        }

        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard sourceWidth > 0, sourceHeight > 0 else { return }

        let horizontalScale = Double(CVPixelBufferGetWidth(output)) / Double(sourceWidth)
        let verticalScale = Double(CVPixelBufferGetHeight(output)) / Double(sourceHeight)

        for key in cleanApertureKeys {
            scaleCleanAperture(
                key,
                horizontalScale: horizontalScale,
                verticalScale: verticalScale,
                from: source,
                to: output
            )
        }

        scaleDisplayDimensions(
            horizontalScale: horizontalScale,
            verticalScale: verticalScale,
            from: source,
            to: output
        )
    }

    private static func scaleCleanAperture(
        _ key: CFString,
        horizontalScale: Double,
        verticalScale: Double,
        from source: CVPixelBuffer,
        to output: CVPixelBuffer
    ) {
        var mode = CVAttachmentMode.shouldPropagate
        CVBufferRemoveAttachment(output, key)
        guard var values = CVBufferCopyAttachment(source, key, &mode) as? [String: Any] else { return }
        guard scaleField(cleanApertureWidthKey, factor: horizontalScale, in: &values),
              scaleField(cleanApertureHeightKey, factor: verticalScale, in: &values),
              scaleField(cleanApertureHorizontalOffsetKey, factor: horizontalScale, in: &values),
              scaleField(cleanApertureVerticalOffsetKey, factor: verticalScale, in: &values) else {
            return
        }
        CVBufferSetAttachment(output, key, values as CFDictionary, mode)
    }

    private static func scaleDisplayDimensions(
        horizontalScale: Double,
        verticalScale: Double,
        from source: CVPixelBuffer,
        to output: CVPixelBuffer
    ) {
        var mode = CVAttachmentMode.shouldPropagate
        CVBufferRemoveAttachment(output, kCVImageBufferDisplayDimensionsKey)
        guard var values = CVBufferCopyAttachment(source, kCVImageBufferDisplayDimensionsKey, &mode) as? [String: Any] else {
            return
        }
        guard scaleField(displayWidthKey, factor: horizontalScale, in: &values),
              scaleField(displayHeightKey, factor: verticalScale, in: &values) else {
            return
        }
        CVBufferSetAttachment(output, kCVImageBufferDisplayDimensionsKey, values as CFDictionary, mode)
    }

    private static func scaleField(_ key: String, factor: Double, in values: inout [String: Any]) -> Bool {
        guard let value = values[key] as? NSNumber, value.doubleValue.isFinite else { return false }
        values[key] = value.doubleValue * factor
        return true
    }
}
