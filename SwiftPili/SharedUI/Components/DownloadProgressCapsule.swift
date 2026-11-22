import SwiftUI

func downloadPercentText(_ fraction: Double) -> String {
    let epsilon = 1e-9
    let scaled = min(max(fraction, 0), 1) * 100 + epsilon
    let percent = min(max(Int(scaled.rounded(.down)), 0), 100)
    return percent.formatted(.percent)
}

func downloadPhaseWord(_ phase: DownloadManager.ActiveDownload.Phase) -> String {
    switch phase {
    case .preparing: String(localized: "Preparing…")
    case .downloadingVideo, .downloadingAudio: String(localized: "Downloading")
    case .retryingVideo, .retryingAudio: String(localized: "Retrying…")
    case .validating: String(localized: "Validating…")
    case .committing: String(localized: "Saving…")
    case .paused: String(localized: "Paused")
    case .failed: ""
    }
}

func downloadRowLeftSlot(
    fraction: Double?, phase: DownloadManager.ActiveDownload.Phase
) -> String {
    fraction.map(downloadPercentText) ?? downloadPhaseWord(phase)
}

func downloadRowRightSlot(
    fraction: Double?, phase: DownloadManager.ActiveDownload.Phase, formattedSpeed: String?
) -> String {
    if let formattedSpeed { return formattedSpeed }
    return fraction != nil ? downloadPhaseWord(phase) : ""
}

extension DownloadManager.ActiveDownload {
    var capsuleHeadline: String {
        switch phase {
        case .downloadingVideo, .downloadingAudio:
            fraction.map(downloadPercentText) ?? downloadPhaseWord(phase)
        case .preparing, .retryingVideo, .retryingAudio, .validating, .committing:
            downloadPhaseWord(phase)
        case .failed, .paused: String(localized: "Downloading")
        }
    }

    var capsuleBarFraction: Double? {
        switch phase {
        case .downloadingVideo, .downloadingAudio: fraction
        default: nil
        }
    }
}

private func capsuleAccessibilityDescription(
    headline: String, othersInFlight: Int
) -> String {
    othersInFlight > 0
        ? String(
            format: String(localized: "%@, and %lld more downloading"),
            headline, othersInFlight
        )
        : headline
}

extension View {
    @ViewBuilder
    func floatingControlSurface<S: Shape>(_ shape: S, enabled: Bool) -> some View {
        if enabled {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
        } else {
            self
        }
    }
}

struct DownloadCapsuleCollapseState: Equatable {
    private(set) var collapsedIDs: Set<String> = []

    func isCollapsed(_ id: String) -> Bool {
        collapsedIDs.contains(id)
    }

    mutating func setCollapsed(_ collapsed: Bool, for id: String) {
        if collapsed {
            collapsedIDs.insert(id)
        } else {
            collapsedIDs.remove(id)
        }
    }

    mutating func purge(activeIDs: [String]) {
        collapsedIDs.formIntersection(activeIDs)
    }
}

struct DownloadProgressCapsuleHost: View {
    let accent: Color
    let open: () -> Void
    var showsSurface = true

    private let manager = DownloadManager.shared

    @State private var collapseState = DownloadCapsuleCollapseState()
    @AppMotion private var motion

    private var presentationAnimation: Animation? {
        motion.animation(normal: .easeInOut(
            duration: AppMotionPolicy.duration(for: .control, reduceMotion: false)
        ))
    }

    private var inFlight: [DownloadManager.ActiveDownload] {
        manager.active.filter { !$0.phase.isResumable }
    }

    private var tracked: DownloadManager.ActiveDownload? {
        inFlight.first
    }

    var body: some View {
        Group {
            if let tracked {
                if collapseState.isCollapsed(tracked.id) {
                    CollapsedDownloadRing(
                        showsSurface: showsSurface,
                        fraction: tracked.capsuleBarFraction,
                        accent: accent,
                        accessibilityDescription: capsuleAccessibilityDescription(
                            headline: tracked.capsuleHeadline,
                            othersInFlight: inFlight.count - 1
                        ),
                        expand: { collapseState.setCollapsed(false, for: tracked.id) }
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(motion.transition(normal: .scale.combined(with: .opacity)))
                } else {
                    DownloadProgressCapsule(
                        showsSurface: showsSurface,
                        item: tracked,
                        othersInFlight: inFlight.count - 1,
                        accent: accent,
                        open: {
                            collapseState.setCollapsed(true, for: tracked.id)
                            open()
                        },
                        collapse: { collapseState.setCollapsed(true, for: tracked.id) }
                    )
                    .transition(motion.transition(normal: .move(edge: .bottom).combined(with: .opacity)))
                }
            }
        }
        .animation(presentationAnimation, value: tracked?.id)
        .animation(presentationAnimation, value: collapseState)
        .onChange(of: inFlight.map(\.id)) { _, ids in
            collapseState.purge(activeIDs: ids)
        }
    }
}

private struct CollapsedDownloadRing: View {
    var showsSurface = true
    let fraction: Double?
    let accent: Color
    let accessibilityDescription: String
    let expand: () -> Void

    private static let diameter: CGFloat = 36

    var body: some View {
        Button(action: expand) {
            Group {
                if let fraction {
                    Gauge(value: fraction) {
                        Text(verbatim: "")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(accent)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .accessibilityHidden(true)
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.appControl)
        .floatingControlSurface(Circle(), enabled: showsSurface)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityHint(Text("Show the full download progress"))
    }
}

struct DownloadProgressCapsule: View {
    var showsSurface = true
    let item: DownloadManager.ActiveDownload
    let othersInFlight: Int
    let accent: Color
    let open: () -> Void
    let collapse: () -> Void

    private var accessibilityDescription: String {
        capsuleAccessibilityDescription(
            headline: item.capsuleHeadline, othersInFlight: othersInFlight
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if item.capsuleBarFraction == nil {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(item.capsuleHeadline)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        if othersInFlight > 0 {
                            Text(verbatim: "+\(othersInFlight)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    if let barFraction = item.capsuleBarFraction {
                        ProgressView(value: barFraction)
                            .tint(accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(Text(accessibilityDescription))
            .accessibilityHint(Text("Open Downloads"))

            Button(action: collapse) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
            .accessibilityLabel(Text("Collapse"))
            .accessibilityHint(Text("Show a smaller progress indicator"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingControlSurface(Capsule(), enabled: showsSurface)
    }
}
