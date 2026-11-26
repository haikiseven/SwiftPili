import SwiftUI

struct PlayerSeekStrip: View {
    let player: PlayerViewModel
    let owner: String
    let isCurrentOwner: Bool
    let gestureDisplay: PlayerGestureDisplay
    let chromeInsets: PlayerChromeInsets
    var inlineCornerRadius: CGFloat = 0
    var suppressScrubPreview = false
    let controlAnimation: Animation?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var stripWidth: CGFloat = 0
    @State private var isVisible = false
    @State private var scrubInteraction: ScrubInteraction?
    @State private var cachedSponsorSegments: [SeekBarSegment] = []
    private var isOwner: Bool { isCurrentOwner && player.ownerKey == owner }

    var body: some View {
        if isOwner, player.mode.isSeekable, player.currentURL != nil,
           !player.isFullscreen || player.showControls || gestureDisplay.isSeeking {
            let interval = samplingInterval(
                sceneIsActive: scenePhase == .active, isVisible: isVisible,
                width: stripWidth, displayScale: displayScale
            )
            let chapterFractions = VideoChapter.tickFractions(
                for: player.videoChapters,
                duration: player.duration
            )
            TimelineView(.animation(minimumInterval: interval ?? 0.25, paused: interval == nil)) { _ in
                let shown = projection(samplingClock: interval != nil)
                CompactSeekBar(
                    progress: shown.progress,
                    buffered: shown.buffered,
                    segments: cachedSponsorSegments,
                    chapterFractions: chapterFractions,
                    isScrubbing: gestureDisplay.isSeeking,
                    prominent: player.showControls,
                    onScrub: updateScrub,
                    onCommit: finishScrub
                )
            }
            .overlay(alignment: .bottomLeading) {
                if gestureDisplay.isSeeking, !suppressScrubPreview, stripWidth > 0 {
                    scrubPreviewOverlay
                }
            }
            .onChange(of: sponsorCacheKey, initial: true) { _, _ in
                cachedSponsorSegments = sponsorBarSegments
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
            .padding(
                .horizontal,
                player.isFullscreen
                    ? ((player.showControls || gestureDisplay.isSeeking) ? chromeInsets.horizontal : 0)
                    : inlineCornerRadius
            )
            .padding(
                .bottom,
                player.isFullscreen && (player.showControls || gestureDisplay.isSeeking)
                    ? chromeInsets.bottom + 14 : 0
            )
            .animation(controlAnimation, value: player.showControls)
            .animation(controlAnimation, value: gestureDisplay.isSeeking)
            .transition(.opacity)
        }
    }

    private var scrubPreviewOverlay: some View {
        let fraction = player.duration > 0
            ? min(max(gestureDisplay.seekValue / player.duration, 0), 1)
            : 0
        let halfWidth: CGFloat = player.isFullscreen ? 96 : 74
        let minCenter = min(halfWidth + 4, stripWidth * 0.5)
        let maxCenter = max(minCenter, stripWidth - halfWidth - 4)
        let clampedCenter = min(max(fraction * stripWidth, minCenter), maxCenter)
        let previewOffsetY: CGFloat = player.isFullscreen
            ? -92
            : (player.showControls ? -72 : -34)
        return PlayerScrubPreviewBubble(player: player, seekTime: gestureDisplay.seekValue)
            .frame(width: halfWidth * 2, alignment: .center)
            .offset(x: clampedCenter - halfWidth, y: previewOffsetY)
            .allowsHitTesting(false)
            .transition(.opacity)
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

    func projection(samplingClock: Bool) -> Projection {
        guard isOwner, player.duration.isFinite, player.duration > 0 else {
            return Projection(progress: 0, buffered: 0)
        }
        let position = player.seekStripDisplayPosition(gestureDisplay: gestureDisplay, samplingClock: samplingClock)
        let end = player.seekStripBufferedEnd ?? 0
        return Projection(progress: position / player.duration, buffered: end / player.duration)
    }

    func samplingInterval(
        sceneIsActive: Bool, isVisible: Bool, width: CGFloat, displayScale: CGFloat
    ) -> TimeInterval? {
        guard sceneIsActive, isVisible, isOwner,
              player.mode.isSeekable, player.currentURL != nil,
              !player.isFullscreen || player.showControls || gestureDisplay.isSeeking,
              player.duration.isFinite, player.duration > 0,
              width.isFinite, width > 0, displayScale.isFinite, displayScale > 0 else { return nil }
        if gestureDisplay.isSeeking { return BufferedTimeUIProjection.defaultCadence }
        guard player.canSampleSeekStripClock,
              player.playbackRate.isFinite, player.playbackRate > 0 else { return nil }
        let pixels = Double(width * displayScale)
        let interval = player.duration / pixels / Double(player.playbackRate)
        return min(max(interval, 1.0 / 60), BufferedTimeUIProjection.defaultCadence)
    }

    private struct SponsorCacheKey: Equatable {
        let usesOnlineVOD: Bool
        let enabled: Bool
        let showOnProgressBar: Bool
        let duration: TimeInterval
        let segmentIDs: [String]
    }

    private var sponsorCacheKey: SponsorCacheKey {
        let manager = SponsorBlockManager.shared
        let usesOnlineVOD = player.mode.usesOnlineVODServices
        guard usesOnlineVOD, manager.isEnabled, manager.showOnProgressBar, player.duration > 0 else {
            return SponsorCacheKey(
                usesOnlineVOD: usesOnlineVOD,
                enabled: manager.isEnabled,
                showOnProgressBar: manager.showOnProgressBar,
                duration: player.duration,
                segmentIDs: []
            )
        }
        return SponsorCacheKey(
            usesOnlineVOD: true,
            enabled: true,
            showOnProgressBar: true,
            duration: player.duration,
            segmentIDs: manager.segments.map(\.uuid)
        )
    }

    private var sponsorBarSegments: [SeekBarSegment] {
        guard player.mode.usesOnlineVODServices, player.duration > 0 else { return [] }
        let manager = SponsorBlockManager.shared
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
