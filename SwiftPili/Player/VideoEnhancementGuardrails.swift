import CoreVideo
import Foundation

enum VideoEnhancementGuardrails {
    static let maxInputLongEdge = 1920
    static let maxInputShortEdge = 1080

    static func isWithin(
        width: Int,
        height: Int,
        limit: VideoEnhancementMaxInputResolution
    ) -> Bool {
        limit.contains(width: width, height: height)
    }

    static func isWithin1080p(width: Int, height: Int) -> Bool {
        isWithin(width: width, height: height, limit: .p1080)
    }

    static func isThermalThrottled(
        _ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Bool {
        state == .serious || state == .critical
    }

    static func isSDR8Bit(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let is8BitFormat = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_32BGRA
        guard is8BitFormat else { return false }

        if let transfer = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            nil
        ) {
            let transferString = String(describing: transfer)
            if transferString == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                || transferString == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
                || transferString == (kCVImageBufferTransferFunction_Linear as String) {
                return false
            }
        }
        return true
    }

    static func commonBypassReason(
        configuration: VideoEnhancementConfiguration,
        pixelBuffer: CVPixelBuffer,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> String? {
        if configuration.isLiveStream {
            return "VOD only"
        }
        if isThermalThrottled(thermalState) {
            return "Thermal throttling"
        }
        if !isSDR8Bit(pixelBuffer) {
            return "HDR / 10-bit"
        }
        return nil
    }

    static func superResolutionBypassReason(
        _ pixelBuffer: CVPixelBuffer,
        maxInputResolution: VideoEnhancementMaxInputResolution = .p1080
    ) -> String? {
        isWithin(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            limit: maxInputResolution
        ) ? nil : maxInputResolution.bypassReason
    }
}

enum VideoFramePairFormat {
    static func hasSameStorageFormat(_ source: CVPixelBuffer, _ destination: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(destination)
            && CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(destination)
            && CVPixelBufferGetPixelFormatType(source) == CVPixelBufferGetPixelFormatType(destination)
    }

    static func matches(_ previous: CVPixelBuffer, _ current: CVPixelBuffer) -> Bool {
        guard hasSameStorageFormat(previous, current) else { return false }
        let previousIsInterlaced = isInterlaced(previous)
        guard previousIsInterlaced == isInterlaced(current) else { return false }
        let keys = previousIsInterlaced ? interpretationKeys + fieldKeys : interpretationKeys
        return keys.allSatisfy { key in
            switch (CVBufferCopyAttachment(previous, key, nil), CVBufferCopyAttachment(current, key, nil)) {
            case (nil, nil): true
            case let (lhs?, rhs?): CFEqual(lhs, rhs)
            default: false
            }
        }
    }

    static func interpolationBypassReason(_ buffer: CVPixelBuffer) -> String? {
        if CVBufferCopyAttachment(buffer, kCVImageBufferLogTransferFunctionKey, nil) != nil
            || CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) != nil
            || CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) != nil {
            return "HDR / log transfer"
        }
        return isInterlaced(buffer) ? "Interlaced input" : nil
    }

    private static func isInterlaced(_ buffer: CVPixelBuffer) -> Bool {
        if let value = CVBufferCopyAttachment(buffer, kCVImageBufferFieldCountKey, nil),
           CFGetTypeID(value) == CFNumberGetTypeID(),
           let number = value as? NSNumber,
           let count = Int(exactly: number), count == 1 || count == 2 {
            return count == 2
        }
        guard let detail = CVBufferCopyAttachment(buffer, kCVImageBufferFieldDetailKey, nil) else { return false }
        let fieldOrders = [
            kCVImageBufferFieldDetailTemporalTopFirst,
            kCVImageBufferFieldDetailTemporalBottomFirst,
            kCVImageBufferFieldDetailSpatialFirstLineEarly,
            kCVImageBufferFieldDetailSpatialFirstLineLate,
        ]
        return fieldOrders.contains { CFEqual(detail, $0) }
    }

    static func copyInterpretation(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        precondition(hasSameStorageFormat(source, destination))
        for key in interpretationKeys + fieldKeys {
            var mode = CVAttachmentMode.shouldPropagate
            if let value = CVBufferCopyAttachment(source, key, &mode) {
                CVBufferSetAttachment(destination, key, value, mode)
            } else {
                CVBufferRemoveAttachment(destination, key)
            }
        }
    }

    private static var fieldKeys: [CFString] {
        [kCVImageBufferFieldCountKey, kCVImageBufferFieldDetailKey, kCVImageBufferChromaLocationBottomFieldKey]
    }

    private static var interpretationKeys: [CFString] {
        [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey,
         kCVImageBufferGammaLevelKey, kCVImageBufferICCProfileKey, kCVImageBufferCGColorSpaceKey,
         kCVImageBufferCleanApertureKey, kCVImageBufferPreferredCleanApertureKey,
         kCVImageBufferPixelAspectRatioKey, kCVImageBufferDisplayDimensionsKey,
         kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferLogTransferFunctionKey,
         kCVImageBufferMasteringDisplayColorVolumeKey, kCVImageBufferContentLightLevelInfoKey,
         kCVImageBufferAmbientViewingEnvironmentKey, kCVImageBufferAlphaChannelModeKey,
         kCVImageBufferAlphaChannelIsOpaque]
    }
}

/// Pixel size of the layer showing the video. Super resolution beyond the on-screen magnification
/// is wasted: the display layer just scales it back down (e.g. 1080p → 4K on a 2868×1320 phone).
struct VideoEnhancementDisplaySurface: Equatable, Sendable {
    /// Below this on-screen magnification SR has no visible benefit and is skipped.
    static let minimumUsefulMagnification: Float = 1.15

    let pixelWidth: Int
    let pixelHeight: Int
    /// Aspect-fill / stretch crops or distorts, so magnification follows the larger ratio.
    let fills: Bool

    /// How much the source is magnified on screen.
    func magnification(inputWidth: Int, inputHeight: Int) -> Float? {
        guard pixelWidth > 0, pixelHeight > 0, inputWidth > 0, inputHeight > 0 else { return nil }
        let horizontal = Float(pixelWidth) / Float(inputWidth)
        let vertical = Float(pixelHeight) / Float(inputHeight)
        return fills ? max(horizontal, vertical) : min(horizontal, vertical)
    }

    /// Scale cap for a backend, or nil when SR would not be visible.
    func superResolutionCap(
        inputWidth: Int, inputHeight: Int, requested: Float, mode: VideoSuperResolutionMode
    ) -> Float? {
        guard let magnification = magnification(inputWidth: inputWidth, inputHeight: inputHeight) else {
            return requested
        }
        guard magnification >= Self.minimumUsefulMagnification else { return nil }
        switch mode {
        case .off: return nil
        // MetalFX supports arbitrary output sizes; match the screen.
        case .metalFXSpatial: return min(requested, magnification)
        // VT only offers native factors (≥ 2×); allow the smallest one when the screen is between.
        case .videoToolboxML: return min(requested, max(2, magnification))
        }
    }
}
