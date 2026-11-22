import CoreVideo
import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif
#if !targetEnvironment(simulator)
import VideoToolbox
#endif

enum VideoSuperResolutionBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case videoToolboxML = "videotoolbox_ml"
    case metalFXSpatial = "metalfx_spatial"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .videoToolboxML: String(localized: "VideoToolbox ML")
        case .metalFXSpatial: String(localized: "MetalFX Spatial")
        }
    }

    var shortLabel: String {
        switch self {
        case .videoToolboxML: "VideoToolbox"
        case .metalFXSpatial: "MetalFX"
        }
    }

    var mode: VideoSuperResolutionMode {
        switch self {
        case .videoToolboxML: .videoToolboxML
        case .metalFXSpatial: .metalFXSpatial
        }
    }
}

enum VideoSuperResolutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case videoToolboxML
    case metalFXSpatial

    var id: String { rawValue }

    var settingsLabel: String {
        switch self {
        case .off: String(localized: "Off")
        case .videoToolboxML: String(localized: "VideoToolbox ML")
        case .metalFXSpatial: String(localized: "MetalFX Spatial")
        }
    }

    var shortLabel: String {
        switch self {
        case .off: String(localized: "Off")
        case .videoToolboxML: "VideoToolbox"
        case .metalFXSpatial: "MetalFX"
        }
    }

    var menuLabel: String { shortLabel }

    var telemetryLabel: String {
        switch self {
        case .off: "Off"
        case .videoToolboxML: "VT ML SR"
        case .metalFXSpatial: "MetalFX SR"
        }
    }

    var persistenceValue: String {
        switch self {
        case .off: "off"
        case .videoToolboxML: "videotoolbox_ml"
        case .metalFXSpatial: "metalfx_spatial"
        }
    }

    init?(persistedValue: String) {
        switch persistedValue {
        case "off": self = .off
        case "videotoolbox_ml", "videoToolboxML": self = .videoToolboxML
        case "metalfx_spatial", "metalFXSpatial": self = .metalFXSpatial
        default: return nil
        }
    }
}

enum VideoInterpolationRate: Int, CaseIterable, Identifiable, Sendable {
    case doubleRate = 0
    case fps60 = 60
    case fps90 = 90
    case fps120 = 120

    var id: Self { self }

    var label: String {
        switch self {
        case .doubleRate: String(localized: "2× Source Frame Rate")
        case .fps60: String(localized: "Up to 60 fps")
        case .fps90: String(localized: "Up to 90 fps")
        case .fps120: String(localized: "Up to 120 fps")
        }
    }
}

enum VideoSuperResolutionScale: Int, CaseIterable, Identifiable, Sendable {
    case two = 2
    case three = 3
    case four = 4

    var id: Self { self }
    var factor: Float { Float(rawValue) }

    var label: String {
        switch self {
        case .two: String(localized: "Up to 2×")
        case .three: String(localized: "Up to 3×")
        case .four: String(localized: "Up to 4×")
        }
    }
}

struct VideoEnhancementConfiguration: Equatable, Sendable {
    var superResolutionMode: VideoSuperResolutionMode = .off
    var frameInterpolationEnabled: Bool = false
    var interpolationRate: VideoInterpolationRate = .doubleRate
    var superResolutionScale: VideoSuperResolutionScale = .two
    var isLiveStream: Bool = false
    /// When enabled, the runtime governor may reduce quality if the device cannot keep up,
    /// runs warm, or is in Low Power Mode. Serious thermal state always pauses enhancement.
    var adaptiveQualityEnabled: Bool = true

    static let disabled = Self()

    var isRequested: Bool {
        superResolutionMode != .off || frameInterpolationEnabled
    }
}

enum VideoEnhancementCapabilityStatus: Equatable, Sendable {
    case supported
    case supportedVisionFallback
    case requiresIOS26
    case unsupported
    case simulatorUnsupported

    var isSupported: Bool {
        switch self {
        case .supported, .supportedVisionFallback: true
        case .requiresIOS26, .unsupported, .simulatorUnsupported: false
        }
    }

    var symbolName: String {
        isSupported ? "checkmark.circle.fill" : "minus.circle"
    }

    var localizedText: String {
        switch self {
        case .supported: String(localized: "Supported")
        case .supportedVisionFallback: String(localized: "Supported (Vision)")
        case .requiresIOS26: String(localized: "Requires iOS 26")
        case .unsupported: String(localized: "Unsupported")
        case .simulatorUnsupported: String(localized: "Simulator")
        }
    }
}

struct VideoEnhancementCapabilities: Equatable, Sendable {
    let videoToolboxML: VideoEnhancementCapabilityStatus
    let metalFXSpatial: VideoEnhancementCapabilityStatus
    let frameInterpolation: VideoEnhancementCapabilityStatus

    static var current: Self {
        Self(
            videoToolboxML: currentVideoToolboxMLSupport(),
            metalFXSpatial: currentMetalFXSpatialSupport(),
            frameInterpolation: currentFrameInterpolationSupport()
        )
    }

    private static func currentVideoToolboxMLSupport() -> VideoEnhancementCapabilityStatus {
        #if targetEnvironment(simulator)
        return .simulatorUnsupported
        #else
        if #available(iOS 26.0, *) {
            let supported = VTSuperResolutionScalerConfiguration.isSupported
                || VTLowLatencySuperResolutionScalerConfiguration.isSupported
            return supported ? .supported : .unsupported
        } else {
            return .requiresIOS26
        }
        #endif
    }

    private static func currentMetalFXSpatialSupport() -> VideoEnhancementCapabilityStatus {
        #if canImport(MetalFX)
        let supported = MTLCreateSystemDefaultDevice().map {
            MTLFXSpatialScalerDescriptor.supportsDevice($0)
        } ?? false
        return supported ? .supported : .unsupported
        #else
        return .unsupported
        #endif
    }

    private static func currentFrameInterpolationSupport() -> VideoEnhancementCapabilityStatus {
        #if targetEnvironment(simulator)
        return .simulatorUnsupported
        #else
        if #available(iOS 26.0, *) {
            let supported = VTFrameRateConversionConfiguration.isSupported
                || VTLowLatencyFrameInterpolationConfiguration.isSupported
            return supported ? .supported : .unsupported
        } else {
            return MTLCreateSystemDefaultDevice() != nil ? .supportedVisionFallback : .unsupported
        }
        #endif
    }
}

enum VideoEnhancementBypassDisplay {
    private static let mappings: [(needles: [String], label: @Sendable () -> String)] = [
        (["> 1080p", ">1080p"], { String(localized: ">1080p") }),
        (["hdr", "10-bit", "log transfer"], { String(localized: "HDR") }),
        (["thermal"], { String(localized: "Thermal") }),
        (["low power"], { String(localized: "Low Power Mode") }),
        (["warming"], { String(localized: "Warming up") }),
        (["memory"], { String(localized: "Memory limited") }),
        (["display resolution"], { String(localized: "Screen resolution reached") }),
        (["performance", "worker busy"], { String(localized: "Performance limited") }),
        (["interlaced"], { String(localized: "Interlaced") }),
        (["vod only", "live unsupported"], { String(localized: "VOD only") }),
        (["libvlc", "demand only"], { String(localized: "Demand only") }),
        (["requires ios 26", "ios 26+"], { String(localized: "iOS 26+") }),
        (["simulator", "device required"], {
            String(localized: "VideoEnhancementBypassSimulator", defaultValue: "Simulator")
        }),
        (["deadline", "timeout"], { String(localized: "VideoEnhancementBypassTimeout", defaultValue: "Timeout") }),
        (["> 30fps", ">30fps"], { String(localized: ">30fps") }),
        (["downloading"], { String(localized: "Model downloading") }),
        (["download required"], { String(localized: "Model required") }),
        (["scene cut"], { String(localized: "Scene cut") }),
        (["unsupported", "unavailable"], { String(localized: "Unsupported") }),
    ]

    static func shortLabel(for rawReason: String) -> String {
        let lower = rawReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for entry in mappings where entry.needles.contains(where: { lower.contains($0) }) {
            return entry.label()
        }
        return String(localized: "Skipped")
    }

    static func pausedMenuLabel(for rawReason: String) -> String {
        String(format: String(localized: "Paused · %@"), shortLabel(for: rawReason))
    }

    static func pausedStatsLabel(for rawReason: String) -> String {
        String(format: String(localized: "Paused (%@)"), shortLabel(for: rawReason))
    }
}

struct VideoEnhancementTelemetry: Equatable, Sendable {
    var activeModeLabel: String = "Off"
    var inputWidth: Int = 0
    var inputHeight: Int = 0
    var outputWidth: Int = 0
    var outputHeight: Int = 0
    var inputFPS: Double = 0
    var outputFPS: Double = 0
    var smoothedProcessingMs: Double = 0
    var bypassReason: String?
    var isActive: Bool = false
    /// Set when the adaptive governor is running a reduced configuration (raw reason string).
    var degradationNote: String?
    /// Share of recently presented originals that were actually upscaled / preceded by
    /// interpolated frames (nil when that feature is not running).
    var superResolutionShare: Double?
    var interpolationShare: Double?
    /// Dominant reason some recent frames were not fully enhanced while enhancement is active.
    var partialReason: String?

    static func bypassed(reason: String) -> Self {
        Self(
            activeModeLabel: "Bypass",
            bypassReason: reason,
            isActive: false
        )
    }

    var formattedSummary: String {
        if let reason = bypassReason {
            return VideoEnhancementBypassDisplay.pausedStatsLabel(for: reason)
        }
        guard isActive else { return String(localized: "Off") }
        var parts = [activeModeLabel]
        if inputWidth > 0, inputHeight > 0, outputWidth > 0, outputHeight > 0 {
            parts.append("\(inputWidth)×\(inputHeight)→\(outputWidth)×\(outputHeight)")
        }
        if inputFPS > 0.5, outputFPS > 0.5 {
            parts.append(String(format: "%.0f→%.0ffps", inputFPS, outputFPS))
        }
        if smoothedProcessingMs > 0.01 {
            parts.append(String(format: "%.1fms", smoothedProcessingMs))
        }
        if let degradationNote {
            parts.append(String(format: String(localized: "(Reduced · %@)"),
                                VideoEnhancementBypassDisplay.shortLabel(for: degradationNote)))
        }
        return parts.joined(separator: " ")
    }

    var compactSummary: String {
        if let reason = bypassReason {
            return VideoEnhancementBypassDisplay.pausedStatsLabel(for: reason)
        }
        guard isActive else { return String(localized: "Off") }
        var parts = [activeModeLabel]
        if inputHeight > 0, outputHeight > 0 {
            parts.append("\(inputHeight)p→\(outputHeight)p")
        }
        if inputFPS > 0.5, outputFPS > 0.5 {
            parts.append(String(format: "%.0f→%.0ffps", inputFPS, outputFPS))
        }
        if smoothedProcessingMs > 0.01 {
            parts.append(String(format: "%.1fms", smoothedProcessingMs))
        }
        if let degradationNote {
            parts.append(String(format: String(localized: "(Reduced · %@)"),
                                VideoEnhancementBypassDisplay.shortLabel(for: degradationNote)))
        }
        return parts.joined(separator: " ")
    }
}

enum VideoEnhancementPreferences {
    static let defaultSRBackendKey = "experimental_video_enhancement_default_sr_backend"
    static let defaultFrameInterpolationKey = "experimental_video_enhancement_default_frame_interpolation"

    static var defaultSRMode: VideoSuperResolutionMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultSRBackendKey),
                  let mode = VideoSuperResolutionMode(persistedValue: raw) else {
                return .off
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.persistenceValue, forKey: defaultSRBackendKey)
        }
    }

    static var defaultSRBackend: VideoSuperResolutionBackend {
        get {
            switch defaultSRMode {
            case .off, .videoToolboxML: .videoToolboxML
            case .metalFXSpatial: .metalFXSpatial
            }
        }
        set {
            defaultSRMode = newValue.mode
        }
    }

    private static let interpolationRateKey = "experimental_video_enhancement_interpolation_rate"
    private static let superResolutionScaleKey = "experimental_video_enhancement_super_resolution_scale"

    static var interpolationRate: VideoInterpolationRate {
        get {
            let raw = UserDefaults.standard.integer(forKey: interpolationRateKey)
            return VideoInterpolationRate(rawValue: raw) ?? .doubleRate
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: interpolationRateKey) }
    }

    static var superResolutionScale: VideoSuperResolutionScale {
        get {
            let raw = UserDefaults.standard.integer(forKey: superResolutionScaleKey)
            return VideoSuperResolutionScale(rawValue: raw) ?? .two
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: superResolutionScaleKey) }
    }

    private static let adaptiveQualityKey = "experimental_video_enhancement_adaptive_quality"

    static var adaptiveQualityEnabled: Bool {
        get { UserDefaults.standard.object(forKey: adaptiveQualityKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: adaptiveQualityKey) }
    }

    static var defaultFrameInterpolationEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: defaultFrameInterpolationKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultFrameInterpolationKey)
        }
    }
}
