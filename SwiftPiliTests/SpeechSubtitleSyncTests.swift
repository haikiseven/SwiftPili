import Foundation
import Testing
@testable import SwiftPili

@Suite("Speech Subtitle Sync & Pacing")
struct SpeechSubtitleSyncTests {
    private static func makeChunk(
        pts: TimeInterval,
        duration: TimeInterval = 1.0,
        sampleRate: Double = 1_000
    ) -> AudioPCMSubtitleChunk {
        let frameCount = max(1, Int((duration * sampleRate).rounded()))
        return AudioPCMSubtitleChunk(
            monoSamples: [Float](repeating: 0.25, count: frameCount),
            pts: pts,
            sampleRate: sampleRate
        )
    }

    @Test("SpeechAudioPacer holds back lookahead chunks and releases them progressively as mediaTime advances")
    func pacerHoldsLookaheadAndFeedsOnMediaTimeAdvance() {
        var pacer = SpeechAudioPacer()
        _ = pacer.updateMediaTime(0.2, now: 100.0)

        // Feed a lookahead burst covering pts = 0, 1, 2, 5, 8, 11 (pts = 2 covers 2.0..3.5 so it stays active at 4.0).
        let burstSpecs: [(pts: TimeInterval, duration: TimeInterval)] = [
            (0.0, 1.0),
            (1.0, 1.0),
            (2.0, 1.5),
            (5.0, 1.0),
            (8.0, 1.0),
            (11.0, 1.0),
        ]
        var initialFed: [TimeInterval] = []
        for spec in burstSpecs {
            let res = pacer.enqueue(Self.makeChunk(pts: spec.pts, duration: spec.duration), now: 100.0)
            #expect(!res.needsSessionReset)
            initialFed.append(contentsOf: res.chunksToFeed.map(\.pts))
        }

        // At mediaTime = 0.2 (lead gate = 1.7), only pts 0 and 1 are released; 2, 5, 8, 11 stay buffered.
        #expect(initialFed == [0.0, 1.0])
        #expect(pacer.pendingChunks.map(\.pts) == [2.0, 5.0, 8.0, 11.0])
        #expect(abs((pacer.latestFedAudioEndPTS ?? -1) - 2.0) < 1e-6)

        // Advancing mediaTime to 4.0 (lead gate = 5.5) feeds pts 2 and 5 while continuing to hold 8 and 11.
        let step1 = pacer.updateMediaTime(4.0, now: 103.8)
        #expect(step1.chunksToFeed.map(\.pts) == [2.0, 5.0])
        #expect(pacer.pendingChunks.map(\.pts) == [8.0, 11.0])
        #expect(abs((pacer.latestFedAudioEndPTS ?? -1) - 6.0) < 1e-6)

        // Advancing mediaTime to 7.0 (lead gate = 8.5) feeds pts 8 and still holds 11.
        let step2 = pacer.updateMediaTime(7.0, now: 106.8)
        #expect(step2.chunksToFeed.map(\.pts) == [8.0])
        #expect(pacer.pendingChunks.map(\.pts) == [11.0])

        // Advancing mediaTime to 10.0 (lead gate = 11.5) releases the final chunk.
        let step3 = pacer.updateMediaTime(10.0, now: 109.8)
        #expect(step3.chunksToFeed.map(\.pts) == [11.0])
        #expect(pacer.pendingChunks.isEmpty)
    }

    @Test("SpeechAudioPacer drops stale chunks behind mediaTime and resets cleanly on seek or PTS jump")
    func pacerDropsStaleChunksAndResetsOnSeek() {
        var pacer = SpeechAudioPacer()
        _ = pacer.updateMediaTime(20.0, now: 10.0)

        // Chunks at 10, 12, 18 (1.0s each) end at 11, 13, 19 < 20.0 - 0.8 (19.2) -> dropped as stale.
        var fedBeforeSeek: [TimeInterval] = []
        for pts in [10.0, 12.0, 18.0, 20.0, 22.0, 25.0] {
            let res = pacer.enqueue(Self.makeChunk(pts: pts, duration: 1.0), now: 10.0)
            fedBeforeSeek.append(contentsOf: res.chunksToFeed.map(\.pts))
        }
        #expect(fedBeforeSeek == [20.0])
        #expect(pacer.pendingChunks.map(\.pts) == [22.0, 25.0])

        // Explicit seek discards pre-seek lookahead chunks and resets fed PTS.
        let seekReset = pacer.handleSeek(to: 50.0, now: 11.0)
        #expect(seekReset.needsSessionReset)
        #expect(seekReset.resetReason == .seek)
        #expect(seekReset.chunksToFeed.isEmpty)
        #expect(pacer.pendingChunks.isEmpty)
        #expect(pacer.latestFedAudioEndPTS == nil)
        #expect(abs((pacer.latestMediaTime ?? -1) - 50.0) < 1e-6)

        // Post-seek chunk feeds immediately without pre-seek leakage.
        let postSeek = pacer.enqueue(Self.makeChunk(pts: 50.0, duration: 1.0), now: 11.1)
        #expect(!postSeek.needsSessionReset)
        #expect(postSeek.chunksToFeed.map(\.pts) == [50.0])

        // Queue future chunk at 54.0, then jump backward via PTS discontinuity -> clears buffer & resets.
        let futureHold = pacer.enqueue(Self.makeChunk(pts: 54.0, duration: 1.0), now: 11.2)
        #expect(futureHold.chunksToFeed.isEmpty)
        #expect(pacer.pendingChunks.map(\.pts) == [54.0])

        let backwardPTS = pacer.enqueue(Self.makeChunk(pts: 5.0, duration: 1.0), now: 11.3)
        #expect(backwardPTS.needsSessionReset)
        #expect(backwardPTS.resetReason == .timelineJump)
        #expect(backwardPTS.chunksToFeed.map(\.pts) == [5.0])
        #expect(pacer.pendingChunks.isEmpty)
    }

    @Test("SpeechAudioPacer interpolates briefly during playback, stops drifting when paused, and paces nil mediaTime")
    func pacerInterpolationPauseHoldAndFallbackClock() {
        var pacer = SpeechAudioPacer()
        _ = pacer.updateMediaTime(10.0, now: 100.0)
        _ = pacer.updateMediaTime(10.2, now: 100.2)

        // 11.9 > 10.2 + 1.5 (11.7) -> held initially.
        let held = pacer.enqueue(Self.makeChunk(pts: 11.9, duration: 1.0), now: 100.2)
        #expect(held.chunksToFeed.isEmpty)

        // 0.25s later (within 0.6s interpolation window): effectiveMediaTime = 10.45 -> 11.9 <= 11.95 -> released!
        let interpolated = pacer.drain(now: 100.45)
        #expect(interpolated.chunksToFeed.map(\.pts) == [11.9])

        // Pause: no mediaTime advance for > 0.6s -> effectiveMediaTime stops at 10.2, never drifting ahead!
        let pausedChunk = pacer.enqueue(Self.makeChunk(pts: 12.1, duration: 1.0), now: 100.5)
        #expect(pausedChunk.chunksToFeed.isEmpty)
        let afterPause = pacer.drain(now: 102.0)
        #expect(afterPause.chunksToFeed.isEmpty)
        #expect(pacer.pendingChunks.map(\.pts) == [12.1])

        // Nil mediaTime fallback: anchors to first finite chunk PTS and paces at 1.0x real time.
        var livePacer = SpeechAudioPacer()
        let first = livePacer.enqueue(Self.makeChunk(pts: 30.0, duration: 1.0), now: 50.0)
        let second = livePacer.enqueue(Self.makeChunk(pts: 31.0, duration: 1.0), now: 50.0)
        let third = livePacer.enqueue(Self.makeChunk(pts: 33.0, duration: 1.0), now: 50.0)
        #expect(first.chunksToFeed.map(\.pts) == [30.0])
        #expect(second.chunksToFeed.map(\.pts) == [31.0])
        #expect(third.chunksToFeed.isEmpty)

        let later = livePacer.drain(now: 52.0)
        #expect(later.chunksToFeed.map(\.pts) == [33.0])
    }

    @Test("Multi-phrase timed volatile updates display each phrase only when playback reaches it")
    func multiPhraseTimedVolatileOrder() {
        let segments: [SpeechSubtitleCueBuilder.TimedSegment] = [
            .init(text: "第一句。", startOffset: 0.0, duration: 1.4),
            .init(text: "第二句。", startOffset: 1.5, duration: 1.5),
            .init(text: "第三句。", startOffset: 3.1, duration: 1.5),
        ]

        // 1. Legacy SFSpeechRecognizer partial path
        let legacyPartial = SpeechSubtitleCueBuilder.buildLegacyPartialUpdate(
            formattedText: "第一句。第二句。第三句。",
            segments: segments,
            basePTS: 0.0,
            windowAudioDuration: 4.6,
            committedSegmentCount: 0,
            lastCommittedEndOffset: 0.0,
            lastPartialEndOffset: 0.0,
            latestFedAudioEndPTS: 4.6
        )
        #expect(legacyPartial.volatileCues.count == 3)

        var legacyStore = SpeechSubtitleTimelineStore()
        legacyStore.apply(
            SpeechRecognitionCueUpdate(
                committedCues: legacyPartial.finalizedBatch,
                volatileCues: legacyPartial.volatileCues
            )
        )
        #expect(legacyStore.activeText(at: -0.1) == nil)
        #expect(legacyStore.activeText(at: 0.5) == "第一句。")
        #expect(legacyStore.activeText(at: 2.0) == "第二句。")
        #expect(legacyStore.activeText(at: 3.5) == "第三句。")

        // 2. iOS 26 SpeechAnalyzer volatile path
        let analyzerUpdate = SpeechSubtitleCueBuilder.buildSpeechAnalyzerUpdate(
            plainText: "第一句。第二句。第三句。",
            timedSegments: segments,
            rangeStartOffset: 0.0,
            rangeDuration: 4.6,
            isFinal: false,
            basePTS: 0.0,
            latestFedAudioEndPTS: 4.6
        )
        #expect(analyzerUpdate.committedCues.isEmpty)
        #expect(analyzerUpdate.volatileCues.count == 3)

        var analyzerStore = SpeechSubtitleTimelineStore()
        analyzerStore.apply(analyzerUpdate)
        #expect(analyzerStore.activeText(at: -0.05) == nil)
        #expect(analyzerStore.activeText(at: 0.5) == "第一句。")
        #expect(analyzerStore.activeText(at: 2.0) == "第二句。")
        #expect(analyzerStore.activeText(at: 3.5) == "第三句。")
    }

    @Test("Zero early lead tolerance prevents volatile cues from appearing before cue.from")
    func zeroVolatileEarlyLeadTolerance() {
        #expect(SpeechSubtitleTimelineStore.defaultVolatileLeadTolerance == 0.0)

        var store = SpeechSubtitleTimelineStore()
        store.setVolatile(.init(from: 3.0, to: 4.5, content: "准时出现"))

        #expect(store.activeCue(at: 2.9) == nil)
        #expect(store.activeText(at: 2.9) == nil)
        #expect(store.activeText(at: 2.999) == nil)
        #expect(store.activeCue(at: 3.0)?.content == "准时出现")
        #expect(store.activeText(at: 3.0) == "准时出现")
        #expect(store.activeText(at: 4.0) == "准时出现")
    }

    @Test("Untimed partials anchor near latestFedAudioEndPTS and split multi-clause text proportionally")
    func untimedPartialsAnchorAndSplitProportionally() {
        // Single untimed tail phrase after 6s of fed audio must NOT stamp back at basePTS (20.0).
        let singleUntimed = SpeechSubtitleCueBuilder.buildLegacyPartialUpdate(
            formattedText: "最新这一句",
            segments: [.init(text: "最新这一句", startOffset: 0, duration: 0)],
            basePTS: 20.0,
            windowAudioDuration: 6.0,
            committedSegmentCount: 0,
            lastCommittedEndOffset: 0.0,
            lastPartialEndOffset: 0.0,
            latestFedAudioEndPTS: 26.0
        )
        #expect(singleUntimed.volatileCues.count == 1)
        #expect(abs((singleUntimed.volatileCue?.from ?? -1) - 24.8) < 1e-6)

        var singleStore = SpeechSubtitleTimelineStore()
        singleStore.apply(SpeechRecognitionCueUpdate(volatileCues: singleUntimed.volatileCues))
        #expect(singleStore.activeText(at: 21.0) == nil)
        #expect(singleStore.activeText(at: 25.0) == "最新这一句")

        // Multi-clause untimed text splits proportionally across [20.0, 26.0].
        let multiUntimed = SpeechSubtitleCueBuilder.buildLegacyPartialUpdate(
            formattedText: "第一句。第二句。第三句。",
            segments: [.init(text: "第一句。第二句。第三句。", startOffset: 0, duration: 0)],
            basePTS: 20.0,
            windowAudioDuration: 6.0,
            committedSegmentCount: 0,
            lastCommittedEndOffset: 0.0,
            lastPartialEndOffset: 0.0,
            latestFedAudioEndPTS: 26.0
        )
        #expect(multiUntimed.volatileCues.count == 3)

        var multiStore = SpeechSubtitleTimelineStore()
        multiStore.apply(SpeechRecognitionCueUpdate(volatileCues: multiUntimed.volatileCues))
        #expect(multiStore.activeText(at: 20.5) == "第一句。")
        #expect(multiStore.activeText(at: 22.5) == "第二句。")
        #expect(multiStore.activeText(at: 24.5) == "第三句。")
    }

    @Test("Monotonic transition from volatile cues to finalized committed cues never regresses or overlaps")
    func monotonicVolatileToCommittedTransition() {
        var store = SpeechSubtitleTimelineStore()

        // Step 1: Receive multi-phrase volatile update.
        store.apply(
            SpeechRecognitionCueUpdate(
                committedCues: [],
                volatileCues: [
                    .init(from: 0.0, to: 1.4, content: "第一句。"),
                    .init(from: 1.5, to: 3.0, content: "第二句。"),
                    .init(from: 3.1, to: 4.8, content: "第三句。"),
                ]
            )
        )
        #expect(store.activeText(at: 0.8) == "第一句。")
        #expect(store.activeText(at: 2.1) == "第二句。")

        // Step 2: Commit first two cues while a volatile update still overlaps the boundary.
        store.apply(
            SpeechRecognitionCueUpdate(
                committedCues: [
                    .init(from: 0.0, to: 1.6, content: "第一句。"),
                    .init(from: 1.5, to: 3.15, content: "第二句。"),
                ],
                volatileCues: [
                    .init(from: 0.0, to: 1.4, content: "第一句。"),
                    .init(from: 1.5, to: 3.0, content: "第二句。"),
                    .init(from: 3.1, to: 4.8, content: "第三句。"),
                ]
            )
        )

        // Committed cues are strictly non-overlapping and monotonic.
        #expect(store.finalizedCues.count == 2)
        #expect(store.finalizedCues[0].to <= store.finalizedCues[1].from + 1e-9)

        // Already-committed volatile cues were pruned; remaining volatile cue clamped to committed end.
        #expect(store.volatileCues.count == 1)
        #expect(store.volatileCues[0].content == "第三句。")
        #expect(store.volatileCues[0].from >= store.finalizedCues[1].to - 1e-9)

        // Playback progresses strictly forward without backward text jump.
        #expect(store.activeText(at: 0.8) == "第一句。")
        #expect(store.activeText(at: 2.1) == "第二句。")
        #expect(store.activeText(at: 3.12) == "第二句。")
        #expect(store.activeText(at: 3.5) == "第三句。")

        // Step 3: Window finalization with replaceCommittedFromPTS replaces tentative cues cleanly.
        store.apply(
            SpeechRecognitionCueUpdate(
                committedCues: [
                    .init(from: 0.0, to: 1.45, content: "第一句。"),
                    .init(from: 1.5, to: 3.05, content: "第二句。"),
                    .init(from: 3.15, to: 4.6, content: "第三句。"),
                ],
                volatileCues: [],
                replaceCommittedFromPTS: 0.0
            )
        )
        #expect(store.finalizedCues.count == 3)
        #expect(store.volatileCues.isEmpty)
        #expect(store.activeText(at: 0.5) == "第一句。")
        #expect(store.activeText(at: 2.0) == "第二句。")
        #expect(store.activeText(at: 4.0) == "第三句。")
    }
}
