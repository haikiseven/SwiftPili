import SwiftUI

/// The persistent hairline is the clock/buffer observation boundary.
struct PlayerSeekStrip: View {
    let player: PlayerViewModel
    let owner: String
    let isCurrentOwner: Bool
    let gestureDisplay: PlayerGestureDisplay
    let chromeInsets: PlayerChromeInsets
    var inlineCornerRadius: CGFloat = 0
    let controlAnimation: Animation?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var stripWidth: CGFloat = 0
    @State private var isVisible = false
    @State private var scrubInteraction: ScrubInteraction?
    private var isOwner: Bool { isCurrentOwner && player.ownerKey == owner }

    var body: some View {
        if isOwner, player.mode.isSeekable, player.currentURL != nil,
           !player.isFullscreen || player.showControls || gestureDisplay.isSeeking {
            // Keep published dependencies in this child body. Fine repaints
            // below read only existing clock truth, without remapping bands
            // or publishing transport text/stat samples at the faster cadence.
            let published = UIHitchMonitor.measureCounted("strip.body") {
                projection(samplingClock: false)
            }
            let segments = sponsorBarSegments
            let interval = samplingInterval(
                sceneIsActive: scenePhase == .active, isVisible: isVisible,
                width: stripWidth, displayScale: displayScale
            )
            TimelineView(.animation(minimumInterval: interval ?? 0.25, paused: interval == nil)) { _ in
                let shown = interval == nil ? published : UIHitchMonitor.measureCounted("strip.tl") {
                    projection(samplingClock: true)
                }
                CompactSeekBar(
                    progress: shown.progress,
                    buffered: shown.buffered,
                    segments: segments,
                    isScrubbing: gestureDisplay.isSeeking,
                    prominent: player.showControls,
                    onScrub: updateScrub,
                    onCommit: finishScrub
                )
            }
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { stripWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in stripWidth = width }
                }
            }
            .onAppear { isVisible = true }
            .onChange(of: scrubSource) { _, current in
                guard case .active(let source) = scrubInteraction, source != current else { return }
                scrubInteraction = .retired
                gestureDisplay.cancelSeek()
            }
            .onDisappear {
                isVisible = false
                if case .active = scrubInteraction { gestureDisplay.cancelSeek() }
                scrubInteraction = nil
            }
            // Inline, the strip NEVER moves — active is identical to
            // idle; when the inline container is rounded (`inlineCornerRadius`),
            // matching horizontal padding keeps the track and knob inside the
            // rounded bottom corners. Fullscreen has no idle bar, so the chrome
            // insets there keep it off the screen corners.
            .padding(
                .horizontal,
                player.isFullscreen
                    ? ((player.showControls || gestureDisplay.isSeeking) ? chromeInsets.horizontal : 0)
                    : inlineCornerRadius
            )
            // Home-indicator clearance only while the chrome is up or a
            // scrub is in flight — when idle the strip must sit flush on
            // the screen edge, not hover a safe-area above it. The extra
            // +14 in fullscreen lifts the landscape scrubber clear of the
            // very bottom edge (it was overlapping the video boundary) so
            // its margin balances the gap up to the transport row.
            .padding(
                .bottom,
                player.isFullscreen && (player.showControls || gestureDisplay.isSeeking)
                    ? chromeInsets.bottom + 14 : 0
            )
            .animation(controlAnimation, value: player.showControls)
            .animation(controlAnimation, value: gestureDisplay.isSeeking)
            // Fades with the chrome in fullscreen (insertion/removal
            // rides the withAnimation that flips showControls).
            .transition(.opacity)
        }
    }

    private struct ScrubSource: Equatable {
        let owner: PlayerOwnerLease
        let load: Int
        let backend: ObjectIdentifier
        let runtime: UInt64
    }

    private enum ScrubInteraction {
        case active(ScrubSource)
        case retired
    }

    private var scrubSource: ScrubSource? {
        guard isOwner, let lease = player.currentOwnerLease, lease.owner == owner,
              player.currentURL != nil, player.mode.isSeekable else { return nil }
        // In-place opens advance this observed value even on the same URL.
        // The backend runtime identity decides whether the source changed.
        _ = player.playerGeneration
        let backend = player.backend
        return ScrubSource(
            owner: lease, load: player.loadGeneration,
            backend: ObjectIdentifier(backend), runtime: backend.runtimeGeneration
        )
    }

    private func updateScrub(_ fraction: Double) {
        guard let source = scrubSource else { return }
        switch scrubInteraction {
        case .none:
            guard !gestureDisplay.isSeeking else { return }
            scrubInteraction = .active(source)
        case .active(let accepted):
            guard source == accepted, gestureDisplay.isSeeking else { return }
        case .retired:
            return
        }
        gestureDisplay.scrub(fraction: fraction, duration: player.duration)
    }

    private func finishScrub() {
        defer { scrubInteraction = nil }
        guard case .active(let source) = scrubInteraction, gestureDisplay.isSeeking else { return }
        guard source == scrubSource else {
            gestureDisplay.cancelSeek()
            return
        }
        gestureDisplay.commitSeek { player.seek(to: $0) }
    }

    struct Projection: Equatable {
        let progress: Double
        let buffered: Double
    }

    /// Project the playhead or preview and the current buffer evidence independently.
    func projection(samplingClock: Bool) -> Projection {
        guard isOwner, player.duration.isFinite, player.duration > 0 else {
            return Projection(progress: 0, buffered: 0)
        }
        let position = player.seekStripDisplayPosition(gestureDisplay: gestureDisplay, samplingClock: samplingClock)
        let end = player.seekStripBufferedEnd(at: position, isScrubbing: gestureDisplay.isSeeking) ?? 0
        return Projection(progress: position / player.duration, buffered: end / player.duration)
    }

    /// Aim for one physical pixel per read, bounded by the ordinary UI tick
    /// and a 60Hz repaint floor. Dates request repaints; they are never media.
    func samplingInterval(
        sceneIsActive: Bool, isVisible: Bool, width: CGFloat, displayScale: CGFloat
    ) -> TimeInterval? {
        guard sceneIsActive, isVisible, isOwner,
              player.mode.isSeekable, player.currentURL != nil,
              !player.isFullscreen || player.showControls || gestureDisplay.isSeeking,
              !gestureDisplay.isSeeking, player.canSampleSeekStripClock,
              player.duration.isFinite, player.duration > 0,
              width.isFinite, width > 0, displayScale.isFinite, displayScale > 0,
              player.playbackRate.isFinite, player.playbackRate > 0 else { return nil }
        let pixels = Double(width * displayScale)
        let interval = player.duration / pixels / Double(player.playbackRate)
        return min(max(interval, 1.0 / 60), 0.25)
    }

    private var sponsorBarSegments: [SeekBarSegment] {
        guard player.mode.usesOnlineVODServices, player.duration > 0 else { return [] }
        let manager = SponsorBlockManager.shared
        // The strip body reads this on published ticks and on every seek drag;
        // the finer clock-only TimelineView repaints reuse these segments.
        // Skip the maps — and the concatenation — when the bar cannot draw.
        guard manager.isEnabled else { return [] }
        let sourceBands = manager.barSegments
        let sourcePOIs = manager.poiMarkers
        guard !sourceBands.isEmpty || !sourcePOIs.isEmpty else { return [] }
        let bands = sourceBands.map {
            SeekBarSegment(id: $0.uuid, start: $0.start / player.duration,
                           end: $0.end / player.duration, color: $0.category.color, isPOI: false)
        }
        let pois = sourcePOIs.map {
            SeekBarSegment(id: $0.uuid, start: $0.start / player.duration,
                           end: $0.start / player.duration, color: $0.category.color, isPOI: true)
        }
        return bands + pois
    }
}
