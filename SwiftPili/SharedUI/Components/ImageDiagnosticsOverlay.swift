import SwiftUI

struct ImageDiagnosticsOverlay: View {
    @AppStorage(ImageDiagnostics.enabledKey) private var enabled = false
    @AppStorage(ImageDiagnostics.overlayKey) private var overlayOn = false

    private static let interval: TimeInterval = 0.5

    var body: some View {
        if enabled, overlayOn, ExperimentalSettingsStore.shared.isAllowed(.diagnostics) {
            TimelineView(.periodic(from: .now, by: Self.interval)) { _ in
                readout(ImageDiagnostics.shared.snapshot())
            }
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
            row("images", counters.distinctImages)
            row("streams", counters.requestStreams)
            row("variants", counters.variants,
                alarm: counters.variants > counters.requestStreams)
            row("resizes", counters.resizes, alarm: counters.resizes > 0)
            row("offscreen", counters.completionsWhileOffscreen,
                alarm: counters.completionsWhileOffscreen > 0)
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
