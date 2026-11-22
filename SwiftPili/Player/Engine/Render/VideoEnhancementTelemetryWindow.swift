import Foundation

/// Rolling per-original-frame record of what enhancement actually reached the screen.
///
/// Telemetry used to be a snapshot of the most recent frame only. Under partial load (SR lands on
/// every frame, interpolation on some, a few frames time out) every UI sample landed on a different
/// state, so the stats overlay and player menu flickered between "MetalFX", "Interpolation",
/// "both" and "Paused". Summarising a short window gives stable labels plus real success ratios.
struct VideoEnhancementTelemetryWindow {
    struct Sample {
        let at: ContinuousClock.Instant
        let upscaled: Bool
        let midpoints: Int
        let missReason: String?
        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int
    }

    var span: Duration = .seconds(1)
    private var samples: [Sample] = []
    private var startedAt: ContinuousClock.Instant?

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        startedAt = nil
    }

    mutating func record(_ sample: Sample) {
        if startedAt == nil { startedAt = sample.at }
        samples.append(sample)
        let cutoff = sample.at.advanced(by: .zero - span)
        if let firstKept = samples.firstIndex(where: { $0.at > cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    /// Returns `nil` when no frame was presented recently (paused, seeking, disabled); callers
    /// then fall back to the latest per-frame state.
    func summarize(
        latest: VideoEnhancementTelemetry,
        configuration: VideoEnhancementConfiguration,
        interpolationLabel: String,
        now: ContinuousClock.Instant = .now
    ) -> VideoEnhancementTelemetry? {
        let cutoff = now.advanced(by: .zero - span)
        let recent = samples.filter { $0.at > cutoff }
        guard let last = recent.last, let startedAt else { return nil }
        let count = recent.count
        let upscaled = recent.filter(\.upscaled).count
        let interpolated = recent.filter { $0.midpoints > 0 }.count
        let midpoints = recent.reduce(0) { $0 + $1.midpoints }

        var summary = latest
        var labels: [String] = []
        if upscaled > 0 { labels.append(configuration.superResolutionMode.telemetryLabel) }
        if interpolated > 0 { labels.append(interpolationLabel) }
        summary.isActive = !labels.isEmpty
        summary.activeModeLabel = labels.isEmpty ? "Bypass" : labels.joined(separator: " + ")
        summary.superResolutionShare = configuration.superResolutionMode != .off
            ? Double(upscaled) / Double(count) : nil
        summary.interpolationShare = configuration.frameInterpolationEnabled
            ? Double(interpolated) / Double(count) : nil

        let reason = Self.mostCommon(recent.compactMap(\.missReason))
        summary.bypassReason = summary.isActive ? nil : (reason ?? latest.bypassReason)
        let fullyApplied = (summary.superResolutionShare ?? 1) >= 0.95 && (summary.interpolationShare ?? 1) >= 0.95
        summary.partialReason = summary.isActive && !fullyApplied ? (reason ?? "Enhancement not admitted") : nil

        summary.inputWidth = last.inputWidth
        summary.inputHeight = last.inputHeight
        let lastUpscaled = recent.last(where: \.upscaled)
        summary.outputWidth = lastUpscaled?.outputWidth ?? last.inputWidth
        summary.outputHeight = lastUpscaled?.outputHeight ?? last.inputHeight

        let elapsed = min(span, startedAt.duration(to: now))
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if seconds >= 0.25 {
            summary.inputFPS = Double(count) / seconds
            summary.outputFPS = Double(count + midpoints) / seconds
        } else {
            summary.inputFPS = 0
            summary.outputFPS = 0
        }
        return summary
    }

    private static func mostCommon(_ reasons: [String]) -> String? {
        guard !reasons.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for reason in reasons { counts[reason, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }
}
