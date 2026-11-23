import CoreVideo
import Foundation

enum ScaledVideoOutputMetadata {
    enum OutputColorSpace {
        case yuvSameAsSource
        case rgbConverted
    }

    private static var rgbKeys: [CFString] {
        [
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
    }

    private static var yuvOnlyKeys: [CFString] {
        [
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey,
        ]
    }

    static func copy(
        from source: CVPixelBuffer,
        to output: CVPixelBuffer,
        colorSpace: OutputColorSpace
    ) {
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(source, output)

        let keysToCopy = colorSpace == .yuvSameAsSource ? rgbKeys + yuvOnlyKeys : rgbKeys
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

        let apertureFactors = [
            kCVImageBufferCleanApertureWidthKey as String: horizontalScale,
            kCVImageBufferCleanApertureHeightKey as String: verticalScale,
            kCVImageBufferCleanApertureHorizontalOffsetKey as String: horizontalScale,
            kCVImageBufferCleanApertureVerticalOffsetKey as String: verticalScale,
        ]
        for key in [kCVImageBufferCleanApertureKey, kCVImageBufferPreferredCleanApertureKey] {
            scaleAttachment(key, factors: apertureFactors, from: source, to: output)
        }

        let displayFactors = [
            kCVImageBufferDisplayWidthKey as String: horizontalScale,
            kCVImageBufferDisplayHeightKey as String: verticalScale,
        ]
        scaleAttachment(kCVImageBufferDisplayDimensionsKey, factors: displayFactors, from: source, to: output)
    }

    private static func scaleAttachment(
        _ key: CFString,
        factors: [String: Double],
        from source: CVPixelBuffer,
        to output: CVPixelBuffer
    ) {
        var mode = CVAttachmentMode.shouldPropagate
        CVBufferRemoveAttachment(output, key)
        guard var values = CVBufferCopyAttachment(source, key, &mode) as? [String: Any] else { return }
        for (dimension, factor) in factors {
            guard let value = values[dimension] as? NSNumber, value.doubleValue.isFinite else { return }
            values[dimension] = value.doubleValue * factor
        }
        CVBufferSetAttachment(output, key, values as CFDictionary, mode)
    }
}
