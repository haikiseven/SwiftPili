import CoreVideo
import Foundation
import os
import UIKit

enum VideoEnhancementGuardrails {
    static let maxInputLongEdge = 1920
    static let maxInputShortEdge = 1080

    private static let memoryPressureCooldown: Duration = .seconds(30)
    private static let lastMemoryWarning = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    private nonisolated(unsafe) static let memoryWarningObserver: NSObjectProtocol =
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            lastMemoryWarning.withLock { $0 = .now }
        }

    static var isUnderMemoryPressure: Bool {
        _ = memoryWarningObserver
        guard let last = lastMemoryWarning.withLock({ $0 }) else { return false }
        return last.duration(to: .now) < memoryPressureCooldown
    }

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
            if CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
                || CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
                || CFEqual(transfer, kCVImageBufferTransferFunction_Linear) {
                return false
            }
        }
        return true
    }

    static func commonBypassReason(
        configuration: VideoEnhancementConfiguration,
        pixelBuffer: CVPixelBuffer,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
        memoryPressure: Bool = VideoEnhancementGuardrails.isUnderMemoryPressure
    ) -> String? {
        if configuration.isLiveStream {
            return "VOD only"
        }
        if isThermalThrottled(thermalState) {
            return "Thermal throttling"
        }
        if memoryPressure {
            return "Memory pressure"
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
    private nonisolated(unsafe) static let fieldKeys: [CFString] = [
        kCVImageBufferFieldCountKey,
        kCVImageBufferFieldDetailKey,
        kCVImageBufferChromaLocationBottomFieldKey,
    ]

    private nonisolated(unsafe) static let interpretationKeys: [CFString] = [
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferGammaLevelKey,
        kCVImageBufferICCProfileKey,
        kCVImageBufferCGColorSpaceKey,
        kCVImageBufferCleanApertureKey,
        kCVImageBufferPreferredCleanApertureKey,
        kCVImageBufferPixelAspectRatioKey,
        kCVImageBufferDisplayDimensionsKey,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferLogTransferFunctionKey,
        kCVImageBufferMasteringDisplayColorVolumeKey,
        kCVImageBufferContentLightLevelInfoKey,
        kCVImageBufferAmbientViewingEnvironmentKey,
        kCVImageBufferAlphaChannelModeKey,
        kCVImageBufferAlphaChannelIsOpaque,
    ]

    private nonisolated(unsafe) static let allKeys: [CFString] = interpretationKeys + fieldKeys

    static func hasSameStorageFormat(_ source: CVPixelBuffer, _ destination: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(destination)
            && CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(destination)
            && CVPixelBufferGetPixelFormatType(source) == CVPixelBufferGetPixelFormatType(destination)
    }

    static func matches(_ previous: CVPixelBuffer, _ current: CVPixelBuffer) -> Bool {
        guard hasSameStorageFormat(previous, current) else { return false }
        let previousIsInterlaced = isInterlaced(previous)
        guard previousIsInterlaced == isInterlaced(current) else { return false }
        let keys = previousIsInterlaced ? allKeys : interpretationKeys
        for key in keys {
            switch (CVBufferCopyAttachment(previous, key, nil), CVBufferCopyAttachment(current, key, nil)) {
            case (nil, nil):
                continue
            case let (lhs?, rhs?):
                if !CFEqual(lhs, rhs) { return false }
            default:
                return false
            }
        }
        return true
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
        return CFEqual(detail, kCVImageBufferFieldDetailTemporalTopFirst)
            || CFEqual(detail, kCVImageBufferFieldDetailTemporalBottomFirst)
            || CFEqual(detail, kCVImageBufferFieldDetailSpatialFirstLineEarly)
            || CFEqual(detail, kCVImageBufferFieldDetailSpatialFirstLineLate)
    }

    static func copyInterpretation(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        precondition(hasSameStorageFormat(source, destination))
        for key in allKeys {
            var mode = CVAttachmentMode.shouldPropagate
            if let value = CVBufferCopyAttachment(source, key, &mode) {
                CVBufferSetAttachment(destination, key, value, mode)
            } else {
                CVBufferRemoveAttachment(destination, key)
            }
        }
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
        }
    }
}
