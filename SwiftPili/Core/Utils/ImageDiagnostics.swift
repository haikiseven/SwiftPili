import CoreGraphics
import Foundation

struct ImageSite: Sendable {
    var screen: String
    var component: String

    static let unknown = ImageSite(screen: "?", component: "?")
}

enum ImageDiagnosticsSource: String, Sendable {
    case memory
    case disk
    case network
}

/// Zero-cost no-op facade preserving external diagnostics API while eliminating runtime overhead.
final class ImageDiagnostics: @unchecked Sendable {
    static let shared = ImageDiagnostics()

    static let enabledKey = "image_perf_diagnostics_enabled"
    static let overlayKey = "image_perf_diagnostics_overlay"

    static var isEnabled: Bool { false }
    static var isRecordingImageEvents: Bool { false }
    static var isCapturing: Bool { false }

    nonisolated(unsafe) static var isScrolling = false

    struct Counters: Sendable {
        var body = 0
        var appear = 0
        var gone = 0
        var probe = 0
        var hitMemory = 0
        var hitDisk = 0
        var miss = 0
        var fail = 0
        var indicators = 0
        var hitches = 0
        var setupMicros = 0
        var completionsWhileOffscreen = 0
        var variants = 0
        var distinctImages = 0
        var requestStreams = 0
        var resizes = 0
        var untracked = 0
        var stallsWhileScrolling = 0
        var stallsAtRest = 0
    }

    @MainActor
    static func setEnabled(_ on: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    @MainActor
    static func applyExperimentalPolicy(activateMonitor: Bool = true) {}

    @MainActor
    static func setOverlayEnabled(_ enabled: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        UserDefaults.standard.set(enabled, forKey: overlayKey)
    }

    @MainActor
    static func applyLaunchState() {}

    static func startCapture() {}
    static func stopCapture() {}
    static func clearLog() {}

    func snapshot() -> Counters { Counters() }

    @inline(__always)
    static func noteBody() {}

    @inline(__always)
    static func noteAppear(url: String, rendered: CGSize, at site: ImageSite) {}

    @inline(__always)
    static func noteDisappear(url: String, at site: ImageSite) {}

    @inline(__always)
    static func noteProbe(url: String, rendered: CGSize, at site: ImageSite) {}

    @inline(__always)
    static func measuringSetup<T>(
        url: String,
        rendered: CGSize,
        at site: ImageSite,
        _ work: () -> T
    ) -> T {
        work()
    }

    @inline(__always)
    static func noteCompletion(
        url: String,
        source: ImageDiagnosticsSource,
        pixels: CGSize?,
        rendered: CGSize?,
        at site: ImageSite
    ) {}

    @inline(__always)
    static func noteFailure(url: String, rendered: CGSize?, at site: ImageSite) {}

    @inline(__always)
    static func noteIndicatorShown(shorterSide: CGFloat?) {}

    @inline(__always)
    static func noteHitch(gapMilliseconds: Int, missedSlots: Int) {}

    @inline(__always)
    static func noteCounterSnapshot(windowSeconds: Double, stalls: Int, worstMilliseconds: Int) {}

    func reportText() -> String {
        "SwiftPili image performance diagnostics disabled.\n"
    }
}
