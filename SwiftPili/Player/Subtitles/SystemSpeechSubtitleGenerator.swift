import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

/// Non-isolated Objective-C completion bridge for `SFSpeechRecognizer.requestAuthorization`.
///
/// Keeping this outside `@MainActor` guarantees Swift 6 never injects a `_swift_task_checkIsolatedSwift`
/// main-queue assertion on Apple's background TCC/XPC callback queue.
private enum SpeechAuthorizationBridge {
    static func requestIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            SFSpeechRecognizer.requestAuthorization { status in
                let shouldResume = resumed.withLock { alreadyResumed -> Bool in
                    guard !alreadyResumed else { return false }
                    alreadyResumed = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: status)
                }
            }
        }
    }
}

enum LegacySpeechErrorDisposition: Equatable, Sendable {
    case fallbackToServer
    case ignoreBenignSilence
    case ignoreCancellation
    case countFailure

    static func classify(
        domain: String,
        code: Int,
        preferOnDevice: Bool,
        hasProducedResultWithOnDevice: Bool,
        hasProducedResultInWindow: Bool
    ) -> Self {
        if (domain == NSCocoaErrorDomain && code == NSUserCancelledError)
            || (domain == "kAFAssistantErrorDomain" && (code == 209 || code == 216)) {
            return .ignoreCancellation
        }
        // kAFAssistantErrorDomain 1110 = "No speech detected" during silent passages.
        if domain == "kAFAssistantErrorDomain" && code == 1110 {
            return .ignoreBenignSilence
        }
        // On real devices, supportsOnDeviceRecognition may report true while local Siri assets
        // fail immediately (e.g. kAFAssistantErrorDomain 1101 / 203 / 1107). Fall back right away.
        if preferOnDevice && !hasProducedResultWithOnDevice && !hasProducedResultInWindow {
            return .fallbackToServer
        }
        return .countFailure
    }
}

enum SpeechSubtitleEngineKind: String, Sendable, Equatable {
    case speechAnalyzer
    case legacyOnDeviceRecognizer
    case legacyServerRecognizer

    var displayLabel: String {
        switch self {
        case .speechAnalyzer:
            String(localized: "iOS 26 SpeechAnalyzer")
        case .legacyOnDeviceRecognizer:
            String(localized: "On-Device Speech")
        case .legacyServerRecognizer:
            String(localized: "System Speech")
        }
    }
}

enum SpeechSubtitleStatus: Equatable, Sendable {
    case idle
    case preparing
    case downloadingModel(progress: Double?)
    case active(engine: SpeechSubtitleEngineKind, localeIdentifier: String)
    case unsupportedBackend
    case permissionDenied
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .preparing, .downloadingModel, .active:
            true
        case .idle, .unsupportedBackend, .permissionDenied, .failed:
            false
        }
    }
}

/// Atomic update emitted by a speech recognition engine for finalized and volatile cues.
struct SpeechRecognitionCueUpdate: Sendable {
    let committedCues: [PlayerViewModel.SubtitleCue]
    let volatileCues: [PlayerViewModel.SubtitleCue]
    let replaceCommittedFromPTS: TimeInterval?
    let clearAll: Bool

    var volatileCue: PlayerViewModel.SubtitleCue? {
        volatileCues.last
    }

    init(
        committedCues: [PlayerViewModel.SubtitleCue] = [],
        volatileCues: [PlayerViewModel.SubtitleCue] = [],
        replaceCommittedFromPTS: TimeInterval? = nil,
        clearAll: Bool = false
    ) {
        self.committedCues = committedCues
        self.volatileCues = volatileCues
        self.replaceCommittedFromPTS = replaceCommittedFromPTS
        self.clearAll = clearAll
    }

    init(
        committedCues: [PlayerViewModel.SubtitleCue],
        volatileCue: PlayerViewModel.SubtitleCue?,
        replaceCommittedFromPTS: TimeInterval? = nil,
        clearAll: Bool = false
    ) {
        self.init(
            committedCues: committedCues,
            volatileCues: volatileCue.map { [$0] } ?? [],
            replaceCommittedFromPTS: replaceCommittedFromPTS,
            clearAll: clearAll
        )
    }
}

/// Pure, testable media-time pacing gate for decoded lookahead PCM audio.
///
/// Decoders often decode 10-15s of audio ahead of current playback `mediaTime`. Feeding those
/// future chunks immediately lets speech recognizers transcribe speech seconds before the user
/// hears it. `SpeechAudioPacer` buffers lookahead chunks in chronological `pts` order and only
/// releases chunks up to `effectiveMediaTime + maxFeedLeadSeconds` (default 1.5s).
struct SpeechAudioPacer: Sendable {
    static let defaultMaxFeedLeadSeconds: TimeInterval = 1.5
    static let defaultStaleDropBehindSeconds: TimeInterval = 0.8
    static let defaultMaxBufferedDuration: TimeInterval = 25.0
    static let defaultInterpolationWindowSeconds: TimeInterval = 0.6
    static let defaultMaxInterpolationLeadSeconds: TimeInterval = 0.3
    static let defaultBackwardMediaJumpThreshold: TimeInterval = 0.8
    static let defaultForwardMediaJumpThreshold: TimeInterval = 1.8
    static let defaultBackwardChunkPTSJumpThreshold: TimeInterval = 1.0

    struct DrainResult: Sendable {
        let chunksToFeed: [AudioPCMSubtitleChunk]
        let needsSessionReset: Bool
        let resetReason: AudioPCMSubtitleDiscontinuityReason?
        let resetTargetPTS: TimeInterval?

        static let empty = DrainResult(
            chunksToFeed: [],
            needsSessionReset: false,
            resetReason: nil,
            resetTargetPTS: nil
        )
    }

    let maxFeedLeadSeconds: TimeInterval
    let staleDropBehindSeconds: TimeInterval
    let maxBufferedDuration: TimeInterval

    private(set) var latestMediaTime: TimeInterval?
    private(set) var latestFedAudioEndPTS: TimeInterval?
    private(set) var pendingChunks: [AudioPCMSubtitleChunk] = []
    private(set) var bufferedDuration: TimeInterval = 0

    private var lastEnqueuedPTS: TimeInterval?
    private var lastMediaAdvanceWallTime: TimeInterval?
    private var fallbackAnchorPTS: TimeInterval?
    private var fallbackAnchorWallTime: TimeInterval?

    init(
        maxFeedLeadSeconds: TimeInterval = SpeechAudioPacer.defaultMaxFeedLeadSeconds,
        staleDropBehindSeconds: TimeInterval = SpeechAudioPacer.defaultStaleDropBehindSeconds,
        maxBufferedDuration: TimeInterval = SpeechAudioPacer.defaultMaxBufferedDuration
    ) {
        self.maxFeedLeadSeconds = max(0.1, maxFeedLeadSeconds)
        self.staleDropBehindSeconds = max(0, staleDropBehindSeconds)
        self.maxBufferedDuration = max(2.0, maxBufferedDuration)
    }

    var pendingChunkCount: Int {
        pendingChunks.count
    }

    func effectiveMediaTime(at now: TimeInterval) -> TimeInterval? {
        if let mediaTime = latestMediaTime {
            if let advanceWall = lastMediaAdvanceWallTime {
                let elapsed = max(0, now - advanceWall)
                if elapsed <= Self.defaultInterpolationWindowSeconds {
                    return mediaTime + min(elapsed, Self.defaultMaxInterpolationLeadSeconds)
                }
            }
            return mediaTime
        }
        if let anchorPTS = fallbackAnchorPTS, let anchorWall = fallbackAnchorWallTime {
            return anchorPTS + max(0, now - anchorWall)
        }
        return nil
    }

    mutating func reset() {
        pendingChunks.removeAll(keepingCapacity: false)
        bufferedDuration = 0
        latestMediaTime = nil
        latestFedAudioEndPTS = nil
        lastEnqueuedPTS = nil
        lastMediaAdvanceWallTime = nil
        fallbackAnchorPTS = nil
        fallbackAnchorWallTime = nil
    }

    mutating func handleSeek(
        to time: TimeInterval?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DrainResult {
        _ = now
        clearBufferAndAnchors()
        if let time, time.isFinite, time >= 0 {
            latestMediaTime = time
        } else {
            latestMediaTime = nil
        }
        return DrainResult(
            chunksToFeed: [],
            needsSessionReset: true,
            resetReason: .seek,
            resetTargetPTS: latestMediaTime
        )
    }

    mutating func handleDiscontinuity(
        reason: AudioPCMSubtitleDiscontinuityReason,
        targetPTS: TimeInterval?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DrainResult {
        _ = now
        clearBufferAndAnchors()
        if let targetPTS, targetPTS.isFinite, targetPTS >= 0 {
            latestMediaTime = targetPTS
        } else {
            // Clear stale pre-seek media time so newly decoded post-seek chunks are never dropped.
            latestMediaTime = nil
        }
        return DrainResult(
            chunksToFeed: [],
            needsSessionReset: true,
            resetReason: reason,
            resetTargetPTS: latestMediaTime
        )
    }

    mutating func updateMediaTime(
        _ time: TimeInterval,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DrainResult {
        guard time.isFinite, time >= 0 else { return .empty }

        if let previous = latestMediaTime {
            if time < previous - Self.defaultBackwardMediaJumpThreshold {
                return handleSeek(to: time, now: now)
            }
            if time > previous + 1e-4 {
                latestMediaTime = time
                lastMediaAdvanceWallTime = now
            } else {
                // Stationary or paused tick: do not refresh advance wall time so interpolation stops.
                latestMediaTime = time
            }
            if time > previous + Self.defaultForwardMediaJumpThreshold {
                let hasCoverageInWindow = pendingChunks.contains { chunk in
                    chunk.endPTS >= time - staleDropBehindSeconds
                        && chunk.pts <= time + maxFeedLeadSeconds
                }
                if !hasCoverageInWindow {
                    clearBufferAndAnchors()
                    latestMediaTime = time
                    return DrainResult(
                        chunksToFeed: [],
                        needsSessionReset: true,
                        resetReason: .seek,
                        resetTargetPTS: time
                    )
                }
            }
        } else {
            if let fedEnd = latestFedAudioEndPTS,
               time < fedEnd - 2.0 || time > fedEnd + 2.5 {
                return handleSeek(to: time, now: now)
            }
            latestMediaTime = time
            lastMediaAdvanceWallTime = nil
            fallbackAnchorPTS = nil
            fallbackAnchorWallTime = nil
        }

        return drain(now: now)
    }

    mutating func enqueue(
        _ chunk: AudioPCMSubtitleChunk,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DrainResult {
        guard !chunk.monoSamples.isEmpty,
              chunk.sampleRate.isFinite,
              chunk.sampleRate > 0 else {
            return .empty
        }
        guard chunk.pts.isFinite else {
            return DrainResult(
                chunksToFeed: [chunk],
                needsSessionReset: false,
                resetReason: nil,
                resetTargetPTS: nil
            )
        }

        var forcedReset: (reason: AudioPCMSubtitleDiscontinuityReason, targetPTS: TimeInterval?)?
        if let lastEnq = lastEnqueuedPTS,
           chunk.pts < lastEnq - Self.defaultBackwardChunkPTSJumpThreshold {
            clearBufferAndAnchors()
            if let mediaTime = latestMediaTime,
               mediaTime > chunk.pts + Self.defaultForwardMediaJumpThreshold {
                latestMediaTime = nil
            }
            forcedReset = (.timelineJump, chunk.pts)
        }

        if latestMediaTime == nil && fallbackAnchorPTS == nil {
            fallbackAnchorPTS = chunk.pts
            fallbackAnchorWallTime = now
        }

        if forcedReset == nil,
           let fedEnd = latestFedAudioEndPTS,
           chunk.endPTS <= fedEnd + 1e-4 {
            return .empty
        }

        if let eff = effectiveMediaTime(at: now),
           chunk.endPTS < eff - staleDropBehindSeconds {
            if let forcedReset {
                return DrainResult(
                    chunksToFeed: [],
                    needsSessionReset: true,
                    resetReason: forcedReset.reason,
                    resetTargetPTS: forcedReset.targetPTS
                )
            }
            return .empty
        }

        insertChronologically(chunk)
        bufferedDuration += chunk.duration
        lastEnqueuedPTS = max(lastEnqueuedPTS ?? chunk.pts, chunk.pts)

        while bufferedDuration > maxBufferedDuration && pendingChunks.count > 1 {
            let dropped = pendingChunks.removeLast()
            bufferedDuration = max(0, bufferedDuration - dropped.duration)
        }

        let drained = drain(now: now)
        if let forcedReset, !drained.needsSessionReset {
            return DrainResult(
                chunksToFeed: drained.chunksToFeed,
                needsSessionReset: true,
                resetReason: forcedReset.reason,
                resetTargetPTS: forcedReset.targetPTS
            )
        }
        return drained
    }

    mutating func drain(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DrainResult {
        guard let eff = effectiveMediaTime(at: now), !pendingChunks.isEmpty else {
            return .empty
        }

        let staleCutoff = eff - staleDropBehindSeconds
        var staleCount = 0
        while staleCount < pendingChunks.count,
              pendingChunks[staleCount].endPTS < staleCutoff {
            staleCount += 1
        }
        let droppedStaleAfterFeed = staleCount > 0 && latestFedAudioEndPTS != nil
        if staleCount > 0 {
            var droppedDur: TimeInterval = 0
            for idx in 0..<staleCount {
                droppedDur += pendingChunks[idx].duration
            }
            pendingChunks.removeFirst(staleCount)
            bufferedDuration = pendingChunks.isEmpty ? 0 : max(0, bufferedDuration - droppedDur)
        }

        let releaseCutoff = eff + maxFeedLeadSeconds
        var releaseCount = 0
        while releaseCount < pendingChunks.count,
              pendingChunks[releaseCount].pts <= releaseCutoff {
            releaseCount += 1
        }
        guard releaseCount > 0 else {
            if droppedStaleAfterFeed {
                latestFedAudioEndPTS = nil
                return DrainResult(
                    chunksToFeed: [],
                    needsSessionReset: true,
                    resetReason: .timelineJump,
                    resetTargetPTS: eff
                )
            }
            return .empty
        }

        var released: [AudioPCMSubtitleChunk] = []
        released.reserveCapacity(releaseCount)
        var removedDur: TimeInterval = 0
        for idx in 0..<releaseCount {
            let candidate = pendingChunks[idx]
            removedDur += candidate.duration
            if let fedEnd = latestFedAudioEndPTS, candidate.endPTS <= fedEnd + 1e-4 {
                continue
            }
            released.append(candidate)
        }
        pendingChunks.removeFirst(releaseCount)
        bufferedDuration = pendingChunks.isEmpty ? 0 : max(0, bufferedDuration - removedDur)

        guard let firstReleased = released.first else {
            return .empty
        }

        var needsReset = false
        var resetReason: AudioPCMSubtitleDiscontinuityReason?
        var resetTargetPTS: TimeInterval?
        if let prevFedEnd = latestFedAudioEndPTS {
            if droppedStaleAfterFeed
                || firstReleased.pts > prevFedEnd + 1.0
                || firstReleased.pts < prevFedEnd - 0.5 {
                needsReset = true
                resetReason = .timelineJump
                resetTargetPTS = firstReleased.pts
            }
        }

        if let lastReleased = released.last {
            if needsReset {
                latestFedAudioEndPTS = lastReleased.endPTS
            } else {
                latestFedAudioEndPTS = max(latestFedAudioEndPTS ?? lastReleased.endPTS, lastReleased.endPTS)
            }
        }

        return DrainResult(
            chunksToFeed: released,
            needsSessionReset: needsReset,
            resetReason: resetReason,
            resetTargetPTS: resetTargetPTS
        )
    }

    private mutating func clearBufferAndAnchors() {
        pendingChunks.removeAll(keepingCapacity: true)
        bufferedDuration = 0
        lastEnqueuedPTS = nil
        latestFedAudioEndPTS = nil
        lastMediaAdvanceWallTime = nil
        fallbackAnchorPTS = nil
        fallbackAnchorWallTime = nil
    }

    private mutating func insertChronologically(_ chunk: AudioPCMSubtitleChunk) {
        if let last = pendingChunks.last, chunk.pts >= last.pts {
            pendingChunks.append(chunk)
            return
        }
        var low = 0
        var high = pendingChunks.count
        while low < high {
            let mid = low + (high - low) / 2
            if pendingChunks[mid].pts <= chunk.pts {
                low = mid + 1
            } else {
                high = mid
            }
        }
        pendingChunks.insert(chunk, at: low)
    }
}

/// Pure, testable timeline store for finalized and volatile speech subtitle cues.
struct SpeechSubtitleTimelineStore: Sendable {
    static let defaultMaxCueCount = 4_000
    static let defaultFinalizedToleranceAfterEnd: TimeInterval = 0.35
    static let defaultVolatileLeadTolerance: TimeInterval = 0.0
    static let defaultVolatileTailHold: TimeInterval = 3.2

    private(set) var finalizedCues: [PlayerViewModel.SubtitleCue] = []
    private(set) var volatileCues: [PlayerViewModel.SubtitleCue] = []
    private let maxCueCount: Int

    var volatileCue: PlayerViewModel.SubtitleCue? {
        volatileCues.last
    }

    init(maxCueCount: Int = SpeechSubtitleTimelineStore.defaultMaxCueCount) {
        self.maxCueCount = max(32, maxCueCount)
    }

    mutating func apply(_ update: SpeechRecognitionCueUpdate) {
        if update.clearAll {
            clearAll()
        }
        if let replaceFrom = update.replaceCommittedFromPTS, replaceFrom.isFinite {
            finalizedCues.removeAll { $0.from >= replaceFrom - 0.05 }
        }
        if !update.committedCues.isEmpty {
            appendFinalized(update.committedCues)
        }
        setVolatileCues(update.volatileCues)
    }

    mutating func appendFinalized(_ newCues: [PlayerViewModel.SubtitleCue]) {
        let valid = newCues.compactMap { cue -> PlayerViewModel.SubtitleCue? in
            let trimmed = cue.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cue.from.isFinite, cue.to.isFinite, cue.to > cue.from, !trimmed.isEmpty else {
                return nil
            }
            return PlayerViewModel.SubtitleCue(from: cue.from, to: cue.to, content: trimmed)
        }
        guard !valid.isEmpty else { return }

        // Replace overlapping/near-duplicate finalized cues emitted for the same time window.
        for incoming in valid {
            finalizedCues.removeAll { existing in
                let overlapStart = max(existing.from, incoming.from)
                let overlapEnd = min(existing.to, incoming.to)
                if overlapEnd > overlapStart + 0.08 {
                    let existingDur = max(0.001, existing.to - existing.from)
                    let overlapRatio = (overlapEnd - overlapStart) / existingDur
                    if overlapRatio >= 0.6 || existing.content == incoming.content {
                        return true
                    }
                }
                return abs(existing.from - incoming.from) < 0.15 && existing.content == incoming.content
            }
            finalizedCues.append(incoming)
        }

        finalizedCues = Self.normalizeMonotonicCues(finalizedCues)
        if finalizedCues.count > maxCueCount {
            finalizedCues.removeFirst(finalizedCues.count - maxCueCount)
        }

        if !volatileCues.isEmpty {
            volatileCues = clampVolatileCues(volatileCues)
        }
    }

    mutating func setVolatile(_ cue: PlayerViewModel.SubtitleCue?) {
        setVolatileCues(cue.map { [$0] } ?? [])
    }

    mutating func setVolatileCues(_ cues: [PlayerViewModel.SubtitleCue]) {
        let valid = cues.compactMap { cue -> PlayerViewModel.SubtitleCue? in
            let trimmed = cue.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cue.from.isFinite, cue.to.isFinite, !trimmed.isEmpty else {
                return nil
            }
            return PlayerViewModel.SubtitleCue(
                from: max(0, cue.from),
                to: max(max(0, cue.from) + 0.25, cue.to),
                content: trimmed
            )
        }
        guard !valid.isEmpty else {
            volatileCues = []
            return
        }

        var normalized = Self.normalizeMonotonicCues(valid)
        if let last = normalized.last {
            normalized[normalized.count - 1] = PlayerViewModel.SubtitleCue(
                from: last.from,
                to: max(last.to, last.from + 0.8),
                content: last.content
            )
        }
        volatileCues = clampVolatileCues(normalized)
    }

    mutating func clearVolatile() {
        volatileCues.removeAll(keepingCapacity: true)
    }

    mutating func clearAll() {
        finalizedCues.removeAll(keepingCapacity: true)
        volatileCues.removeAll(keepingCapacity: true)
    }

    func activeCue(at time: TimeInterval) -> PlayerViewModel.SubtitleCue? {
        guard time.isFinite else { return nil }

        let finalizedCandidateIndex = Self.lastCueIndexStartingAtOrBefore(time, in: finalizedCues)
        if let finalizedCandidateIndex {
            let cue = finalizedCues[finalizedCandidateIndex]
            if time >= cue.from && time <= cue.to {
                return cue
            }
        }

        let volatileSearchTime = time + Self.defaultVolatileLeadTolerance
        let volatileCandidateIndex = Self.lastCueIndexStartingAtOrBefore(volatileSearchTime, in: volatileCues)
        if let volatileCandidateIndex {
            let cue = volatileCues[volatileCandidateIndex]
            if time >= cue.from - Self.defaultVolatileLeadTolerance && time <= cue.to {
                return cue
            }
            if volatileCandidateIndex + 1 < volatileCues.count {
                let nextVolatile = volatileCues[volatileCandidateIndex + 1]
                let bridgeEnd = min(nextVolatile.from, cue.to + Self.defaultFinalizedToleranceAfterEnd)
                if time >= cue.from - Self.defaultVolatileLeadTolerance && time < bridgeEnd {
                    return cue
                }
            }
        }

        if let finalizedCandidateIndex, volatileCandidateIndex == nil {
            let cue = finalizedCues[finalizedCandidateIndex]
            if time >= cue.from && time <= cue.to + Self.defaultFinalizedToleranceAfterEnd {
                return cue
            }
        }

        if let lastVolatile = volatileCues.last,
           time >= lastVolatile.from - Self.defaultVolatileLeadTolerance,
           time <= lastVolatile.to + Self.defaultVolatileTailHold {
            return lastVolatile
        }

        return nil
    }

    func activeText(at time: TimeInterval) -> String? {
        activeCue(at: time)?.content
    }

    private func clampVolatileCues(_ cues: [PlayerViewModel.SubtitleCue]) -> [PlayerViewModel.SubtitleCue] {
        guard let lastCommitted = finalizedCues.last else { return cues }
        let committedEnd = lastCommitted.to
        var filtered: [PlayerViewModel.SubtitleCue] = []
        filtered.reserveCapacity(cues.count)

        for cue in cues {
            if cue.to <= committedEnd + 0.04 {
                continue
            }
            if filtered.isEmpty,
               cue.content == lastCommitted.content,
               cue.from <= committedEnd + 0.25 {
                continue
            }
            if filtered.isEmpty {
                let clampedFrom = max(cue.from, committedEnd)
                guard cue.to > clampedFrom + 0.04 else { continue }
                filtered.append(
                    PlayerViewModel.SubtitleCue(
                        from: clampedFrom,
                        to: cue.to,
                        content: cue.content
                    )
                )
            } else {
                filtered.append(cue)
            }
        }
        return filtered
    }

    private static func normalizeMonotonicCues(
        _ rawCues: [PlayerViewModel.SubtitleCue]
    ) -> [PlayerViewModel.SubtitleCue] {
        let sorted = rawCues.sorted { lhs, rhs in
            if lhs.from != rhs.from { return lhs.from < rhs.from }
            return lhs.to < rhs.to
        }
        var normalized: [PlayerViewModel.SubtitleCue] = []
        normalized.reserveCapacity(sorted.count)

        for cue in sorted {
            var from = cue.from
            let endTime = cue.to
            if let prev = normalized.last {
                if prev.content == cue.content && from <= prev.to + 0.25 {
                    normalized[normalized.count - 1] = PlayerViewModel.SubtitleCue(
                        from: prev.from,
                        to: max(prev.to, endTime),
                        content: prev.content
                    )
                    continue
                }
                if from < prev.to {
                    if from >= prev.from + 0.12 {
                        normalized[normalized.count - 1] = PlayerViewModel.SubtitleCue(
                            from: prev.from,
                            to: from,
                            content: prev.content
                        )
                    } else {
                        from = prev.to
                    }
                }
            }
            guard endTime > from + 0.02 else { continue }
            normalized.append(PlayerViewModel.SubtitleCue(from: from, to: endTime, content: cue.content))
        }
        return normalized
    }

    private static func lastCueIndexStartingAtOrBefore(
        _ time: TimeInterval,
        in cues: [PlayerViewModel.SubtitleCue]
    ) -> Int? {
        guard !cues.isEmpty else { return nil }
        var low = 0
        var high = cues.count
        while low < high {
            let mid = low + (high - low) / 2
            if cues[mid].from <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? (low - 1) : nil
    }
}

/// Pure helper that groups timed recognition segments into readable subtitle-length cues.
enum SpeechSubtitleCueBuilder {
    struct TimedSegment: Sendable, Equatable {
        let text: String
        let startOffset: TimeInterval
        let duration: TimeInterval

        var endOffset: TimeInterval {
            startOffset + max(0.05, duration)
        }
    }

    static let maxCueDuration: TimeInterval = 4.2
    static let pauseSplitThreshold: TimeInterval = 0.85
    static let maxCueCharacterCount = 34
    static let volatileTailExtensionSeconds: TimeInterval = 1.8

    private static let sentenceEndings: Set<Character> = [
        ".", "!", "?", "。", "！", "？", "…", "\n",
    ]
    private static let clausePunctuation: Set<Character> = [
        ",", "，", ";", "；", ":", "：", "、",
    ]

    static func buildCues(
        from segments: [TimedSegment],
        basePTS: TimeInterval
    ) -> [PlayerViewModel.SubtitleCue] {
        guard basePTS.isFinite, !segments.isEmpty else { return [] }

        let orderedSegments = sortSegmentsChronologically(segments)
        var cues: [PlayerViewModel.SubtitleCue] = []
        var bucket: [TimedSegment] = []
        var bucketCharCount = 0

        func flushBucket() {
            guard let first = bucket.first, let last = bucket.last else { return }
            let joined = joinSegments(bucket)
            bucket.removeAll(keepingCapacity: true)
            bucketCharCount = 0
            guard !joined.isEmpty else { return }
            let start = max(0, basePTS + first.startOffset)
            let end = max(start + 0.75, basePTS + last.endOffset)
            cues.append(PlayerViewModel.SubtitleCue(from: start, to: end, content: joined))
        }

        for segment in orderedSegments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, segment.startOffset.isFinite else { continue }

            if let previous = bucket.last, let first = bucket.first {
                let gap = segment.startOffset - previous.endOffset
                let projectedDuration = segment.endOffset - first.startOffset
                let projectedChars = bucketCharCount + trimmed.count + 1
                if gap >= pauseSplitThreshold
                    || projectedDuration >= maxCueDuration
                    || projectedChars > maxCueCharacterCount {
                    flushBucket()
                }
            }

            bucket.append(segment)
            bucketCharCount += trimmed.count + 1

            if let lastChar = trimmed.last, sentenceEndings.contains(lastChar) {
                flushBucket()
            } else if bucketCharCount >= 18,
                      let lastChar = trimmed.last,
                      clausePunctuation.contains(lastChar) {
                flushBucket()
            }
        }

        flushBucket()
        return clampSequentialCues(cues)
    }

    /// Formats trailing text for live partial display, keeping the latest concise caption line.
    static func conciseVolatileLine(from rawText: String, maxCharacters: Int = 46) -> String {
        let cleaned = rawText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxCharacters else { return cleaned }

        // Prefer starting right after the last sentence boundary if it leaves enough context.
        let tailSlice = cleaned.suffix(maxCharacters)
        if let boundary = tailSlice.firstIndex(where: { sentenceEndings.contains($0) }) {
            let afterBoundary = tailSlice.index(after: boundary)
            let candidate = String(tailSlice[afterBoundary...]).trimmingCharacters(in: .whitespaces)
            if candidate.count >= 6 {
                return candidate
            }
        }
        if let space = tailSlice.firstIndex(of: " "),
           tailSlice.distance(from: tailSlice.startIndex, to: space) < maxCharacters / 2 {
            let afterSpace = tailSlice.index(after: space)
            let candidate = String(tailSlice[afterSpace...]).trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty {
                return candidate
            }
        }
        return String(tailSlice).trimmingCharacters(in: .whitespaces)
    }

    /// Splits untimed text into chronological sentence/clause units for proportional pacing.
    static func splitIntoClauses(
        _ rawText: String,
        maxCharacters: Int = maxCueCharacterCount
    ) -> [String] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var primaryClauses: [String] = []
        var current = ""
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let character = normalized[index]
            let nextIndex = normalized.index(after: index)
            if character == "\n" {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { primaryClauses.append(piece) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
                if sentenceEndings.contains(character) {
                    let isDecimalDot = character == "."
                        && nextIndex < normalized.endIndex
                        && normalized[nextIndex].isNumber
                    if !isDecimalDot {
                        let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !piece.isEmpty { primaryClauses.append(piece) }
                        current.removeAll(keepingCapacity: true)
                    }
                }
            }
            index = nextIndex
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            primaryClauses.append(remainder)
        }

        var result: [String] = []
        for clause in primaryClauses {
            if clause.count <= maxCharacters {
                result.append(clause)
            } else {
                result.append(contentsOf: splitLongClause(clause, maxCharacters: maxCharacters))
            }
        }
        return result
    }

    /// Builds proportionally timed cues across `[windowStartPTS, windowEndPTS]` for untimed text.
    static func buildUntimedCues(
        from rawText: String,
        windowStartPTS: TimeInterval,
        windowEndPTS: TimeInterval,
        extendLastCueBy: TimeInterval = 0
    ) -> [PlayerViewModel.SubtitleCue] {
        guard windowStartPTS.isFinite, windowEndPTS.isFinite else { return [] }
        let clauses = splitIntoClauses(rawText)
        guard !clauses.isEmpty else { return [] }

        let spanStart = max(0, windowStartPTS)
        let minSpan = max(0.8, 0.5 * Double(clauses.count))
        let spanEnd = max(spanStart + minSpan, windowEndPTS)
        let totalSpan = spanEnd - spanStart
        let totalWeight = Double(clauses.reduce(0) { $0 + max(1, $1.count) })

        var cues: [PlayerViewModel.SubtitleCue] = []
        cues.reserveCapacity(clauses.count)
        var cursor = spanStart
        for (idx, clause) in clauses.enumerated() {
            let weight = Double(max(1, clause.count))
            let naturalEnd = (idx == clauses.count - 1)
                ? spanEnd
                : (cursor + totalSpan * (weight / totalWeight))
            let isLast = idx == clauses.count - 1
            let cueEnd = isLast
                ? max(cursor + 0.8, naturalEnd + max(0, extendLastCueBy))
                : max(cursor + 0.25, naturalEnd)
            cues.append(PlayerViewModel.SubtitleCue(from: cursor, to: cueEnd, content: clause))
            cursor = naturalEnd
        }
        return clampSequentialCues(cues)
    }

    /// Builds volatile cues when the recognizer has not emitted word timestamps yet.
    ///
    /// Multi-clause text is distributed proportionally across `[windowStartPTS, latestFedAudioEndPTS]`
    /// so earlier clauses appear first and trailing clauses wait until playback reaches them.
    /// Single-clause text anchors near `latestFedAudioEndPTS - 1.2s` when fed audio has advanced.
    static func buildUntimedVolatileCues(
        from rawText: String,
        windowStartPTS: TimeInterval,
        latestFedAudioEndPTS: TimeInterval?,
        fallbackWindowEndPTS: TimeInterval
    ) -> [PlayerViewModel.SubtitleCue] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, windowStartPTS.isFinite else { return [] }

        let spanStart = max(0, windowStartPTS)
        let clauses = splitIntoClauses(trimmed)
        if clauses.count >= 2 {
            let spanEnd: TimeInterval
            if let fedEnd = latestFedAudioEndPTS, fedEnd.isFinite {
                spanEnd = max(spanStart + 0.8, fedEnd)
            } else {
                spanEnd = max(spanStart + 1.6, fallbackWindowEndPTS)
            }
            var cues = buildUntimedCues(
                from: trimmed,
                windowStartPTS: spanStart,
                windowEndPTS: spanEnd,
                extendLastCueBy: volatileTailExtensionSeconds
            )
            if let last = cues.last {
                cues[cues.count - 1] = PlayerViewModel.SubtitleCue(
                    from: last.from,
                    to: max(last.to, last.from + 2.5),
                    content: last.content
                )
            }
            return cues
        }

        let line = conciseVolatileLine(from: trimmed)
        guard !line.isEmpty else { return [] }
        if let fedEnd = latestFedAudioEndPTS, fedEnd.isFinite {
            let fromPTS = max(spanStart, fedEnd - 1.2)
            let toPTS = max(fromPTS + 2.5, fedEnd + volatileTailExtensionSeconds)
            return [PlayerViewModel.SubtitleCue(from: fromPTS, to: toPTS, content: line)]
        }

        let toPTS = max(spanStart + 2.5, fallbackWindowEndPTS)
        return [PlayerViewModel.SubtitleCue(from: spanStart, to: toPTS, content: line)]
    }

    /// Pure cue builder shared by iOS 26 `SpeechAnalyzer` (`SpeechTranscriber.Result`) and tests.
    static func buildSpeechAnalyzerUpdate(
        plainText: String,
        timedSegments: [TimedSegment],
        rangeStartOffset: TimeInterval?,
        rangeDuration: TimeInterval?,
        isFinal: Bool,
        basePTS: TimeInterval,
        latestFedAudioEndPTS: TimeInterval?
    ) -> SpeechRecognitionCueUpdate {
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, basePTS.isFinite else {
            return SpeechRecognitionCueUpdate()
        }

        let rangeStart: TimeInterval
        let rangeEnd: TimeInterval
        if let startOffset = rangeStartOffset, let duration = rangeDuration,
           startOffset.isFinite, duration.isFinite, startOffset >= 0 {
            rangeStart = max(0, basePTS + startOffset)
            rangeEnd = max(rangeStart + 0.8, rangeStart + max(0, duration))
        } else if let first = timedSegments.first, let last = timedSegments.last {
            rangeStart = max(0, basePTS + first.startOffset)
            rangeEnd = max(rangeStart + 0.8, basePTS + last.endOffset)
        } else {
            rangeStart = max(0, basePTS)
            rangeEnd = max(rangeStart + 0.8, latestFedAudioEndPTS ?? (rangeStart + 1.8))
        }

        if isFinal {
            if !timedSegments.isEmpty {
                let grouped = buildCues(from: timedSegments, basePTS: basePTS)
                if !grouped.isEmpty {
                    return SpeechRecognitionCueUpdate(committedCues: grouped, volatileCues: [])
                }
            }
            let untimedFinal = buildUntimedCues(
                from: trimmed,
                windowStartPTS: rangeStart,
                windowEndPTS: rangeEnd
            )
            if !untimedFinal.isEmpty {
                return SpeechRecognitionCueUpdate(committedCues: untimedFinal, volatileCues: [])
            }
            return SpeechRecognitionCueUpdate(
                committedCues: [PlayerViewModel.SubtitleCue(from: rangeStart, to: rangeEnd, content: trimmed)],
                volatileCues: []
            )
        }

        if !timedSegments.isEmpty {
            var volatile = buildCues(from: timedSegments, basePTS: basePTS)
            if let last = volatile.last {
                volatile[volatile.count - 1] = PlayerViewModel.SubtitleCue(
                    from: last.from,
                    to: max(last.to, rangeEnd + 1.5, last.from + 1.8),
                    content: last.content
                )
            }
            return SpeechRecognitionCueUpdate(committedCues: [], volatileCues: volatile)
        }

        let volatile = buildUntimedVolatileCues(
            from: trimmed,
            windowStartPTS: rangeStart,
            latestFedAudioEndPTS: latestFedAudioEndPTS,
            fallbackWindowEndPTS: max(rangeEnd, rangeStart + 0.8)
        )
        return SpeechRecognitionCueUpdate(committedCues: [], volatileCues: volatile)
    }

    struct LegacyPartialUpdateResult: Sendable {
        let finalizedBatch: [PlayerViewModel.SubtitleCue]
        let volatileCues: [PlayerViewModel.SubtitleCue]
        let updatedCommittedSegmentCount: Int
        let updatedCommittedEndOffset: TimeInterval
        let updatedPartialEndOffset: TimeInterval

        var volatileCue: PlayerViewModel.SubtitleCue? {
            volatileCues.last
        }
    }

    /// Computes incremental finalized cues and properly sliced timed volatile cues for
    /// `SFSpeechRecognizer` partial results so future phrases never display ahead of audio.
    static func buildLegacyPartialUpdate(
        formattedText: String,
        segments: [TimedSegment],
        basePTS: TimeInterval,
        windowAudioDuration: TimeInterval,
        committedSegmentCount: Int,
        lastCommittedEndOffset: TimeInterval,
        lastPartialEndOffset: TimeInterval,
        latestFedAudioEndPTS: TimeInterval? = nil
    ) -> LegacyPartialUpdateResult {
        let trimmedFull = formattedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFull.isEmpty, basePTS.isFinite else {
            return LegacyPartialUpdateResult(
                finalizedBatch: [],
                volatileCues: [],
                updatedCommittedSegmentCount: committedSegmentCount,
                updatedCommittedEndOffset: lastCommittedEndOffset,
                updatedPartialEndOffset: lastPartialEndOffset
            )
        }

        let timedSegments = segments.filter { $0.startOffset > 0 || $0.duration > 0 }
        var nextPartialEndOffset = lastPartialEndOffset
        if let lastTimed = timedSegments.last {
            nextPartialEndOffset = max(nextPartialEndOffset, lastTimed.endOffset)
        }

        var finalizedBatch: [PlayerViewModel.SubtitleCue] = []
        var nextCommittedCount = min(max(0, committedSegmentCount), timedSegments.count)
        var nextCommittedEndOffset = max(0, lastCommittedEndOffset)

        if timedSegments.count > nextCommittedCount + 4 {
            let stablePrefix = Array(timedSegments[nextCommittedCount..<(timedSegments.count - 2)])
            let built = buildCues(from: stablePrefix, basePTS: basePTS)
            if built.count >= 2 {
                finalizedBatch = Array(built.dropLast())
                if let lastCommittedCue = finalizedBatch.last {
                    nextCommittedEndOffset = max(nextCommittedEndOffset, lastCommittedCue.to - basePTS)
                }
                if let firstUncommittedCue = built.last {
                    let nextUncommittedStart = firstUncommittedCue.from - basePTS
                    var advanced = nextCommittedCount
                    while advanced < timedSegments.count - 2,
                          timedSegments[advanced].startOffset < nextUncommittedStart - 1e-4 {
                        advanced += 1
                    }
                    nextCommittedCount = max(nextCommittedCount, advanced)
                }
            }
        }

        let tailTimed = Array(timedSegments.dropFirst(min(nextCommittedCount, timedSegments.count)))
        let volatileCues: [PlayerViewModel.SubtitleCue]
        if !tailTimed.isEmpty {
            var sliced = buildCues(from: tailTimed, basePTS: basePTS)
            if let last = sliced.last {
                // Extend only the final active phrase so earlier phrases end cleanly before the next phrase.
                sliced[sliced.count - 1] = PlayerViewModel.SubtitleCue(
                    from: last.from,
                    to: max(last.to + volatileTailExtensionSeconds, last.from + 2.5),
                    content: last.content
                )
            }
            volatileCues = sliced
        } else {
            let windowStartPTS = max(0, basePTS + nextCommittedEndOffset)
            let untimedSpan = max(nextCommittedEndOffset + 3.0, max(0, windowAudioDuration))
            let fallbackEndPTS = max(windowStartPTS + 2.5, basePTS + untimedSpan)
            volatileCues = buildUntimedVolatileCues(
                from: trimmedFull,
                windowStartPTS: windowStartPTS,
                latestFedAudioEndPTS: latestFedAudioEndPTS,
                fallbackWindowEndPTS: fallbackEndPTS
            )
        }

        return LegacyPartialUpdateResult(
            finalizedBatch: finalizedBatch,
            volatileCues: volatileCues,
            updatedCommittedSegmentCount: nextCommittedCount,
            updatedCommittedEndOffset: nextCommittedEndOffset,
            updatedPartialEndOffset: nextPartialEndOffset
        )
    }

    private static func sortSegmentsChronologically(_ segments: [TimedSegment]) -> [TimedSegment] {
        var isSorted = true
        if segments.count > 1 {
            for idx in 1..<segments.count where segments[idx].startOffset < segments[idx - 1].startOffset {
                isSorted = false
                break
            }
        }
        guard !isSorted else { return segments }
        return segments.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.startOffset != rhs.element.startOffset {
                    return lhs.element.startOffset < rhs.element.startOffset
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func clampSequentialCues(
        _ input: [PlayerViewModel.SubtitleCue]
    ) -> [PlayerViewModel.SubtitleCue] {
        guard input.count > 1 else { return input }
        var cues = input
        for index in 0..<(cues.count - 1) {
            let current = cues[index]
            let next = cues[index + 1]
            if current.to > next.from {
                if next.from >= current.from + 0.12 {
                    cues[index] = PlayerViewModel.SubtitleCue(
                        from: current.from,
                        to: next.from,
                        content: current.content
                    )
                } else {
                    let clampedNextFrom = current.to
                    cues[index + 1] = PlayerViewModel.SubtitleCue(
                        from: clampedNextFrom,
                        to: max(clampedNextFrom + 0.2, next.to),
                        content: next.content
                    )
                }
            }
        }
        return cues
    }

    private static func splitLongClause(_ text: String, maxCharacters: Int) -> [String] {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var pieces: [String] = []
        let limit = max(8, maxCharacters)

        while remaining.count > limit {
            let endIdx = remaining.index(remaining.startIndex, offsetBy: limit)
            let prefix = remaining[..<endIdx]
            let splitIndex: String.Index
            if let punct = prefix.lastIndex(where: { clausePunctuation.contains($0) }),
               prefix.distance(from: prefix.startIndex, to: punct) >= limit / 3 {
                splitIndex = remaining.index(after: punct)
            } else if let space = prefix.lastIndex(of: " "),
                      prefix.distance(from: prefix.startIndex, to: space) >= limit / 3 {
                splitIndex = remaining.index(after: space)
            } else {
                splitIndex = endIdx
            }
            let head = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty {
                pieces.append(head)
            }
            remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespaces)
        }
        if !remaining.isEmpty {
            pieces.append(remaining)
        }
        return pieces
    }

    private static func joinSegments(_ segments: [TimedSegment]) -> String {
        var result = ""
        for segment in segments {
            let piece = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if !result.isEmpty, needsSpaceBetween(result, and: piece) {
                result.append(" ")
            }
            result.append(piece)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func needsSpaceBetween(_ lhs: String, and rhs: String) -> Bool {
        guard let last = lhs.unicodeScalars.last, let first = rhs.unicodeScalars.first else {
            return false
        }
        // Avoid inserting spaces inside CJK text or right before punctuation.
        if isCJKScalar(last) || isCJKScalar(first) {
            return false
        }
        let punctuation = CharacterSet.punctuationCharacters
        if punctuation.contains(first) {
            return false
        }
        return true
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            true
        default:
            false
        }
    }
}

/// Converts mono Float32 `AudioPCMSubtitleChunk` samples into a target `AVAudioFormat`.
/// Must remain confined to a single serial execution context.
final class PCMBufferConverter {
    private let targetFormat: AVAudioFormat
    private var cachedSourceRate: Double?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func reset() {
        converter?.reset()
    }

    func convert(_ chunk: AudioPCMSubtitleChunk) -> AVAudioPCMBuffer? {
        guard !chunk.monoSamples.isEmpty,
              chunk.sampleRate.isFinite,
              chunk.sampleRate > 0 else {
            return nil
        }

        if cachedSourceRate != chunk.sampleRate || sourceFormat == nil {
            guard let src = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: chunk.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                return nil
            }
            cachedSourceRate = chunk.sampleRate
            sourceFormat = src
            converter = (src == targetFormat) ? nil : AVAudioConverter(from: src, to: targetFormat)
        }

        guard let srcFormat = sourceFormat else { return nil }
        let inputFrameCount = AVAudioFrameCount(chunk.monoSamples.count)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: srcFormat,
            frameCapacity: inputFrameCount
        ) else {
            return nil
        }
        inputBuffer.frameLength = inputFrameCount
        if let channelData = inputBuffer.floatChannelData?[0] {
            chunk.monoSamples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    channelData.update(from: base, count: chunk.monoSamples.count)
                }
            }
        }

        guard let converter else {
            return inputBuffer
        }

        let ratio = targetFormat.sampleRate / srcFormat.sampleRate
        let outputCapacity = max(
            AVAudioFrameCount(32),
            AVAudioFrameCount(ceil(Double(inputFrameCount) * ratio)) + 64
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        var suppliedInput = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil, outputBuffer.frameLength > 0 else {
            return nil
        }
        return outputBuffer
    }
}

/// Thread-safe bridge wrapping `SpeechAudioPacer` and emitting strictly ordered paced PCM events.
private final class SpeechAudioPacingController: Sendable {
    private struct State: Sendable {
        var pacer: SpeechAudioPacer
        var continuation: AsyncStream<AudioPCMSubtitleEvent>.Continuation?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(initialMediaTime: TimeInterval? = nil) {
        var pacer = SpeechAudioPacer()
        if let initialMediaTime, initialMediaTime.isFinite, initialMediaTime >= 0 {
            _ = pacer.updateMediaTime(initialMediaTime, now: ProcessInfo.processInfo.systemUptime)
        }
        self.state = OSAllocatedUnfairLock(initialState: State(pacer: pacer, continuation: nil))
    }

    var latestFedAudioEndPTS: TimeInterval? {
        state.withLock { $0.pacer.latestFedAudioEndPTS }
    }

    func makePacedStream(
        bufferingNewest capacity: Int = AudioPCMSubtitleTap.defaultBufferCapacity
    ) -> AsyncStream<AudioPCMSubtitleEvent> {
        let (stream, continuation) = AsyncStream<AudioPCMSubtitleEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, capacity))
        )
        let previous = state.withLock { state -> AsyncStream<AudioPCMSubtitleEvent>.Continuation? in
            let old = state.continuation
            state.continuation = continuation
            return old
        }
        previous?.finish()
        return stream
    }

    func finish() {
        let previous = state.withLock { state -> AsyncStream<AudioPCMSubtitleEvent>.Continuation? in
            let old = state.continuation
            state.continuation = nil
            state.pacer.reset()
            return old
        }
        previous?.finish()
    }

    func handleIncoming(_ event: AudioPCMSubtitleEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { state in
            let result: SpeechAudioPacer.DrainResult
            switch event {
            case .pcm(let chunk):
                result = state.pacer.enqueue(chunk, now: now)
            case .discontinuity(let reason, let targetPTS):
                result = state.pacer.handleDiscontinuity(reason: reason, targetPTS: targetPTS, now: now)
            }
            Self.emitLocked(result, to: state.continuation)
        }
    }

    @discardableResult
    func updateMediaTime(_ time: TimeInterval) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return state.withLock { state in
            let result = state.pacer.updateMediaTime(time, now: now)
            Self.emitLocked(result, to: state.continuation)
            return result.needsSessionReset
        }
    }

    func handleSeek(to time: TimeInterval?) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { state in
            let result = state.pacer.handleSeek(to: time, now: now)
            Self.emitLocked(result, to: state.continuation)
        }
    }

    func drainTick() {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { state in
            let result = state.pacer.drain(now: now)
            Self.emitLocked(result, to: state.continuation)
        }
    }

    private static func emitLocked(
        _ result: SpeechAudioPacer.DrainResult,
        to continuation: AsyncStream<AudioPCMSubtitleEvent>.Continuation?
    ) {
        guard let continuation else { return }
        if result.needsSessionReset {
            continuation.yield(
                .discontinuity(
                    reason: result.resetReason ?? .timelineJump,
                    targetPTS: result.resetTargetPTS
                )
            )
        }
        for chunk in result.chunksToFeed {
            continuation.yield(.pcm(chunk))
        }
    }
}

/// On-device `SFSpeechRecognizer` streaming fallback with automatic ~48s/pause window rotation
/// so Apple's 60-second `SFSpeechRecognitionTask` limit never interrupts long VOD or Live playback.
private final class LegacySFSpeechEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.swiftpili.speech.legacy", qos: .userInitiated)
    private let locale: Locale
    private let onUpdate: @Sendable (SpeechRecognitionCueUpdate) -> Void
    private let onEngineKindChanged: @Sendable (SpeechSubtitleEngineKind) -> Void
    private let onFatalError: @Sendable (String) -> Void

    private var recognizer: SFSpeechRecognizer?
    private var callbackQueue: OperationQueue?
    private var converter: PCMBufferConverter?
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeTask: SFSpeechRecognitionTask?
    private var preferOnDevice = false
    private var hasProducedResultWithOnDevice = false
    private var hasProducedResultInWindow = false
    private var windowGeneration: UInt64 = 0
    private var windowBasePTS: TimeInterval?
    private var windowAudioDuration: TimeInterval = 0
    private var latestFedAudioEndPTS: TimeInterval?
    private var consecutiveSilenceDuration: TimeInterval = 0
    private var committedSegmentCount = 0
    private var lastCommittedEndOffset: TimeInterval = 0
    private var lastPartialText = ""
    private var lastPartialEndOffset: TimeInterval = 0
    private var lastPartialVolatileCues: [PlayerViewModel.SubtitleCue] = []
    private var pendingRetryChunks: [AudioPCMSubtitleChunk] = []
    private var pendingRetryDuration: TimeInterval = 0
    private var consecutiveFailureCount = 0
    private var isStopped = false

    private static let maxWindowDuration: TimeInterval = 48.0
    private static let softRotateDuration: TimeInterval = 28.0
    private static let pauseSilenceThreshold: Float = 0.008
    private static let pauseMinDuration: TimeInterval = 0.55
    private static let maxPendingRetryDuration: TimeInterval = 6.0
    private static let maxConsecutiveFailures = 6

    init(
        locale: Locale,
        onUpdate: @escaping @Sendable (SpeechRecognitionCueUpdate) -> Void,
        onEngineKindChanged: @escaping @Sendable (SpeechSubtitleEngineKind) -> Void,
        onFatalError: @escaping @Sendable (String) -> Void
    ) {
        self.locale = locale
        self.onUpdate = onUpdate
        self.onEngineKindChanged = onEngineKindChanged
        self.onFatalError = onFatalError
    }

    func prepare() -> SpeechSubtitleEngineKind? {
        queue.sync {
            guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
                return nil
            }
            let opQueue = OperationQueue()
            opQueue.name = "com.swiftpili.speech.legacy.callbacks"
            opQueue.maxConcurrentOperationCount = 1
            opQueue.qualityOfService = .userInitiated
            rec.queue = opQueue

            callbackQueue = opQueue
            recognizer = rec
            preferOnDevice = rec.supportsOnDeviceRecognition
            hasProducedResultWithOnDevice = false
            if let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) {
                converter = PCMBufferConverter(targetFormat: format)
            }
            return preferOnDevice
                ? .legacyOnDeviceRecognizer
                : .legacyServerRecognizer
        }
    }

    func handle(_ event: AudioPCMSubtitleEvent) {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            switch event {
            case .pcm(let chunk):
                self.consumePCM(chunk)
            case .discontinuity(let reason, _):
                self.handleDiscontinuity(reason: reason)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.pendingRetryChunks.removeAll(keepingCapacity: false)
            self.pendingRetryDuration = 0
            self.teardownCurrentWindow(commitPendingVolatile: false)
            self.recognizer = nil
            self.callbackQueue = nil
            self.converter = nil
        }
    }

    private func consumePCM(_ chunk: AudioPCMSubtitleChunk) {
        guard recognizer != nil else { return }

        if preferOnDevice && !hasProducedResultWithOnDevice && pendingRetryDuration < Self.maxPendingRetryDuration {
            pendingRetryChunks.append(chunk)
            pendingRetryDuration += chunk.duration
        }

        let rms = Self.computeRMS(chunk.monoSamples)
        if rms < Self.pauseSilenceThreshold {
            consecutiveSilenceDuration += chunk.duration
        } else {
            consecutiveSilenceDuration = 0
        }

        let shouldRotate = activeRequest != nil
            && (windowAudioDuration >= Self.maxWindowDuration
                || (windowAudioDuration >= Self.softRotateDuration
                    && consecutiveSilenceDuration >= Self.pauseMinDuration))

        if shouldRotate {
            teardownCurrentWindow(commitPendingVolatile: true)
            converter?.reset()
        }

        if activeRequest == nil {
            startWindow(basePTS: chunk.pts)
        }

        guard let request = activeRequest,
              let buffer = converter?.convert(chunk) else {
            return
        }

        request.append(buffer)
        windowAudioDuration += chunk.duration
        if chunk.endPTS.isFinite {
            latestFedAudioEndPTS = max(latestFedAudioEndPTS ?? chunk.endPTS, chunk.endPTS)
        }
    }

    private func handleDiscontinuity(reason: AudioPCMSubtitleDiscontinuityReason) {
        let shouldClearAll = reason == .streamReset || reason == .sessionStopped
        pendingRetryChunks.removeAll(keepingCapacity: false)
        pendingRetryDuration = 0
        teardownCurrentWindow(commitPendingVolatile: false)
        converter?.reset()
        onUpdate(SpeechRecognitionCueUpdate(committedCues: [], volatileCues: [], clearAll: shouldClearAll))
    }

    private func startWindow(basePTS: TimeInterval) {
        guard let recognizer, recognizer.isAvailable else { return }

        windowGeneration &+= 1
        let generation = windowGeneration
        windowBasePTS = basePTS
        windowAudioDuration = 0
        latestFedAudioEndPTS = nil
        consecutiveSilenceDuration = 0
        committedSegmentCount = 0
        lastCommittedEndOffset = 0
        lastPartialText = ""
        lastPartialEndOffset = 0
        lastPartialVolatileCues = []
        hasProducedResultInWindow = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = preferOnDevice
        activeRequest = request

        activeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let snapshot: (
                isFinal: Bool,
                formattedText: String,
                segments: [SpeechSubtitleCueBuilder.TimedSegment]
            )?
            if let result {
                let segs = result.bestTranscription.segments.map { seg in
                    SpeechSubtitleCueBuilder.TimedSegment(
                        text: seg.substring,
                        startOffset: seg.timestamp,
                        duration: seg.duration
                    )
                }
                snapshot = (
                    isFinal: result.isFinal,
                    formattedText: result.bestTranscription.formattedString,
                    segments: segs
                )
            } else {
                snapshot = nil
            }
            let errorInfo: (domain: String, code: Int, message: String)?
            if let error {
                let nsError = error as NSError
                errorInfo = (nsError.domain, nsError.code, nsError.localizedDescription)
            } else {
                errorInfo = nil
            }

            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.isStopped, self.windowGeneration == generation else { return }
                if let snapshot {
                    self.consecutiveFailureCount = 0
                    if !snapshot.formattedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.hasProducedResultInWindow = true
                        if self.preferOnDevice {
                            self.hasProducedResultWithOnDevice = true
                        }
                        self.pendingRetryChunks.removeAll(keepingCapacity: false)
                        self.pendingRetryDuration = 0
                    }
                    self.processRecognitionSnapshot(
                        isFinal: snapshot.isFinal,
                        formattedText: snapshot.formattedText,
                        segments: snapshot.segments,
                        basePTS: basePTS
                    )
                }
                if let errorInfo {
                    self.handleRecognitionError(errorInfo)
                }
            }
        }
    }

    private func handleRecognitionError(_ errorInfo: (domain: String, code: Int, message: String)) {
        let disposition = LegacySpeechErrorDisposition.classify(
            domain: errorInfo.domain,
            code: errorInfo.code,
            preferOnDevice: preferOnDevice,
            hasProducedResultWithOnDevice: hasProducedResultWithOnDevice,
            hasProducedResultInWindow: hasProducedResultInWindow
        )
        switch disposition {
        case .fallbackToServer:
            PlayerLog.log(
                "[SpeechSubtitles] on-device recognition failed (\(errorInfo.domain) \(errorInfo.code)); " +
                "falling back to System Speech"
            )
            preferOnDevice = false
            consecutiveFailureCount = 0
            let replayChunks = pendingRetryChunks
            pendingRetryChunks.removeAll(keepingCapacity: false)
            pendingRetryDuration = 0
            onEngineKindChanged(.legacyServerRecognizer)
            teardownCurrentWindow(commitPendingVolatile: false)
            converter?.reset()
            for chunk in replayChunks {
                consumePCM(chunk)
            }
        case .ignoreBenignSilence:
            teardownCurrentWindow(commitPendingVolatile: true)
            converter?.reset()
        case .ignoreCancellation:
            teardownCurrentWindow(commitPendingVolatile: false)
        case .countFailure:
            if !hasProducedResultInWindow {
                consecutiveFailureCount += 1
            }
            teardownCurrentWindow(commitPendingVolatile: true)
            converter?.reset()
            if consecutiveFailureCount >= Self.maxConsecutiveFailures {
                onFatalError(errorInfo.message)
            }
        }
    }

    private func processRecognitionSnapshot(
        isFinal: Bool,
        formattedText: String,
        segments: [SpeechSubtitleCueBuilder.TimedSegment],
        basePTS: TimeInterval
    ) {
        let trimmedFull = formattedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFull.isEmpty else { return }

        lastPartialText = trimmedFull
        let timedSegments = segments.filter { $0.startOffset > 0 || $0.duration > 0 }
        if let lastSeg = timedSegments.last {
            lastPartialEndOffset = max(lastPartialEndOffset, lastSeg.endOffset)
        }

        if isFinal {
            let cues: [PlayerViewModel.SubtitleCue]
            if !timedSegments.isEmpty {
                cues = SpeechSubtitleCueBuilder.buildCues(from: timedSegments, basePTS: basePTS)
            } else {
                let start = max(0, basePTS)
                let fallbackEnd = max(start + 1.0, latestFedAudioEndPTS ?? (basePTS + max(1.0, windowAudioDuration)))
                let untimed = SpeechSubtitleCueBuilder.buildUntimedCues(
                    from: trimmedFull,
                    windowStartPTS: start,
                    windowEndPTS: fallbackEnd
                )
                cues = untimed.isEmpty
                    ? [PlayerViewModel.SubtitleCue(from: start, to: fallbackEnd, content: trimmedFull)]
                    : untimed
            }
            committedSegmentCount = segments.count
            lastPartialText = ""
            lastPartialVolatileCues = []
            onUpdate(
                SpeechRecognitionCueUpdate(
                    committedCues: cues,
                    volatileCues: [],
                    replaceCommittedFromPTS: basePTS
                )
            )
            teardownCurrentWindow(commitPendingVolatile: false)
            return
        }

        let update = SpeechSubtitleCueBuilder.buildLegacyPartialUpdate(
            formattedText: trimmedFull,
            segments: segments,
            basePTS: basePTS,
            windowAudioDuration: windowAudioDuration,
            committedSegmentCount: committedSegmentCount,
            lastCommittedEndOffset: lastCommittedEndOffset,
            lastPartialEndOffset: lastPartialEndOffset,
            latestFedAudioEndPTS: latestFedAudioEndPTS
        )
        committedSegmentCount = update.updatedCommittedSegmentCount
        lastCommittedEndOffset = update.updatedCommittedEndOffset
        lastPartialEndOffset = update.updatedPartialEndOffset
        lastPartialVolatileCues = update.volatileCues

        onUpdate(
            SpeechRecognitionCueUpdate(
                committedCues: update.finalizedBatch,
                volatileCues: update.volatileCues
            )
        )
    }

    private func teardownCurrentWindow(commitPendingVolatile: Bool) {
        if commitPendingVolatile, let basePTS = windowBasePTS {
            if !lastPartialVolatileCues.isEmpty {
                var committed = lastPartialVolatileCues
                if let last = committed.last {
                    let audioEnd = latestFedAudioEndPTS
                        ?? (basePTS + max(lastPartialEndOffset, max(lastCommittedEndOffset + 1.0, windowAudioDuration)))
                    let clampedEnd = max(last.from + 0.5, min(last.to, max(last.from + 0.8, audioEnd)))
                    committed[committed.count - 1] = PlayerViewModel.SubtitleCue(
                        from: last.from,
                        to: clampedEnd,
                        content: last.content
                    )
                }
                onUpdate(SpeechRecognitionCueUpdate(committedCues: committed, volatileCues: []))
            } else if !lastPartialText.isEmpty {
                let tail = SpeechSubtitleCueBuilder.conciseVolatileLine(from: lastPartialText)
                if !tail.isEmpty {
                    let endOffset = max(lastPartialEndOffset, max(lastCommittedEndOffset + 1.0, windowAudioDuration))
                    let endPTS = max(basePTS + 0.8, latestFedAudioEndPTS ?? (basePTS + endOffset))
                    let startPTS = max(basePTS + lastCommittedEndOffset, endPTS - min(3.5, max(1.0, endOffset)))
                    let cue = PlayerViewModel.SubtitleCue(from: startPTS, to: endPTS, content: tail)
                    onUpdate(SpeechRecognitionCueUpdate(committedCues: [cue], volatileCues: []))
                }
            }
        }
        windowGeneration &+= 1
        activeRequest?.endAudio()
        activeRequest = nil
        activeTask?.cancel()
        activeTask = nil
        windowBasePTS = nil
        windowAudioDuration = 0
        latestFedAudioEndPTS = nil
        consecutiveSilenceDuration = 0
        committedSegmentCount = 0
        lastCommittedEndOffset = 0
        lastPartialText = ""
        lastPartialEndOffset = 0
        lastPartialVolatileCues = []
        hasProducedResultInWindow = false
    }

    private static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let stride = max(1, samples.count / 128)
        var sumSq: Float = 0
        var count = 0
        var index = 0
        while index < samples.count {
            let sample = samples[index]
            sumSq += sample * sample
            count += 1
            index += stride
        }
        guard count > 0 else { return 0 }
        return sqrt(sumSq / Float(count))
    }
}

/// Manages system on-device speech subtitle generation from ahead-of-playback PCM audio.
///
/// Primary engine on iOS 26+: `SpeechAnalyzer` + `SpeechTranscriber` when supported and installed.
/// Automatic fallback on iOS 18-25 or missing iOS 26 assets: on-device `SFSpeechRecognizer`
/// with automatic ~48s/pause recognition window rotation.
@MainActor
final class SystemSpeechSubtitleGenerator {
    var onStatusChanged: ((SpeechSubtitleStatus, _ engineLabel: String?, _ canDownloadModel: Bool) -> Void)?
    var onSubtitlesUpdated: (() -> Void)?

    private var store = SpeechSubtitleTimelineStore()
    private var runGeneration: UInt64 = 0
    private var pipelineTask: Task<Void, Never>?
    private var downloadTask: Task<Bool, Never>?
    private weak var currentTap: AudioPCMSubtitleTap?
    private var currentLocale: SpeechSubtitleLocale = .auto
    private var canDownloadModelFlag = false
    private var latestKnownMediaTime: TimeInterval?
    private var activePacer: SpeechAudioPacingController?

    private(set) var status: SpeechSubtitleStatus = .idle

    func activeCue(at time: TimeInterval) -> PlayerViewModel.SubtitleCue? {
        updateMediaTime(time)
        return store.activeCue(at: time)
    }

    func activeText(at time: TimeInterval) -> String? {
        activeCue(at: time)?.content
    }

    func updateMediaTime(_ time: TimeInterval) {
        guard time.isFinite, time >= 0 else { return }
        latestKnownMediaTime = time
        if let pacer = activePacer, pacer.updateMediaTime(time) {
            store.clearVolatile()
        }
    }

    func handleSeek(to time: TimeInterval) {
        guard time.isFinite, time >= 0 else { return }
        latestKnownMediaTime = time
        store.clearVolatile()
        activePacer?.handleSeek(to: time)
        onSubtitlesUpdated?()
    }

    func resetTimeline() {
        store.clearAll()
        activePacer?.handleSeek(to: latestKnownMediaTime)
        onSubtitlesUpdated?()
    }

    func start(
        tap: AudioPCMSubtitleTap,
        locale: SpeechSubtitleLocale,
        initialMediaTime: TimeInterval? = nil
    ) {
        let sameTap = currentTap === tap
        stopInternal(resetStatusToIdle: false)
        currentTap = tap
        currentLocale = locale
        if let initialMediaTime, initialMediaTime.isFinite, initialMediaTime >= 0 {
            latestKnownMediaTime = initialMediaTime
        } else if !sameTap {
            latestKnownMediaTime = nil
        }
        runGeneration &+= 1
        let generation = runGeneration
        canDownloadModelFlag = false
        publishStatus(.preparing, engineLabel: nil, canDownloadModel: false)

        pipelineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPipeline(tap: tap, locale: locale, generation: generation)
        }
    }

    func stop() {
        stopInternal(resetStatusToIdle: true)
    }

    /// Downloads the iOS 26 on-device `SpeechTranscriber` model for `locale` via `AssetInventory`,
    /// then seamlessly restarts the active pipeline on `SpeechAnalyzer` if currently running.
    @discardableResult
    func downloadSpeechAnalyzerModel(for locale: SpeechSubtitleLocale) async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        downloadTask?.cancel()
        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }
            self.publishStatus(.downloadingModel(progress: nil), engineLabel: nil, canDownloadModel: false)
            do {
                let installedLocale = try await Self.installSpeechTranscriberModel(for: locale)
                guard !Task.isCancelled else { return false }
                guard let installedLocale else {
                    self.canDownloadModelFlag = false
                    if let tap = self.currentTap {
                        self.start(tap: tap, locale: locale)
                    } else {
                        self.publishStatus(.idle, engineLabel: nil, canDownloadModel: false)
                    }
                    return false
                }
                self.canDownloadModelFlag = false
                PlayerLog.log("[SpeechSubtitles] iOS 26 SpeechTranscriber model installed for \(installedLocale)")
                if let tap = self.currentTap {
                    self.start(tap: tap, locale: locale)
                } else {
                    self.publishStatus(.idle, engineLabel: nil, canDownloadModel: false)
                }
                return true
            } catch {
                guard !Task.isCancelled else { return false }
                PlayerLog.log("[SpeechSubtitles] model download failed: \(error.localizedDescription)")
                self.canDownloadModelFlag = true
                if let tap = self.currentTap {
                    self.start(tap: tap, locale: locale)
                } else {
                    self.publishStatus(.failed(error.localizedDescription), engineLabel: nil, canDownloadModel: true)
                }
                return false
            }
        }
        downloadTask = task
        return await task.value
    }

    private func stopInternal(resetStatusToIdle: Bool) {
        runGeneration &+= 1
        pipelineTask?.cancel()
        pipelineTask = nil
        activePacer?.finish()
        activePacer = nil
        currentTap?.deactivate()
        store.clearAll()
        if resetStatusToIdle {
            currentTap = nil
            latestKnownMediaTime = nil
            canDownloadModelFlag = false
            publishStatus(.idle, engineLabel: nil, canDownloadModel: false)
            onSubtitlesUpdated?()
        }
    }

    private func publishStatus(
        _ newStatus: SpeechSubtitleStatus,
        engineLabel: String?,
        canDownloadModel: Bool
    ) {
        status = newStatus
        canDownloadModelFlag = canDownloadModel
        onStatusChanged?(newStatus, engineLabel, canDownloadModel)
    }

    private func applyRecognitionUpdate(
        _ update: SpeechRecognitionCueUpdate,
        generation: UInt64
    ) {
        guard runGeneration == generation else { return }
        store.apply(update)
        onSubtitlesUpdated?()
    }

    private struct PacedStreamSession {
        let controller: SpeechAudioPacingController
        let stream: AsyncStream<AudioPCMSubtitleEvent>
        let ingestTask: Task<Void, Never>
        let drainTask: Task<Void, Never>
    }

    private func startPacedSession(from tap: AudioPCMSubtitleTap) -> PacedStreamSession {
        activePacer?.finish()
        let controller = SpeechAudioPacingController(initialMediaTime: latestKnownMediaTime)
        activePacer = controller
        let pacedStream = controller.makePacedStream(
            bufferingNewest: AudioPCMSubtitleTap.defaultBufferCapacity
        )
        let rawStream = tap.makeStream(
            bufferingNewest: AudioPCMSubtitleTap.defaultBufferCapacity
        )
        let ingestTask = Task.detached(priority: .userInitiated) {
            for await event in rawStream {
                if Task.isCancelled { break }
                controller.handleIncoming(event)
            }
            controller.finish()
        }
        let drainTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { break }
                controller.drainTick()
            }
        }
        return PacedStreamSession(
            controller: controller,
            stream: pacedStream,
            ingestTask: ingestTask,
            drainTask: drainTask
        )
    }

    private func stopPacedSession(_ session: PacedStreamSession) {
        session.ingestTask.cancel()
        session.drainTask.cancel()
        session.controller.finish()
        if activePacer === session.controller {
            activePacer = nil
        }
    }

    private func runPipeline(
        tap: AudioPCMSubtitleTap,
        locale: SpeechSubtitleLocale,
        generation: UInt64
    ) async {
        // 1. Request speech authorization via a nonisolated bridge (Apple invokes TCC callbacks
        // on a background XPC queue, never on MainActor).
        let authStatus = await SpeechAuthorizationBridge.requestIfNeeded()
        guard runGeneration == generation, !Task.isCancelled else { return }

        // 2. Primary engine on iOS 26+: SpeechAnalyzer + SpeechTranscriber when model is installed.
        var modelDownloadable = false
        if #available(iOS 26.0, *) {
            let probe = await Self.probeSpeechAnalyzerAvailability(for: locale)
            guard runGeneration == generation, !Task.isCancelled else { return }
            switch probe {
            case .ready(let resolvedLocale, let audioFormat):
                PlayerLog.log(
                    "[SpeechSubtitles] starting iOS 26 SpeechAnalyzer locale=\(resolvedLocale.identifier) " +
                    "sr=\(Int(audioFormat.value.sampleRate)) fmt=\(audioFormat.value.commonFormat.rawValue) " +
                    "interleaved=\(audioFormat.value.isInterleaved)"
                )
                publishStatus(
                    .active(engine: .speechAnalyzer, localeIdentifier: resolvedLocale.identifier),
                    engineLabel: SpeechSubtitleEngineKind.speechAnalyzer.displayLabel,
                    canDownloadModel: false
                )
                let paced = startPacedSession(from: tap)
                let startupFailed = await runSpeechAnalyzerLoop(
                    paced: paced,
                    resolvedLocale: resolvedLocale,
                    targetFormat: audioFormat,
                    generation: generation,
                    allowFallbackOnStartupError: authStatus == .authorized
                )
                stopPacedSession(paced)
                guard runGeneration == generation, !Task.isCancelled else { return }
                if !startupFailed {
                    return
                }
                PlayerLog.log(
                    "[SpeechSubtitles] iOS 26 SpeechAnalyzer startup failed - falling back to SFSpeechRecognizer"
                )
            case .needsDownload:
                modelDownloadable = true
                PlayerLog.log("[SpeechSubtitles] iOS 26 model not installed yet - falling back to SFSpeechRecognizer")
            case .unavailable:
                break
            }
        }

        // 3. Automatic on-device fallback via SFSpeechRecognizer (iOS 18-25 or uninstalled iOS 26 asset).
        guard authStatus == .authorized else {
            publishStatus(.permissionDenied, engineLabel: nil, canDownloadModel: modelDownloadable)
            return
        }

        guard let fallbackLocale = Self.resolveLegacyLocale(for: locale) else {
            publishStatus(
                .failed(String(localized: "Selected speech recognition language is unavailable on this device.")),
                engineLabel: nil,
                canDownloadModel: modelDownloadable
            )
            return
        }

        let legacyEngine = LegacySFSpeechEngine(
            locale: fallbackLocale,
            onUpdate: { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.applyRecognitionUpdate(update, generation: generation)
                }
            },
            onEngineKindChanged: { [weak self] updatedKind in
                Task { @MainActor [weak self] in
                    guard let self, self.runGeneration == generation else { return }
                    self.publishStatus(
                        .active(engine: updatedKind, localeIdentifier: fallbackLocale.identifier),
                        engineLabel: updatedKind.displayLabel,
                        canDownloadModel: self.canDownloadModelFlag
                    )
                }
            },
            onFatalError: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.runGeneration == generation else { return }
                    self.publishStatus(
                        .failed(message),
                        engineLabel: nil,
                        canDownloadModel: self.canDownloadModelFlag
                    )
                }
            }
        )

        guard let engineKind = legacyEngine.prepare() else {
            publishStatus(
                .failed(String(localized: "System speech recognizer is temporarily unavailable.")),
                engineLabel: nil,
                canDownloadModel: modelDownloadable
            )
            return
        }

        PlayerLog.log(
            "[SpeechSubtitles] starting \(engineKind.rawValue) locale=\(fallbackLocale.identifier)"
        )
        publishStatus(
            .active(engine: engineKind, localeIdentifier: fallbackLocale.identifier),
            engineLabel: engineKind.displayLabel,
            canDownloadModel: modelDownloadable
        )

        let paced = startPacedSession(from: tap)
        let ingestTask = paced.ingestTask
        let drainTask = paced.drainTask
        let controller = paced.controller
        await withTaskCancellationHandler {
            for await event in paced.stream {
                if Task.isCancelled || self.runGeneration != generation {
                    break
                }
                legacyEngine.handle(event)
            }
        } onCancel: {
            ingestTask.cancel()
            drainTask.cancel()
            controller.finish()
            legacyEngine.stop()
        }
        stopPacedSession(paced)
        legacyEngine.stop()
    }

    // MARK: - Locale Resolution

    private nonisolated static func resolveLegacyLocale(for locale: SpeechSubtitleLocale) -> Locale? {
        for identifier in locale.candidateIdentifiers() {
            let candidate = Locale(identifier: identifier)
            if let recognizer = SFSpeechRecognizer(locale: candidate), recognizer.isAvailable {
                return candidate
            }
        }
        if let fallback = SFSpeechRecognizer(), fallback.isAvailable {
            return fallback.locale
        }
        return nil
    }

    // MARK: - iOS 26 SpeechAnalyzer + SpeechTranscriber Primary Engine

    private struct UncheckedSendableAudioFormat: @unchecked Sendable {
        let value: AVAudioFormat
    }

    @available(iOS 26.0, *)
    private enum SpeechAnalyzerProbeResult: Sendable {
        case ready(locale: Locale, audioFormat: UncheckedSendableAudioFormat)
        case needsDownload(locale: Locale)
        case unavailable
    }

    @available(iOS 26.0, *)
    private nonisolated static func ensureLocaleReserved(_ resolvedLocale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0 == resolvedLocale || $0.identifier == resolvedLocale.identifier }) {
            return
        }
        let maxReserved = AssetInventory.maximumReservedLocales
        if maxReserved > 0, reserved.count >= maxReserved {
            let releaseCount = reserved.count - maxReserved + 1
            for oldest in reserved.prefix(releaseCount) {
                _ = await AssetInventory.release(reservedLocale: oldest)
            }
        }
        do {
            _ = try await AssetInventory.reserve(locale: resolvedLocale)
        } catch {
            PlayerLog.log(
                "[SpeechSubtitles] AssetInventory.reserve(\(resolvedLocale.identifier)) failed: " +
                "\(error.localizedDescription)"
            )
        }
    }

    @available(iOS 26.0, *)
    private nonisolated static func resolveSupportedSpeechTranscriberLocale(
        for locale: SpeechSubtitleLocale
    ) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        for identifier in locale.candidateIdentifiers() {
            if let supported = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)
            ) {
                return supported
            }
        }
        return nil
    }

    @available(iOS 26.0, *)
    private nonisolated static func installSpeechTranscriberModel(
        for locale: SpeechSubtitleLocale
    ) async throws -> String? {
        guard let resolvedLocale = await resolveSupportedSpeechTranscriberLocale(for: locale) else {
            return nil
        }
        await ensureLocaleReserved(resolvedLocale)
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        if assetStatus == .installed {
            return resolvedLocale.identifier
        }
        guard assetStatus == .supported || assetStatus == .downloading else {
            return nil
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return resolvedLocale.identifier
    }

    @available(iOS 26.0, *)
    private nonisolated static func probeSpeechAnalyzerAvailability(
        for locale: SpeechSubtitleLocale
    ) async -> SpeechAnalyzerProbeResult {
        guard let supportedLocale = await resolveSupportedSpeechTranscriberLocale(for: locale) else {
            return .unavailable
        }
        let probeTranscriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        let assetStatus = await AssetInventory.status(forModules: [probeTranscriber])
        switch assetStatus {
        case .installed:
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [probeTranscriber]
            ) else {
                return .unavailable
            }
            return .ready(locale: supportedLocale, audioFormat: UncheckedSendableAudioFormat(value: format))
        case .supported, .downloading:
            return .needsDownload(locale: supportedLocale)
        case .unsupported:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    @available(iOS 26.0, *)
    private func runSpeechAnalyzerLoop(
        paced: PacedStreamSession,
        resolvedLocale: Locale,
        targetFormat: UncheckedSendableAudioFormat,
        generation: UInt64,
        allowFallbackOnStartupError: Bool
    ) async -> Bool {
        // Offload audio conversion and SpeechAnalyzer streaming off MainActor.
        let onUpdate: @Sendable (SpeechRecognitionCueUpdate) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.applyRecognitionUpdate(update, generation: generation)
            }
        }
        let onFailure: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.runGeneration == generation else { return }
                self.publishStatus(.failed(message), engineLabel: nil, canDownloadModel: false)
            }
        }

        let stream = paced.stream
        let pacerController = paced.controller
        let ingestTask = paced.ingestTask
        let drainTask = paced.drainTask
        let workerTask = Task.detached(priority: .userInitiated) {
            await Self.consumeWithSpeechAnalyzer(
                stream: stream,
                pacerController: pacerController,
                locale: resolvedLocale,
                targetFormat: targetFormat.value,
                allowFallbackOnStartupError: allowFallbackOnStartupError,
                onUpdate: onUpdate,
                onFailure: onFailure
            )
        }
        return await withTaskCancellationHandler {
            await workerTask.value
        } onCancel: {
            ingestTask.cancel()
            drainTask.cancel()
            pacerController.finish()
            workerTask.cancel()
        }
    }

    @available(iOS 26.0, *)
    private nonisolated static func consumeWithSpeechAnalyzer(
        stream: AsyncStream<AudioPCMSubtitleEvent>,
        pacerController: SpeechAudioPacingController,
        locale: Locale,
        targetFormat: AVAudioFormat,
        allowFallbackOnStartupError: Bool,
        onUpdate: @escaping @Sendable (SpeechRecognitionCueUpdate) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        await ensureLocaleReserved(locale)
        let converter = PCMBufferConverter(targetFormat: targetFormat)

        var activeAnalyzer: SpeechAnalyzer?
        var activeInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        var activeResultTask: Task<Void, Never>?
        let hasEmittedCue = OSAllocatedUnfairLock(initialState: false)

        func tearDownEpoch() async {
            activeInputContinuation?.finish()
            activeInputContinuation = nil
            activeResultTask?.cancel()
            activeResultTask = nil
            if let analyzer = activeAnalyzer {
                activeAnalyzer = nil
                await analyzer.cancelAndFinishNow()
            }
            converter.reset()
        }

        func startEpoch(basePTS: TimeInterval) async -> Bool {
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange]
            )
            let resultsSequence = transcriber.results
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .bufferingNewest(128)
            )

            let resultTask = Task {
                do {
                    for try await result in resultsSequence {
                        if Task.isCancelled { break }
                        let update = Self.extractCueUpdate(
                            from: result,
                            basePTS: basePTS,
                            latestFedAudioEndPTS: pacerController.latestFedAudioEndPTS
                        )
                        if !update.committedCues.isEmpty || !update.volatileCues.isEmpty {
                            hasEmittedCue.withLock { $0 = true }
                        }
                        onUpdate(update)
                    }
                } catch {
                    if !Task.isCancelled {
                        PlayerLog.log(
                            "[SpeechSubtitles] SpeechTranscriber results ended: \(error.localizedDescription)"
                        )
                    }
                }
            }

            do {
                try await analyzer.start(inputSequence: inputStream)
                activeAnalyzer = analyzer
                activeInputContinuation = inputContinuation
                activeResultTask = resultTask
                return true
            } catch {
                inputContinuation.finish()
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                let emittedAny = hasEmittedCue.withLock { $0 }
                if !allowFallbackOnStartupError || emittedAny {
                    onFailure(error.localizedDescription)
                }
                return false
            }
        }

        for await event in stream {
            if Task.isCancelled { break }
            switch event {
            case .discontinuity(let reason, _):
                await tearDownEpoch()
                let clearAll = reason == .streamReset || reason == .sessionStopped
                onUpdate(SpeechRecognitionCueUpdate(committedCues: [], volatileCues: [], clearAll: clearAll))

            case .pcm(let chunk):
                if activeAnalyzer == nil {
                    let started = await startEpoch(basePTS: chunk.pts)
                    if !started {
                        await tearDownEpoch()
                        let emittedAny = hasEmittedCue.withLock { $0 }
                        return allowFallbackOnStartupError && !emittedAny
                    }
                }
                if let pcmBuffer = converter.convert(chunk) {
                    let input = AnalyzerInput(buffer: pcmBuffer)
                    activeInputContinuation?.yield(input)
                }
            }
        }

        await tearDownEpoch()
        return false
    }

    @available(iOS 26.0, *)
    private nonisolated static func extractCueUpdate(
        from result: SpeechTranscriber.Result,
        basePTS: TimeInterval,
        latestFedAudioEndPTS: TimeInterval?
    ) -> SpeechRecognitionCueUpdate {
        let attributed = result.text
        let plain = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return SpeechRecognitionCueUpdate() }

        // Extract word/phrase time ranges from AttributedString runs when present.
        var timedSegments: [SpeechSubtitleCueBuilder.TimedSegment] = []
        for run in attributed.runs {
            if let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
               timeRange.start.isNumeric,
               timeRange.duration.isNumeric {
                let startSec = timeRange.start.seconds
                let durSec = timeRange.duration.seconds
                if startSec.isFinite, durSec.isFinite, startSec >= 0, durSec >= 0 {
                    let text = String(attributed[run.range].characters)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        timedSegments.append(
                            SpeechSubtitleCueBuilder.TimedSegment(
                                text: text,
                                startOffset: startSec,
                                duration: max(0.05, durSec)
                            )
                        )
                    }
                }
            }
        }

        let rangeStartOffset: TimeInterval?
        let rangeDuration: TimeInterval?
        if result.range.start.isNumeric, result.range.duration.isNumeric,
           result.range.start.seconds.isFinite, result.range.duration.seconds.isFinite,
           result.range.start.seconds >= 0 {
            rangeStartOffset = result.range.start.seconds
            rangeDuration = max(0, result.range.duration.seconds)
        } else {
            rangeStartOffset = nil
            rangeDuration = nil
        }

        return SpeechSubtitleCueBuilder.buildSpeechAnalyzerUpdate(
            plainText: plain,
            timedSegments: timedSegments,
            rangeStartOffset: rangeStartOffset,
            rangeDuration: rangeDuration,
            isFinal: result.isFinal,
            basePTS: basePTS,
            latestFedAudioEndPTS: latestFedAudioEndPTS
        )
    }
}
