import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func armDurableResumeTarget(_ target: TimeInterval?, source: String) {
        durableResumeTarget = target
        durableResumeArmedFrom = mediaTime.isFinite ? mediaTime : 0
        durableResumeArmedAtWall = CACurrentMediaTime()
        if let target {
            PlayerLog.log("[Player] resume-target=\(String(format: "%.1f", target))s (\(source))")
        }
    }

    func resolvedDisplayTime(mediaTime sample: TimeInterval) -> TimeInterval {
        NearEndClockPolicy.resolveDisplayTime(
            playbackEnded: playbackEnded,
            duration: duration,
            pendingSeek: pendingSeekTarget,
            nearEndDisplay: nearEndDisplayTime,
            mediaTime: sample
        )
    }

    func seekStripDisplayPosition(
        gestureDisplay: PlayerGestureDisplay, samplingClock: Bool
    ) -> TimeInterval {
        let position = gestureDisplay.isSeeking ? gestureDisplay.seekValue
            : seekStripDisplayTime(samplingClock: samplingClock)
        return clampedSeekableDisplayTime(position)
    }

    private func seekStripDisplayTime(samplingClock: Bool) -> TimeInterval {
        guard samplingClock, canSampleSeekStripClock else { return displayTime }
        let sample = nativeSeekSettledPosition
        guard sample.isFinite, sample >= 0 else { return displayTime }
        return resolvedDisplayTime(mediaTime: sample)
    }

    func clampedSeekableDisplayTime(_ value: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(Self.normalizedBufferedTime(value), duration)
    }

    var seekStripBufferedEnd: TimeInterval? {
        guard canPublishBufferedDisplay else { return nil }
        let published = displayedBufferedRange.map { clampedSeekableDisplayTime($0.end) }
        guard !isSeekInFlight, pendingSeekTarget == nil else { return published }
        let actualMediaPosition = max(
            displayTime,
            canSampleSeekStripClock && nativeSeekSettledPosition.isFinite ? nativeSeekSettledPosition : 0
        )
        let floor = clampedSeekableDisplayTime(actualMediaPosition)
        guard let published else { return floor > 0 ? floor : nil }
        return max(published, floor)
    }

    func displayedBufferAhead(gestureDisplay: PlayerGestureDisplay) -> TimeInterval? {
        guard mode.isSeekable, currentURL != nil, duration.isFinite, duration > 0 else { return nil }
        guard mode == .offline || backendKind != .vlc else { return nil }
        let position = seekStripDisplayPosition(gestureDisplay: gestureDisplay, samplingClock: false)
        guard let end = seekStripBufferedEnd else { return nil }
        return max(0, end - position)
    }

    func clearNearEndStall() {
        nearEndStallDriveTask?.cancel()
        nearEndStallDriveTask = nil
        nearEndFreezeArmTask?.cancel()
        nearEndFreezeArmTask = nil
        nearEndStallWallStart = nil
        nearEndStallMediaStart = nil
        nearEndDisplayTime = nil
        nearEndFreezeCandidateMedia = nil
        nearEndStallLogged = false
    }

    private func clearNearEndPresentation() {
        nearEndStallDriveTask?.cancel()
        nearEndStallDriveTask = nil
        nearEndStallWallStart = nil
        nearEndStallMediaStart = nil
        nearEndDisplayTime = nil
        nearEndStallLogged = false
    }

    func noteNearEndMediaSample(_ sample: TimeInterval, duration total: TimeInterval) {
        guard NearEndClockPolicy.isInNearEndWindow(media: sample, duration: total) else {
            if nearEndStallWallStart != nil || nearEndFreezeCandidateMedia != nil {
                clearNearEndStall()
            }
            return
        }

        let advanced = nearEndFreezeCandidateMedia.map { sample > $0 + 0.05 } ?? true
        if advanced {
            if nearEndStallWallStart != nil {
                clearNearEndPresentation()
            }
            nearEndFreezeCandidateMedia = sample
            scheduleNearEndFreezeArm(anchor: sample)
            return
        }

        if nearEndFreezeCandidateMedia == nil {
            nearEndFreezeCandidateMedia = sample
        }
        if nearEndStallWallStart == nil, nearEndFreezeArmTask == nil {
            scheduleNearEndFreezeArm(anchor: nearEndFreezeCandidateMedia ?? sample)
        }
    }

    private func scheduleNearEndFreezeArm(anchor: TimeInterval) {
        nearEndFreezeArmTask?.cancel()
        nearEndFreezeArmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.nearEndFreezeThreshold * 1000)))
            guard let self, !Task.isCancelled else { return }
            guard self.nearEndStallWallStart == nil else { return }
            guard !self.playbackEnded, !self.isSeekInFlight else { return }
            guard self.userWantsPlaying, self.backend.isPlaying || self.isPlaying else { return }
            let m = self.mediaTime
            guard m <= anchor + 0.05 else { return }
            guard NearEndClockPolicy.isInNearEndWindow(media: m, duration: self.duration) else { return }
            self.armNearEndStall(at: m, duration: self.duration)
        }
    }

    private func armNearEndStall(at sample: TimeInterval, duration total: TimeInterval) {
        guard NearEndClockPolicy.isInNearEndWindow(media: sample, duration: total) else { return }
        if nearEndStallWallStart != nil { return }
        let now = CACurrentMediaTime()
        nearEndStallWallStart = now
        nearEndStallMediaStart = sample
        if let shown = nearEndDisplayTime {
            nearEndDisplayTime = max(shown, sample)
        } else {
            nearEndDisplayTime = sample
        }
        if !nearEndStallLogged {
            nearEndStallLogged = true
            PlayerLog.log(
                "[Player] near-EOF clock stall at \(String(format: "%.1f", sample))s of \(String(format: "%.1f", total))s — driving displayTime from wall clock (mediaTime frozen)"
            )
        }
        nearEndStallDriveTask?.cancel()
        nearEndStallDriveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                guard let wall = self.nearEndStallWallStart,
                      let media = self.nearEndStallMediaStart,
                      self.duration > 0, !self.playbackEnded else {
                    self.clearNearEndStall()
                    return
                }
                guard self.userWantsPlaying, self.backend.isPlaying || self.isPlaying else {
                    self.nearEndStallWallStart = CACurrentMediaTime()
                    self.nearEndStallMediaStart = self.nearEndDisplayTime ?? self.mediaTime
                    continue
                }
                let elapsed = CACurrentMediaTime() - wall
                let extrapolated = media + elapsed * Double(max(self.playbackRate, 0.01))
                let clamped = min(max(extrapolated, media), self.duration)
                let shown = self.nearEndDisplayTime ?? media
                if clamped > shown + 0.05 {
                    self.nearEndDisplayTime = clamped
                }
                if clamped >= self.duration - 0.05 || (self.nearEndDisplayTime ?? 0) >= self.duration - 0.05 {
                    self.nearEndDisplayTime = self.duration
                    return
                }
            }
        }
    }

    // MARK: - Private

    static func normalizedBufferedTime(_ value: TimeInterval) -> TimeInterval {
        PlaybackClockState.normalizedBufferedTime(value)
    }

    func resetBufferedTime(raw: TimeInterval, displayedEnd: TimeInterval?) {
        clock.resetBufferedTime(raw: raw, displayedEnd: displayedEnd, isOffline: mode == .offline)
    }

    func prepareBufferedDisplayForSeek(to target: TimeInterval) {
        guard mode == .vod else { return }
        let anchor = Self.normalizedBufferedTime(target)
        let nextRange: BufferedDisplayRange?
        if let range = bufferedTimeProjection.publishedRange,
           anchor >= range.start - 0.5,
           anchor <= range.end {
            nextRange = BufferedDisplayRange(start: min(anchor, range.end), end: range.end)
        } else {
            nextRange = BufferedDisplayRange(start: anchor, end: anchor)
        }
        bufferedDisplayDiagnostic = nil
        guard bufferedTimeProjection.publishedRange != nextRange else {
            bufferedTimeProjection.invalidateSampling()
            return
        }
        clock.mutateBufferedTime {
            bufferedTimeProjection.reset(range: nextRange)
        }
    }

    func publishBufferedTime(
        _ value: TimeInterval, display: () -> MediaBufferDisplaySample?, at now: TimeInterval
    ) {
        let rawValue = Self.normalizedBufferedTime(value)
        let becameZero = rawValue == 0 && bufferedTimeStorage != 0
        bufferedTimeStorage = rawValue
        guard canPublishBufferedDisplay else { return }
        if mode == .offline {
            guard duration.isFinite, duration > 0, rawValue >= duration else { return }
        }
        guard bufferedTimeProjection.canAdmitSample(at: now, force: becameZero) else { return }
        let sample = display()
        let seekTarget = mode == .vod ? (pendingSeekTarget ?? backend.pendingSeekTarget) : nil
        if let seekTarget, !Self.isSettledSeekBufferSample(sample, target: seekTarget) {
            return
        }
        let range = bufferDisplayRange(sample: sample, rawEndpoint: value)
        bufferedTimeProjection.recordSample(at: now)
        bufferedDisplayDiagnostic = PlayerLog.isCapturing ? BufferedDisplayDiagnosticSample(
            backendIdentity: ObjectIdentifier(backend), runtimeGeneration: backend.runtimeGeneration,
            loadGeneration: loadGeneration, ownerLeaseGeneration: ownerLeaseGeneration,
            sampledAt: now, rawEndpoint: rawValue, display: sample
        ) : nil
        clock.mutateBufferedTime {
            bufferedTimeProjection.ingest(range: range)
        }
    }

    private static func isSettledSeekBufferSample(
        _ sample: MediaBufferDisplaySample?,
        target: TimeInterval
    ) -> Bool {
        guard let sample,
              sample.position.isFinite,
              abs(sample.position - target) <= 0.5,
              let end = sample.bufferedThrough,
              end.isFinite,
              end >= target else {
            return false
        }
        return true
    }

    private func bufferDisplayRange(
        sample: MediaBufferDisplaySample?, rawEndpoint: TimeInterval
    ) -> BufferedDisplayRange? {
        if mode == .offline { return BufferedDisplayRange(start: 0, end: rawEndpoint) }
        if let sample, let end = sample.bufferedThrough {
            return BufferedDisplayRange(start: sample.position, end: end)
        }
        let start = min(Self.normalizedBufferedTime(backend.currentTime), rawEndpoint)
        return BufferedDisplayRange(start: start, end: rawEndpoint)
    }

    func applyVideoGeometry(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return
        }
        let decodedAspect = DetailPlayerGeometry.normalizedAspect(size.width / size.height)
        if let decodedAspect {
            if let current = videoAspectRatio {
                if abs(current - decodedAspect) >= 0.005 {
                    videoAspectRatio = decodedAspect
                }
            } else {
                videoAspectRatio = decodedAspect
            }
        }
        if mode == .offline, let aid = currentAid, let cid = currentCid {
            let w = Int(size.width.rounded())
            let h = Int(size.height.rounded())
            if w > 0, h > 0 {
                OfflineProgressStore.shared.recordDimensions(width: w, height: h, aid: aid, cid: cid)
            }
        }
        var state = portraitPropagation
        let changed = state.applyVideoGeometry(
            width: Double(size.width),
            height: Double(size.height),
            isPad: !DeviceCapability.usesCompactPortraitVideoFraming
        )
        portraitPropagation = state
        if changed || isPortraitContent != state.isPortrait {
            isPortraitContent = state.isPortrait
        }
    }
}

struct PlayerPortraitPropagationState: Equatable, Sendable {
    let mode: PlayerMode
    let apiHint: Bool?
    private(set) var isPortrait: Bool
    private(set) var hasValidVideoGeometry = false

    init(mode: PlayerMode, apiHint: Bool?, initialIsPortrait: Bool) {
        self.mode = mode
        self.apiHint = apiHint
        self.isPortrait = initialIsPortrait
    }

    @discardableResult
    mutating func applyVideoGeometry(
        width: Double,
        height: Double,
        isPad: Bool
    ) -> Bool {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return false
        }

        hasValidVideoGeometry = true
        let nextPortrait: Bool
        if isPad {
            nextPortrait = false
        } else if let apiHint, mode == .vod {
            nextPortrait = apiHint
        } else {
            nextPortrait = DetailPlayerGeometry.isPortraitAspect(
                CGFloat(width / height),
                fallback: height > width
            )
        }

        guard nextPortrait != isPortrait else { return false }
        isPortrait = nextPortrait
        return true
    }
}

struct BufferedDisplayDiagnosticSample {
    let backendIdentity: ObjectIdentifier
    let runtimeGeneration: UInt64
    let loadGeneration: Int
    let ownerLeaseGeneration: UInt64
    let sampledAt: TimeInterval
    let rawEndpoint: TimeInterval
    let display: MediaBufferDisplaySample?
}

struct BufferedDisplayRange: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    init?(start: TimeInterval, end: TimeInterval) {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
        self.start = start
        self.end = end
    }
}

struct BufferedTimeUIProjection: Equatable, Sendable {
    static let defaultCadence: TimeInterval = 0.25

    let cadence: TimeInterval
    private(set) var publishedRange: BufferedDisplayRange?
    private var lastSampleAt: TimeInterval?

    init(cadence: TimeInterval = Self.defaultCadence) {
        self.cadence = max(0, cadence)
    }

    func canAdmitSample(at now: TimeInterval, force: Bool = false) -> Bool {
        guard now.isFinite else { return false }
        if !force, let lastSampleAt, now >= lastSampleAt, now - lastSampleAt < cadence {
            return false
        }
        return true
    }

    mutating func recordSample(at now: TimeInterval) {
        if now.isFinite {
            lastSampleAt = now
        } else {
            invalidateSampling()
        }
    }

    mutating func invalidateSampling() {
        lastSampleAt = nil
    }

    mutating func ingest(range: BufferedDisplayRange?) {
        publishedRange = range
    }

    mutating func reset(range: BufferedDisplayRange? = nil) {
        publishedRange = range
        invalidateSampling()
    }
}
