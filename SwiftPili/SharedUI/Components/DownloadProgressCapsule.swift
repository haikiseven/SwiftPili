import SwiftUI

func downloadPercentText(_ fraction: Double) -> String {
    let epsilon = 1e-9
    let scaled = min(max(fraction, 0), 1) * 100 + epsilon
    let percent = min(max(Int(scaled.rounded(.down)), 0), 100)
    return percent.formatted(.percent)
}

func downloadPhaseWord(_ phase: DownloadManager.ActiveDownload.Phase) -> String {
    switch phase {
    case .queued: String(localized: "Waiting…")
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
        case .queued, .preparing, .retryingVideo, .retryingAudio, .validating, .committing:
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

    var capsuleTrimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var capsuleSpeedText: String? {
        switch phase {
        case .downloadingVideo, .downloadingAudio:
            guard let value = speedBytesPerSecond, value.isFinite, value > 0 else { return nil }
            let rounded = value.rounded()
            let readableBytes = rounded >= Double(Int64.max) ? Int64.max : Int64(rounded)
            return "\(ByteCountFormatter.string(fromByteCount: readableBytes, countStyle: .file))/s"
        default:
            return nil
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

private func capsuleAccessibilityLabel(
    item: DownloadManager.ActiveDownload, othersInFlight: Int
) -> String {
    let summary = capsuleAccessibilityDescription(
        headline: item.capsuleHeadline,
        othersInFlight: othersInFlight
    )
    let title = item.capsuleTrimmedTitle
    return title.isEmpty ? summary : "\(title), \(summary)"
}

private func clampedDownloadFraction(_ fraction: Double) -> Double {
    guard fraction.isFinite else { return 0 }
    return min(max(fraction, 0), 1)
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
        inFlight.first(where: { $0.phase.isActivelyRunning }) ?? inFlight.first
    }

    var body: some View {
        Group {
            if let tracked {
                if showsSurface, collapseState.isCollapsed(tracked.id) {
                    CollapsedDownloadRing(
                        showsSurface: true,
                        fraction: tracked.capsuleBarFraction,
                        accent: accent,
                        accessibilityDescription: capsuleAccessibilityLabel(
                            item: tracked,
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
                            if showsSurface {
                                collapseState.setCollapsed(true, for: tracked.id)
                            }
                            open()
                        },
                        collapse: {
                            guard showsSurface else { return }
                            collapseState.setCollapsed(true, for: tracked.id)
                        }
                    )
                    .transition(
                        showsSurface
                            ? motion.transition(normal: .move(edge: .bottom).combined(with: .opacity))
                            : motion.transition(normal: .opacity)
                    )
                }
            }
        }
        .animation(presentationAnimation, value: tracked?.id)
        .animation(showsSurface ? presentationAnimation : nil, value: collapseState)
        .onChange(of: inFlight.map(\.id)) { _, ids in
            collapseState.purge(activeIDs: ids)
        }
    }
}

private struct DownloadProgressRing: View {
    let fraction: Double?
    let accent: Color
    var size: CGFloat = 22
    var lineWidth: CGFloat = 2.25
    var iconSize: CGFloat = 8.5

    @AppMotion private var motion

    var body: some View {
        Group {
            if let fraction {
                let clamped = clampedDownloadFraction(fraction)
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.16), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: CGFloat(clamped))
                        .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.down")
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundStyle(accent)
                }
                .animation(motion.animation(normal: .linear(duration: 0.18)), value: clamped)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
            DownloadProgressRing(
                fraction: fraction,
                accent: accent,
                size: 24,
                lineWidth: 2.5,
                iconSize: 9.5
            )
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.appControl)
        .floatingControlSurface(Circle(), enabled: showsSurface)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityHint(Text("Show the full download progress"))
    }
}

@available(iOS 26.0, *)
private struct TabAccessoryDownloadBar: View {
    let item: DownloadManager.ActiveDownload
    let othersInFlight: Int
    let accent: Color
    let open: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        DownloadAccessoryRow(
            item: item,
            othersInFlight: othersInFlight,
            accent: accent,
            isInlinePlacement: placement == .inline,
            open: open
        )
    }
}

private struct DownloadAccessoryRow: View {
    let item: DownloadManager.ActiveDownload
    let othersInFlight: Int
    let accent: Color
    let isInlinePlacement: Bool
    let open: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var accessibilityLabelText: String {
        capsuleAccessibilityLabel(item: item, othersInFlight: othersInFlight)
    }

    var body: some View {
        let title = item.capsuleTrimmedTitle
        Button(action: open) {
            HStack(spacing: isInlinePlacement ? 8 : 10) {
                DownloadProgressRing(
                    fraction: item.capsuleBarFraction,
                    accent: accent,
                    size: 22,
                    lineWidth: 2.25,
                    iconSize: 8.5
                )

                if isInlinePlacement {
                    Text(item.capsuleHeadline)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if othersInFlight > 0 {
                        Text(verbatim: "+\(othersInFlight)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                } else if !title.isEmpty {
                    Text(title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    expandedTrailingMetrics
                } else {
                    Text(item.capsuleHeadline)
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let speed = item.capsuleSpeedText, !dynamicTypeSize.isAccessibilitySize {
                        Divider()
                            .frame(height: 10)
                            .accessibilityHidden(true)
                        Text(speed)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if othersInFlight > 0 {
                        othersCountBadge
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, isInlinePlacement ? 10 : 14)
            .padding(.vertical, 8)
            .frame(
                maxWidth: .infinity,
                minHeight: isInlinePlacement ? 36 : 40,
                alignment: .leading
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.appControl)
        .foregroundStyle(.primary)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(Text("Open Downloads"))
    }

    private var expandedTrailingMetrics: some View {
        HStack(spacing: 5) {
            Text(item.capsuleHeadline)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let speed = item.capsuleSpeedText, !dynamicTypeSize.isAccessibilitySize {
                Divider()
                    .frame(height: 10)
                    .accessibilityHidden(true)
                Text(speed)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if othersInFlight > 0 {
                othersCountBadge
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .layoutPriority(1)
    }

    private var othersCountBadge: some View {
        Text(verbatim: "+\(othersInFlight)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(AppFill.inset, in: Capsule())
    }
}

struct DownloadProgressCapsule: View {
    var showsSurface = true
    let item: DownloadManager.ActiveDownload
    let othersInFlight: Int
    let accent: Color
    let open: () -> Void
    var collapse: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var accessibilityLabelText: String {
        capsuleAccessibilityLabel(item: item, othersInFlight: othersInFlight)
    }

    var body: some View {
        if showsSurface {
            floatingCapsule
        } else if #available(iOS 26.0, *) {
            TabAccessoryDownloadBar(
                item: item,
                othersInFlight: othersInFlight,
                accent: accent,
                open: open
            )
        } else {
            DownloadAccessoryRow(
                item: item,
                othersInFlight: othersInFlight,
                accent: accent,
                isInlinePlacement: false,
                open: open
            )
        }
    }

    private var floatingCapsule: some View {
        let title = item.capsuleTrimmedTitle
        return HStack(spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if item.capsuleBarFraction == nil {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(accent)
                        }
                        if !title.isEmpty {
                            Text(title)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 6)
                            HStack(spacing: 5) {
                                Text(item.capsuleHeadline)
                                    .font(.footnote.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let speed = item.capsuleSpeedText, !dynamicTypeSize.isAccessibilitySize {
                                    Divider()
                                        .frame(height: 10)
                                        .accessibilityHidden(true)
                                    Text(speed)
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if othersInFlight > 0 {
                                    Text(verbatim: "+\(othersInFlight)")
                                        .font(.caption2.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .layoutPriority(1)
                        } else {
                            Text(item.capsuleHeadline)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .monospacedDigit()
                            if let speed = item.capsuleSpeedText, !dynamicTypeSize.isAccessibilitySize {
                                Divider()
                                    .frame(height: 10)
                                    .accessibilityHidden(true)
                                Text(speed)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if othersInFlight > 0 {
                                Text(verbatim: "+\(othersInFlight)")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    if let barFraction = item.capsuleBarFraction {
                        ProgressView(value: clampedDownloadFraction(barFraction))
                            .tint(accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(Text(accessibilityLabelText))
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
        .floatingControlSurface(Capsule(), enabled: true)
    }
}
