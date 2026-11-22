import SwiftUI

/// Compact live counter readout for the image-scroll investigation, shown over
/// the tab content while Settings → Image Diagnostics is armed AND its overlay
/// switch is on.
///
/// **Why it is not expensive.** The thing being measured is scroll smoothness,
/// so an overlay that costs frames would corrupt its own reading. Three
/// properties keep it out of the way:
///
///  1. It refreshes on its own `TimelineView` schedule (`Self.interval`), NOT
///     on the counters changing. Nothing here is `@Observable`, so a scroll
///     producing hundreds of events per second still redraws this at 2 Hz.
///  2. The redraw is confined to this subtree. It reads a value snapshot under
///     one lock and renders fixed-width text — no layout that the scrolling
///     content participates in, and no geometry reader.
///  3. When the toggle is off it is `EmptyView`, so there is no timeline, no
///     schedule, and no view to update.
///
/// It is still an observer effect, just a bounded and constant one. For the
/// cleanest numbers, run one pass with the overlay off and read the exported
/// log instead — the log carries the same counters at every frame-pacing
/// window boundary.
struct ImageDiagnosticsOverlay: View {
    @AppStorage(ImageDiagnostics.enabledKey) private var enabled = false
    @AppStorage(ImageDiagnostics.overlayKey) private var overlayOn = false

    /// 2 Hz: fast enough to watch a counter move during a scroll, slow enough
    /// that the readout itself is never in the frame budget.
    private static let interval: TimeInterval = 0.5

    var body: some View {
        if enabled, overlayOn, ExperimentalSettingsStore.shared.isAllowed(.diagnostics) {
            TimelineView(.periodic(from: .now, by: Self.interval)) { _ in
                readout(ImageDiagnostics.shared.snapshot())
            }
            // Never intercept a scroll — the gesture being measured has to
            // reach the content underneath.
            .allowsHitTesting(false)
        }
    }

    private func readout(_ counters: ImageDiagnostics.Counters) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            row("hitches", counters.hitches, alarm: counters.hitches > 0)
            row("appear", counters.appear)
            row("hit.mem", counters.hitMemory)
            row("hit.disk", counters.hitDisk)
            row("miss", counters.miss)
            row("probe", counters.probe)
            // Compare variants with (picture, call-site) streams: independent
            // layers may legitimately draw one picture at different boxes.
            row("images", counters.distinctImages)
            row("streams", counters.requestStreams)
            row("variants", counters.variants,
                alarm: counters.variants > counters.requestStreams)
            row("resizes", counters.resizes, alarm: counters.resizes > 0)
            // Not in the requested set, but it is the one number that answers
            // the stale-work question at a glance.
            row("offscreen", counters.completionsWhileOffscreen,
                alarm: counters.completionsWhileOffscreen > 0)
            // Stalls split by whether a drag was in flight: an interval with no
            // network and no disk that still stalls is a layout cost, and only
            // this split says so.
            row("stall.scrl", counters.stallsWhileScrolling)
            row("stall.rest", counters.stallsAtRest)
            if ImageDiagnostics.isCapturing {
                Text(verbatim: "● REC")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
    }

    /// `Text(verbatim:)` throughout: these are instrument labels that must read
    /// identically in every locale and in a pasted screenshot, and they are
    /// deliberately the same tokens as the `[hitch]` line and the exported log
    /// so the three can be compared without a translation table.
    private func row(_ label: String, _ value: Int, alarm: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
                .frame(width: 58, alignment: .leading)
                .foregroundStyle(.white.opacity(0.75))
            Text(verbatim: "\(value)")
                .foregroundStyle(alarm ? .orange : .white)
        }
        .font(.system(size: 10, design: .monospaced))
        .monospacedDigit()
    }
}
