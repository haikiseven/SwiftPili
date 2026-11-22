import CoreVideo
import Foundation

/// Shared input policy and the separate resolution limit for Demand VOD super-resolution.
enum VideoEnhancementGuardrails {
    static let maxInputLongEdge = 1920
    static let maxInputShortEdge = 1080

    static func isWithin1080p(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        return longEdge <= maxInputLongEdge && shortEdge <= maxInputShortEdge
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

    static func superResolutionBypassReason(_ pixelBuffer: CVPixelBuffer) -> String? {
        isWithin1080p(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            ? nil : "Resolution > 1080p"
    }
}

/// Interpretation must be stable across a synthesized pair. Size and pixel
/// format alone cannot detect an attachment-only range, color or aperture change.
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
        // Field order and bottom-field chroma don't affect progressive images.
        // Compare the scan classification above instead of the raw field count.
        let keys = previousIsInterlaced ? interpretationKeys + fieldKeys : interpretationKeys
        return keys.allSatisfy { key in
            switch (CVBufferCopyAttachment(previous, key, nil), CVBufferCopyAttachment(current, key, nil)) {
            case (nil, nil): true
            case let (lhs?, rhs?): CFEqual(lhs, rhs)
            default: false
            }
        }
    }

    /// Both synthesis backends support progressive SDR input. Log and HDR
    /// metadata require an explicit color pipeline, even on 8-bit surfaces.
    static func interpolationBypassReason(_ buffer: CVPixelBuffer) -> String? {
        if CVBufferCopyAttachment(buffer, kCVImageBufferLogTransferFunctionKey, nil) != nil
            || CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) != nil
            || CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) != nil {
            return "HDR / log transfer"
        }
        return isInterlaced(buffer) ? "Interlaced input" : nil
    }

    private static func isInterlaced(_ buffer: CVPixelBuffer) -> Bool {
        // CoreMedia defines FieldCount as 1 or 2. A valid count takes precedence over field order.
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

    /// Restore image interpretation on an exclusively owned synthesis buffer.
    /// CoreVideo propagation alone skips attachments marked doNotPropagate.
    static func copyInterpretation(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        precondition(hasSameStorageFormat(source, destination))
        for key in interpretationKeys + fieldKeys {
            var mode = CVAttachmentMode.shouldPropagate
            if let value = CVBufferCopyAttachment(source, key, &mode) {
                CVBufferSetAttachment(destination, key, value, mode)
            } else {
                // A missing attachment must also survive pool reuse.
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
