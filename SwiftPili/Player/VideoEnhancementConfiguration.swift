import CoreVideo
import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif
#if !targetEnvironment(simulator)
import VideoToolbox
#endif

enum VideoSuperResolutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case metalFXSpatial

    var id: String { rawValue }

    var settingsLabel: String {
        switch self {
        case .off: String(localized: "Off")
        case .metalFXSpatial: String(localized: "MetalFX Spatial")
        }
    }

    var shortLabel: String {
        switch self {
        case .off: String(localized: "Off")
        case .metalFXSpatial: "MetalFX"
        }
    }

    var menuLabel: String { shortLabel }

    var telemetryLabel: String {
        switch self {
        case .off: "Off"
        case .metalFXSpatial: "MetalFX SR"
        }
    }

    var persistenceValue: String {
        switch self {
        case .off: "off"
        case .metalFXSpatial: "metalfx_spatial"
        }
    }

    init?(persistedValue: String) {
        switch persistedValue {
        case "off":
            self = .off
        case "metalfx_spatial", "metalFXSpatial", "videotoolbox_ml", "videoToolboxML":
            self = .metalFXSpatial
        default:
            return nil
        }
    }
}

enum VideoFrameInterpolationBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case videoToolbox = "videotoolbox"
    case visionOpticalFlow = "vision_optical_flow"

    var id: Self { self }

    var label: String {
        switch self {
        case .auto:
            String(localized: "Auto")
        case .videoToolbox:
            String(localized: "iOS 26 System", defaultValue: "iOS 26 System")
        case .visionOpticalFlow:
            String(localized: "Optical Flow (iOS 18+)", defaultValue: "Optical Flow (iOS 18+)")
        }
    }

    var telemetryLabel: String {
        switch self {
        case .auto:
            resolved().telemetryLabel
        case .videoToolbox:
            "VT System"
        case .visionOpticalFlow:
            "Vision Flow"
        }
    }

    var persistenceValue: String { rawValue }

    init?(persistedValue: String) {
        switch persistedValue {
        case "auto":
            self = .auto
        case "videotoolbox", "videoToolbox":
            self = .videoToolbox
        case "vision_optical_flow", "visionOpticalFlow", "vision":
            self = .visionOpticalFlow
        default:
            return nil
        }
    }

    /// Resolves user preference to a concrete runtime backend (`.videoToolbox` or `.visionOpticalFlow`).
    /// - `.auto` resolves to `.videoToolbox` when iOS 26+ `VTFrameProcessor` FRC is supported,
    ///   otherwise `.visionOpticalFlow`.
    /// - `.videoToolbox` gracefully falls back to `.visionOpticalFlow` when hardware/OS lacks support.
    /// - `.visionOpticalFlow` always runs Vision optical flow (including on iOS 26+ devices).
    func resolved(
        vtSupported: Bool = VideoEnhancementCapabilities.supportsVideoToolboxFrameInterpolation
    ) -> Self {
        switch self {
        case .auto, .videoToolbox:
            vtSupported ? .videoToolbox : .visionOpticalFlow
        case .visionOpticalFlow:
            .visionOpticalFlow
        }
    }

    func supportsArbitraryPhases(
        vtSupported: Bool = VideoEnhancementCapabilities.supportsVideoToolboxFrameInterpolation
    ) -> Bool {
        switch resolved(vtSupported: vtSupported) {
        case .videoToolbox, .auto:
            false
        case .visionOpticalFlow:
            true
        }
    }

    func isSelectable(
        vtSupported: Bool = VideoEnhancementCapabilities.supportsVideoToolboxFrameInterpolation
    ) -> Bool {
        switch self {
        case .auto, .visionOpticalFlow:
            true
        case .videoToolbox:
            vtSupported
        }
    }

    static func selectableBackends(
        vtSupported: Bool = VideoEnhancementCapabilities.supportsVideoToolboxFrameInterpolation
    ) -> [Self] {
        allCases.filter { $0.isSelectable(vtSupported: vtSupported) }
    }
}

enum VideoInterpolationRate: Int, Codable, CaseIterable, Identifiable, Sendable {
    case doubleRate = 0
    case fps60 = 60
    case fps120 = 120

    var id: Self { self }

    init(persistedValue: Int) {
        switch persistedValue {
        case 0:
            self = .doubleRate
        case 1...75:
            self = .fps60
        case 76...:
            self = .fps120
        default:
            self = .doubleRate
        }
    }

    var persistedValue: Int { rawValue }

    var targetFPS: Int? {
        switch self {
        case .doubleRate: nil
        case .fps60: 60
        case .fps120: 120
        }
    }

    var label: String {
        switch self {
        case .doubleRate: String(localized: "2× Source Frame Rate")
        case .fps60: String(localized: "Up to 60 fps")
        case .fps120: String(localized: "Up to 120 fps")
        }
    }

    var shortStatsLabel: String {
        switch self {
        case .doubleRate: "2×"
        case .fps60: "60 fps"
        case .fps120: "120 fps"
        }
    }
}

enum VideoSuperResolutionScale: Int, Codable, CaseIterable, Identifiable, Sendable {
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

enum VideoSuperResolutionSharpness: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case light
    case standard
    case strong

    var id: Self { self }

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .light: String(localized: "VideoEnhancementSharpnessLight", defaultValue: "Light")
        case .standard: String(localized: "Standard")
        case .strong: String(localized: "Strong")
        }
    }

    var rcasStrength: Float {
        switch self {
        case .off: 0
        case .light: 0.45
        case .standard: 0.80
        case .strong: 1.00
        }
    }
}

struct VideoSuperResolutionDimensions: Equatable, Hashable, Sendable {
    let width: Int
    let height: Int
}

enum VideoSuperResolutionTargetOutcome: Equatable, Sendable {
    case output(VideoSuperResolutionDimensions)
    case alreadyAtOrAboveTarget
    case exceedsRasterBudget
}

enum VideoSuperResolutionTargetResolution: Equatable, Hashable, Codable, Sendable {
    case auto
    case p1080
    case p1440
    case p2160
    case custom(Int)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        self.init(persistedValue: raw)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }

    static let minimumCustomShortEdge = 720
    static let maximumCustomShortEdge = 2160
    static let customStep = 60

    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case auto
        case p1080
        case p1440
        case p2160
        case custom

        var id: Self { self }

        var label: String {
            switch self {
            case .auto: String(localized: "Auto (Screen)")
            case .p1080: "1080p"
            case .p1440: String(localized: "1440p (2K)")
            case .p2160: String(localized: "2160p (4K)")
            case .custom: String(localized: "Custom")
            }
        }
    }

    static func clampedCustomShortEdge(_ shortEdge: Int) -> Int {
        let clamped = min(maximumCustomShortEdge, max(minimumCustomShortEdge, shortEdge))
        return max(2, (clamped / 2) * 2)
    }

    static func fromShortEdge(_ shortEdge: Int) -> Self {
        let normalized = clampedCustomShortEdge(shortEdge)
        switch normalized {
        case 1080: return .p1080
        case 1440: return .p1440
        case 2160: return .p2160
        default: return .custom(normalized)
        }
    }

    init(persistedValue: Int) {
        guard persistedValue > 0 else {
            self = .auto
            return
        }
        self = Self.fromShortEdge(persistedValue)
    }

    var persistedValue: Int { shortEdge ?? 0 }

    var shortEdge: Int? {
        switch self {
        case .auto: nil
        case .p1080: 1080
        case .p1440: 1440
        case .p2160: 2160
        case let .custom(value): Self.clampedCustomShortEdge(value)
        }
    }

    var isManual: Bool { shortEdge != nil }

    var preset: Preset {
        switch self {
        case .auto: .auto
        case .p1080: .p1080
        case .p1440: .p1440
        case .p2160: .p2160
        case .custom: .custom
        }
    }

    var label: String {
        switch self {
        case .auto: String(localized: "Auto (Screen)")
        case .p1080: "1080p"
        case .p1440: String(localized: "1440p (2K)")
        case .p2160: String(localized: "2160p (4K)")
        case let .custom(value): "\(Self.clampedCustomShortEdge(value))p"
        }
    }

    static func customDefault(from current: Self) -> Self {
        switch current {
        case .custom: current
        case .auto, .p1080: .custom(1200)
        case .p1440: .custom(1620)
        case .p2160: .custom(1800)
        }
    }

    /// Resolves aspect-preserving even output dimensions for MetalFX Spatial within
    /// `VideoSuperResolutionRasterBudget` (3840×2160) and MetalFX's 4× scale cap.
    static func resolveMetalFXOutput(
        inputWidth: Int,
        inputHeight: Int,
        targetShortEdge: Int
    ) -> VideoSuperResolutionTargetOutcome {
        guard inputWidth > 0, inputHeight > 0, targetShortEdge > 0,
              VideoSuperResolutionRasterBudget.contains(width: inputWidth, height: inputHeight) else {
            return .exceedsRasterBudget
        }
        let inputShort = min(inputWidth, inputHeight)
        guard inputShort < targetShortEdge else {
            return .alreadyAtOrAboveTarget
        }
        let inputLong = max(inputWidth, inputHeight)
        let desiredScale = Double(targetShortEdge) / Double(inputShort)
        let maxEdgeScale = Double(VideoSuperResolutionRasterBudget.longestEdge) / Double(inputLong)
        let maxAreaScale = (Double(VideoSuperResolutionRasterBudget.pixelCount)
            / Double(inputWidth * inputHeight)).squareRoot()
        let scale = min(desiredScale, 4.0, maxEdgeScale, maxAreaScale)
        guard scale.isFinite, scale > 1.0 else {
            return .exceedsRasterBudget
        }

        func evenNearest(_ value: Double) -> Int { max(2, Int((value / 2.0).rounded()) * 2) }
        func evenDown(_ value: Double) -> Int { max(2, Int((value / 2.0).rounded(.down)) * 2) }

        var outWidth = evenNearest(Double(inputWidth) * scale)
        var outHeight = evenNearest(Double(inputHeight) * scale)
        if !VideoSuperResolutionRasterBudget.contains(width: outWidth, height: outHeight) {
            outWidth = evenDown(Double(inputWidth) * scale)
            outHeight = evenDown(Double(inputHeight) * scale)
        }
        guard outWidth > inputWidth, outHeight > inputHeight,
              VideoSuperResolutionRasterBudget.contains(width: outWidth, height: outHeight) else {
            return .exceedsRasterBudget
        }
        return .output(VideoSuperResolutionDimensions(width: outWidth, height: outHeight))
    }
}

enum VideoEnhancementMaxInputResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case p1080 = "1080p"
    case p1440 = "1440p"
    case unlimited = "unlimited"

    var id: Self { self }

    var label: String {
        switch self {
        case .p1080: String(localized: "Up to 1080p")
        case .p1440: String(localized: "Up to 1440p (2K)")
        case .unlimited: String(localized: "Up to 4K (Unlimited)")
        }
    }

    var bypassReason: String {
        switch self {
        case .p1080: "Resolution > 1080p"
        case .p1440: "Resolution > 1440p"
        case .unlimited: "Resolution > 4K"
        }
    }

    func contains(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        switch self {
        case .p1080:
            // Include standard 1920x1080, 16-aligned 1920x1088, DCI 2048x1080, and 21:9 cinema 1080p (up to 2560x1080).
            return shortEdge <= 1088 && longEdge <= 2560 && (width * height) <= (2560 * 1088)
        case .p1440:
            return shortEdge <= 1448 && longEdge <= 3440 && (width * height) <= (3440 * 1448)
        case .unlimited:
            return VideoSuperResolutionRasterBudget.contains(width: width, height: height)
        }
    }
}

enum VideoEnhancementConfigurationChange: Equatable, Sendable {
    case unchanged
    case shaderUniformOnly
    case interpolationBackendAliasOnly
    case interpolationBackendHotSwap(
        outgoing: VideoFrameInterpolationBackend,
        incoming: VideoFrameInterpolationBackend
    )
    case fullPipelineReset
}

struct VideoEnhancementConfiguration: Equatable, Codable, Sendable {
    var superResolutionMode: VideoSuperResolutionMode = .off
    var frameInterpolationEnabled: Bool = false
    var frameInterpolationBackend: VideoFrameInterpolationBackend = .auto
    var interpolationRate: VideoInterpolationRate = .doubleRate
    /// Locks optical flow to its highest quality profile (`540p .medium`), expands lookahead runway
    /// (`0.45s`), and ignores `.fair`/`.serious` thermal & worker-busy step-downs (retaining only `.critical` OS safety).
    var forceFrameInterpolation: Bool = false
    var superResolutionScale: VideoSuperResolutionScale = .two
    var superResolutionTargetResolution: VideoSuperResolutionTargetResolution = .auto
    var superResolutionSharpness: VideoSuperResolutionSharpness = .standard
    /// Real-time split-screen A/B comparison (left: bilinear original, right: MetalFX + RCAS).
    var superResolutionSplitCompare: Bool = false
    var maxInputResolution: VideoEnhancementMaxInputResolution = .p1080
    var isLiveStream: Bool = false
    /// Cap SR output to the on-screen pixel size (and skip SR when it would not be visible).
    /// Applies to MetalFX Auto mode; explicit MetalFX target resolutions override it.
    var limitToScreenResolution: Bool = true

    static let disabled = Self()

    init(
        superResolutionMode: VideoSuperResolutionMode = .off,
        frameInterpolationEnabled: Bool = false,
        frameInterpolationBackend: VideoFrameInterpolationBackend = .auto,
        interpolationRate: VideoInterpolationRate = .doubleRate,
        forceFrameInterpolation: Bool = false,
        superResolutionScale: VideoSuperResolutionScale = .two,
        superResolutionTargetResolution: VideoSuperResolutionTargetResolution = .auto,
        superResolutionSharpness: VideoSuperResolutionSharpness = .standard,
        superResolutionSplitCompare: Bool = false,
        maxInputResolution: VideoEnhancementMaxInputResolution = .p1080,
        isLiveStream: Bool = false,
        limitToScreenResolution: Bool = true
    ) {
        self.superResolutionMode = superResolutionMode
        self.frameInterpolationEnabled = frameInterpolationEnabled
        self.frameInterpolationBackend = frameInterpolationBackend
        self.interpolationRate = interpolationRate
        self.forceFrameInterpolation = forceFrameInterpolation
        self.superResolutionScale = superResolutionScale
        self.superResolutionTargetResolution = superResolutionTargetResolution
        self.superResolutionSharpness = superResolutionSharpness
        self.superResolutionSplitCompare = superResolutionSplitCompare
        self.maxInputResolution = maxInputResolution
        self.isLiveStream = isLiveStream
        self.limitToScreenResolution = limitToScreenResolution
    }

    private enum CodingKeys: String, CodingKey {
        case superResolutionMode
        case frameInterpolationEnabled
        case frameInterpolationBackend
        case interpolationRate
        case forceFrameInterpolation
        case superResolutionScale
        case superResolutionTargetResolution
        case superResolutionSharpness
        case superResolutionSplitCompare
        case maxInputResolution
        case isLiveStream
        case limitToScreenResolution
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        superResolutionMode = try container.decodeIfPresent(
            VideoSuperResolutionMode.self, forKey: .superResolutionMode
        ) ?? .off
        frameInterpolationEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .frameInterpolationEnabled
        ) ?? false
        if let rawBackend = try container.decodeIfPresent(String.self, forKey: .frameInterpolationBackend) {
            frameInterpolationBackend = VideoFrameInterpolationBackend(persistedValue: rawBackend) ?? .auto
        } else {
            frameInterpolationBackend = .auto
        }
        interpolationRate = try container.decodeIfPresent(
            VideoInterpolationRate.self, forKey: .interpolationRate
        ) ?? .doubleRate
        forceFrameInterpolation = try container.decodeIfPresent(
            Bool.self, forKey: .forceFrameInterpolation
        ) ?? false
        superResolutionScale = try container.decodeIfPresent(
            VideoSuperResolutionScale.self, forKey: .superResolutionScale
        ) ?? .two
        superResolutionTargetResolution = try container.decodeIfPresent(
            VideoSuperResolutionTargetResolution.self, forKey: .superResolutionTargetResolution
        ) ?? .auto
        superResolutionSharpness = try container.decodeIfPresent(
            VideoSuperResolutionSharpness.self, forKey: .superResolutionSharpness
        ) ?? .standard
        superResolutionSplitCompare = try container.decodeIfPresent(
            Bool.self, forKey: .superResolutionSplitCompare
        ) ?? false
        maxInputResolution = try container.decodeIfPresent(
            VideoEnhancementMaxInputResolution.self, forKey: .maxInputResolution
        ) ?? .p1080
        isLiveStream = try container.decodeIfPresent(Bool.self, forKey: .isLiveStream) ?? false
        limitToScreenResolution = try container.decodeIfPresent(
            Bool.self, forKey: .limitToScreenResolution
        ) ?? true
    }

    var isRequested: Bool {
        superResolutionMode != .off || frameInterpolationEnabled
    }

    var isForceInterpolationActive: Bool {
        frameInterpolationEnabled && forceFrameInterpolation
    }

    var resolvedFrameInterpolationBackend: VideoFrameInterpolationBackend {
        resolvedFrameInterpolationBackend()
    }

    func resolvedFrameInterpolationBackend(
        vtSupported: Bool = VideoEnhancementCapabilities.supportsVideoToolboxFrameInterpolation
    ) -> VideoFrameInterpolationBackend {
        frameInterpolationBackend.resolved(vtSupported: vtSupported)
    }

    static var selectableFrameInterpolationBackends: [VideoFrameInterpolationBackend] {
        VideoFrameInterpolationBackend.selectableBackends()
    }

    static func selectableFrameInterpolationBackends(
        vtSupported: Bool
    ) -> [VideoFrameInterpolationBackend] {
        VideoFrameInterpolationBackend.selectableBackends(vtSupported: vtSupported)
    }

    /// Returns `true` when changing from `other` only alters live per-frame uniforms or force-interpolation
    /// policy (`superResolutionSharpness`, `superResolutionSplitCompare`, or `forceFrameInterpolation`)
    /// and requires zero pipeline flush.
    func isShaderUniformOnlyChange(from other: Self) -> Bool {
        superResolutionMode == other.superResolutionMode
            && frameInterpolationEnabled == other.frameInterpolationEnabled
            && frameInterpolationBackend == other.frameInterpolationBackend
            && interpolationRate == other.interpolationRate
            && superResolutionScale == other.superResolutionScale
            && superResolutionTargetResolution == other.superResolutionTargetResolution
            && maxInputResolution == other.maxInputResolution
            && isLiveStream == other.isLiveStream
            && limitToScreenResolution == other.limitToScreenResolution
    }

    /// Returns `true` when changing from `other` only alters `frameInterpolationBackend`
    /// while every other enhancement setting stays identical.
    func isFrameInterpolationBackendOnlyChange(from other: Self) -> Bool {
        frameInterpolationBackend != other.frameInterpolationBackend
            && superResolutionMode == other.superResolutionMode
            && frameInterpolationEnabled == other.frameInterpolationEnabled
            && interpolationRate == other.interpolationRate
            && forceFrameInterpolation == other.forceFrameInterpolation
            && superResolutionScale == other.superResolutionScale
            && superResolutionTargetResolution == other.superResolutionTargetResolution
            && superResolutionSharpness == other.superResolutionSharpness
            && superResolutionSplitCompare == other.superResolutionSplitCompare
            && maxInputResolution == other.maxInputResolution
            && isLiveStream == other.isLiveStream
            && limitToScreenResolution == other.limitToScreenResolution
    }

    func changeKind(
        from other: Self,
        vtSupported: Bool = VideoEnhancementCapabilities.supportsVideoToolboxFrameInterpolation
    ) -> VideoEnhancementConfigurationChange {
        guard self != other else { return .unchanged }
        if isShaderUniformOnlyChange(from: other) {
            return .shaderUniformOnly
        }
        if isFrameInterpolationBackendOnlyChange(from: other) {
            guard frameInterpolationEnabled else { return .interpolationBackendAliasOnly }
            let outgoing = other.resolvedFrameInterpolationBackend(vtSupported: vtSupported)
            let incoming = resolvedFrameInterpolationBackend(vtSupported: vtSupported)
            if outgoing == incoming {
                return .interpolationBackendAliasOnly
            }
            return .interpolationBackendHotSwap(outgoing: outgoing, incoming: incoming)
        }
        return .fullPipelineReset
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
    let metalFXSpatial: VideoEnhancementCapabilityStatus
    let frameInterpolation: VideoEnhancementCapabilityStatus

    static var current: Self {
        Self(
            metalFXSpatial: currentMetalFXSpatialSupport(),
            frameInterpolation: currentFrameInterpolationSupport()
        )
    }

    var supportsVideoToolboxFrameInterpolation: Bool {
        frameInterpolation == .supported
    }

    var selectableFrameInterpolationBackends: [VideoFrameInterpolationBackend] {
        VideoFrameInterpolationBackend.selectableBackends(
            vtSupported: supportsVideoToolboxFrameInterpolation
        )
    }

    static var supportsVideoToolboxFrameInterpolation: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 26.0, *) {
            return VTLowLatencyFrameInterpolationConfiguration.isSupported
        } else {
            return false
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
            if VTLowLatencyFrameInterpolationConfiguration.isSupported {
                return .supported
            }
            return MTLCreateSystemDefaultDevice() != nil ? .supportedVisionFallback : .unsupported
        } else {
            return MTLCreateSystemDefaultDevice() != nil ? .supportedVisionFallback : .unsupported
        }
        #endif
    }
}

enum VideoEnhancementBypassDisplay {
    private static let mappings: [(needles: [String], label: @Sendable () -> String)] = [
        (["> 1080p", ">1080p"], { String(localized: ">1080p") }),
        (["> 1440p", ">1440p"], { String(localized: ">1440p") }),
        (["> 2160p", ">2160p", "> 4k", ">4k"], { String(localized: ">4K") }),
        (["hdr", "10-bit", "log transfer"], { String(localized: "HDR") }),
        (["thermal"], { String(localized: "Thermal") }),
        (["low power"], { String(localized: "Low Power Mode") }),
        (["warming"], { String(localized: "Warming up") }),
        (["memory"], { String(localized: "Memory limited") }),
        (["target resolution"], { String(localized: "Target resolution reached") }),
        (["target frame rate"], { String(localized: "Target FPS reached") }),
        (["display resolution"], { String(localized: "Screen resolution reached") }),
        (["raster budget"], { String(localized: "Max output size") }),
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
        (["ratio unsupported"], { String(localized: "Ratio unsupported") }),
        (["timing gap", "timing invalid"], { String(localized: "Frame timing gap") }),
        (["format changed"], { String(localized: "Format changed") }),
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
        String(format: String(localized: "Paused (%@)"), shortLabel(for: rawReason))
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
    /// Active/resolved frame interpolation backend label (`"VT System"` vs `"Vision Flow"`),
    /// or `nil` when frame interpolation is off.
    var activeFrameInterpolationBackendLabel: String?

    /// Resolves the interpolation engine label (`"VT System"` vs `"Vision Flow"`), preferring
    /// explicit `activeFrameInterpolationBackendLabel` and falling back to tokens in `activeModeLabel`.
    var resolvedFrameInterpolationBackendLabel: String? {
        if let explicit = activeFrameInterpolationBackendLabel, !explicit.isEmpty {
            return explicit
        }
        let tokens = activeModeLabel
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.contains("VT System") || tokens.contains("VT FI") {
            return VideoFrameInterpolationBackend.videoToolbox.telemetryLabel
        }
        if tokens.contains("Vision Flow") || tokens.contains("Vision FI") {
            return VideoFrameInterpolationBackend.visionOpticalFlow.telemetryLabel
        }
        return nil
    }

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
            parts.append(String(format: String(localized: "(Reduced: %@)"),
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
            parts.append(String(format: String(localized: "(Reduced: %@)"),
                                VideoEnhancementBypassDisplay.shortLabel(for: degradationNote)))
        }
        return parts.joined(separator: " ")
    }
}

enum VideoEnhancementPreferences {
    static let defaultSRBackendKey = "experimental_video_enhancement_default_sr_backend"
    static let defaultFrameInterpolationKey = "experimental_video_enhancement_default_frame_interpolation"
    static let frameInterpolationBackendKey = "experimental_video_enhancement_frame_interpolation_backend"
    static let forceFrameInterpolationKey = "experimental_video_enhancement_force_frame_interpolation"

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

    private static let interpolationRateKey = "experimental_video_enhancement_interpolation_rate"
    private static let superResolutionScaleKey = "experimental_video_enhancement_super_resolution_scale"
    private static let superResolutionTargetResolutionKey =
        "experimental_video_enhancement_super_resolution_target_resolution"
    private static let superResolutionSharpnessKey =
        "experimental_video_enhancement_super_resolution_sharpness"
    private static let maxInputResolutionKey = "experimental_video_enhancement_max_input_resolution"

    static var interpolationRate: VideoInterpolationRate {
        get {
            let raw = UserDefaults.standard.integer(forKey: interpolationRateKey)
            return VideoInterpolationRate(persistedValue: raw)
        }
        set { UserDefaults.standard.set(newValue.persistedValue, forKey: interpolationRateKey) }
    }

    static var superResolutionScale: VideoSuperResolutionScale {
        get {
            let raw = UserDefaults.standard.integer(forKey: superResolutionScaleKey)
            return VideoSuperResolutionScale(rawValue: raw) ?? .two
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: superResolutionScaleKey) }
    }

    static var superResolutionTargetResolution: VideoSuperResolutionTargetResolution {
        get {
            let raw = UserDefaults.standard.integer(forKey: superResolutionTargetResolutionKey)
            return VideoSuperResolutionTargetResolution(persistedValue: raw)
        }
        set {
            UserDefaults.standard.set(newValue.persistedValue, forKey: superResolutionTargetResolutionKey)
        }
    }

    static var superResolutionSharpness: VideoSuperResolutionSharpness {
        get {
            UserDefaults.standard.string(forKey: superResolutionSharpnessKey)
                .flatMap(VideoSuperResolutionSharpness.init(rawValue:)) ?? .standard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: superResolutionSharpnessKey) }
    }

    static var maxInputResolution: VideoEnhancementMaxInputResolution {
        get {
            UserDefaults.standard.string(forKey: maxInputResolutionKey)
                .flatMap(VideoEnhancementMaxInputResolution.init(rawValue:)) ?? .p1080
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: maxInputResolutionKey) }
    }

    private static let limitToScreenKey = "experimental_video_enhancement_limit_to_screen"

    static var limitToScreenResolution: Bool {
        get { UserDefaults.standard.object(forKey: limitToScreenKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: limitToScreenKey) }
    }

    static var defaultFrameInterpolationEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: defaultFrameInterpolationKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultFrameInterpolationKey)
        }
    }

    static var frameInterpolationBackend: VideoFrameInterpolationBackend {
        get { loadFrameInterpolationBackend() }
        set { saveFrameInterpolationBackend(newValue) }
    }

    static func loadFrameInterpolationBackend(
        from defaults: UserDefaults = .standard
    ) -> VideoFrameInterpolationBackend {
        guard let raw = defaults.string(forKey: frameInterpolationBackendKey),
              let backend = VideoFrameInterpolationBackend(persistedValue: raw) else {
            return .auto
        }
        return backend
    }

    static func saveFrameInterpolationBackend(
        _ backend: VideoFrameInterpolationBackend,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(backend.persistenceValue, forKey: frameInterpolationBackendKey)
    }

    static var forceFrameInterpolation: Bool {
        get { loadForceFrameInterpolation() }
        set { saveForceFrameInterpolation(newValue) }
    }

    static func loadForceFrameInterpolation(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: forceFrameInterpolationKey)
    }

    static func saveForceFrameInterpolation(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: forceFrameInterpolationKey)
    }
}
