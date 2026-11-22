import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Record the target and its starting clock so stale pre-travel samples cannot prove arrival.
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

    /// Keep both strip endpoints and the statistics row in the same finite timeline.
    func clampedSeekableDisplayTime(_ value: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(Self.normalizedBufferedTime(value), duration)
    }

    /// A scrub before the sampled range cannot claim coverage up to its end.
    func seekStripBufferedEnd(at position: TimeInterval, isScrubbing: Bool) -> TimeInterval? {
        guard let range = displayedBufferedRange else { return nil }
        guard !isScrubbing || position >= range.start else { return nil }
        return clampedSeekableDisplayTime(range.end)
    }

    /// The published strip endpoint measured from the shared preview or published clock.
    func displayedBufferAhead(gestureDisplay: PlayerGestureDisplay) -> TimeInterval? {
        guard mode.isSeekable, currentURL != nil, duration.isFinite, duration > 0 else { return nil }
        // Remote VLC publishes its playhead as the endpoint without measuring availability.
        guard mode == .offline || backendKind != .vlc else { return nil }
        let position = seekStripDisplayPosition(gestureDisplay: gestureDisplay, samplingClock: false)
        guard let end = seekStripBufferedEnd(at: position, isScrubbing: gestureDisplay.isSeeking) else { return nil }
        return max(0, end - position)
    }

    /// Retire both the pending freeze check and the display drive.
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

    /// Clear extrapolated display progress after the media clock resumes.
    private func clearNearEndPresentation() {
        nearEndStallDriveTask?.cancel()
        nearEndStallDriveTask = nil
        nearEndStallWallStart = nil
        nearEndStallMediaStart = nil
        nearEndDisplayTime = nil
        nearEndStallLogged = false
    }

    /// Arm display extrapolation only after an actual near-EOF media freeze.
    func noteNearEndMediaSample(_ sample: TimeInterval, duration total: TimeInterval) {
        guard NearEndClockPolicy.isInNearEndWindow(media: sample, duration: total) else {
            if nearEndStallWallStart != nil || nearEndFreezeCandidateMedia != nil {
                clearNearEndStall()
            }
            return
        }

        let advanced = nearEndFreezeCandidateMedia.map { sample > $0 + 0.05 } ?? true
        if advanced {
            // Real media tick — presentation must not outrun truth forever.
            if nearEndStallWallStart != nil {
                clearNearEndPresentation()
            }
            nearEndFreezeCandidateMedia = sample
            scheduleNearEndFreezeArm(anchor: sample)
            return
        }

        // Still frozen at (approx) the candidate. Ensure a freeze-arm is pending
        // if presentation is not already live.
        if nearEndFreezeCandidateMedia == nil {
            nearEndFreezeCandidateMedia = sample
        }
        if nearEndStallWallStart == nil, nearEndFreezeArmTask == nil {
            scheduleNearEndFreezeArm(anchor: nearEndFreezeCandidateMedia ?? sample)
        }
    }

    /// Delay arming until the same near-EOF media position is still frozen during active playback.
    private func scheduleNearEndFreezeArm(anchor: TimeInterval) {
        nearEndFreezeArmTask?.cancel()
        nearEndFreezeArmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.nearEndFreezeThreshold * 1000)))
            guard let self, !Task.isCancelled else { return }
            guard self.nearEndStallWallStart == nil else { return }
            guard !self.playbackEnded, !self.isSeekInFlight else { return }
            guard self.userWantsPlaying, self.backend.isPlaying || self.isPlaying else { return }
            let m = self.mediaTime
            // Still frozen near the anchor (media may have inched by a few ms).
            guard m <= anchor + 0.05 else { return }
            guard NearEndClockPolicy.isInNearEndWindow(media: m, duration: self.duration) else { return }
            self.armNearEndStall(at: m, duration: self.duration)
        }
    }

    /// Advance presentation at 4 Hz while near-EOF media callbacks are frozen; mediaTime remains unchanged.
    private func armNearEndStall(at sample: TimeInterval, duration total: TimeInterval) {
        guard NearEndClockPolicy.isInNearEndWindow(media: sample, duration: total) else { return }
        if nearEndStallWallStart != nil { return }
        let now = CACurrentMediaTime()
        nearEndStallWallStart = now
        nearEndStallMediaStart = sample
        // Seed display immediately so the scrubber moves without waiting for
        // the first drive sleep. mediaTime stays at the frozen sample.
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
                // Stop advancing display if the user paused or transport died
                // without endReached. Keep the last display value; re-anchor
                // wall so resume does not jump by pause duration.
                guard self.userWantsPlaying, self.backend.isPlaying || self.isPlaying else {
                    self.nearEndStallWallStart = CACurrentMediaTime()
                    self.nearEndStallMediaStart = self.nearEndDisplayTime ?? self.mediaTime
                    continue
                }
                let elapsed = CACurrentMediaTime() - wall
                let extrapolated = media + elapsed * Double(max(self.playbackRate, 0.01))
                let clamped = min(max(extrapolated, media), self.duration)
                // Monotonic write into presentation only. @Observable
                // invalidates scrubbers via nearEndDisplayTime → displayTime.
                let shown = self.nearEndDisplayTime ?? media
                if clamped > shown + 0.05 {
                    self.nearEndDisplayTime = clamped
                }
                if clamped >= self.duration - 0.05 || (self.nearEndDisplayTime ?? 0) >= self.duration - 0.05 {
                    // Reached the declared end on the wall clock for display.
                    // mediaTime stays frozen until playedToTheEnd end policy.
                    self.nearEndDisplayTime = self.duration
                    return
                }
            }
        }
    }

    // MARK: - Private

    static func normalizedBufferedTime(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }

    func resetBufferedTime(raw: TimeInterval, displayedEnd: TimeInterval?) {
        withMutation(keyPath: \.bufferedTime) {
            bufferedTimeStorage = raw
            // Direct endpoints are local whole-file ranges or the completion point.
            let range = displayedEnd.flatMap { end in
                BufferedDisplayRange(start: mode == .offline ? 0 : end, end: end)
            }
            bufferedTimeProjection.reset(range: range)
            bufferedDisplayDiagnostic = nil
        }
    }

    /// Connected online evidence belongs to one playhead, so native travel retires it.
    func invalidateBufferedDisplayForSeek() {
        guard mode == .vod else { return }
        bufferedDisplayDiagnostic = nil
        guard bufferedTimeProjection.publishedRange != nil else {
            bufferedTimeProjection.invalidateSampling()
            return
        }
        withMutation(keyPath: \.bufferedTime) {
            bufferedTimeProjection.reset()
        }
    }

    /// Store every raw sample for recovery/diagnostics. Query display evidence
    /// only at the UI cadence or an explicit invalidation boundary.
    func publishBufferedTime(
        _ value: TimeInterval, display: () -> MediaBufferDisplaySample?, at now: TimeInterval
    ) {
        let rawValue = Self.normalizedBufferedTime(value)
        let becameZero = rawValue == 0 && bufferedTimeStorage != 0
        // This direct write is intentionally outside `withMutation`: it is
        // backend truth, not a UI publication.
        bufferedTimeStorage = rawValue
        guard canPublishBufferedDisplay else { return }
        if mode == .vod, pendingSeekTarget != nil || isSeekInFlight {
            invalidateBufferedDisplayForSeek()
            return
        }
        if mode == .offline {
            // Before a backend knows the local file's length, playableTime can echo its position.
            guard duration.isFinite, duration > 0, rawValue >= duration else { return }
        }
        guard bufferedTimeProjection.admitSample(at: now, force: becameZero) else { return }
        // A zero raw runway may still have independent resident evidence.
        // Sample that evidence instead of assuming the displayed range is zero.
        let sample = display()
        let range = bufferDisplayRange(sample: sample, rawEndpoint: value)
        // Capture the same admitted read, never query the book again for logs.
        bufferedDisplayDiagnostic = PlayerLog.isCapturing ? BufferedDisplayDiagnosticSample(
            backendIdentity: ObjectIdentifier(backend), runtimeGeneration: backend.runtimeGeneration,
            loadGeneration: loadGeneration, ownerLeaseGeneration: ownerLeaseGeneration,
            sampledAt: now, rawEndpoint: rawValue, display: sample
        ) : nil
        withMutation(keyPath: \.bufferedTime) {
            bufferedTimeProjection.ingest(range: range)
        }
    }

    private func bufferDisplayRange(
        sample: MediaBufferDisplaySample?, rawEndpoint: TimeInterval
    ) -> BufferedDisplayRange? {
        if mode == .offline { return BufferedDisplayRange(start: 0, end: rawEndpoint) }
        if let sample, let end = sample.bufferedThrough {
            return BufferedDisplayRange(start: sample.position, end: end)
        }
        return BufferedDisplayRange(start: backend.currentTime, end: rawEndpoint)
    }

    /// Applies the shared orientation policy to a valid track/frame geometry.
    /// A zero-size ready track is deliberately ignored; the next dynamic
    /// stats sample can resolve live portrait layout without reopening media.
    func applyVideoGeometry(_ size: CGSize) {
        var state = portraitPropagation
        let changed = state.applyVideoGeometry(
            width: Double(size.width),
            height: Double(size.height),
            isPad: UIDevice.current.userInterfaceIdiom == .pad
        )
        portraitPropagation = state
        if changed {
            isPortraitContent = state.isPortrait
        }
    }
}

/// Ignore missing geometry and preserve normalized VOD orientation hints.
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
            nextPortrait = height > width
        }

        guard nextPortrait != isPortrait else { return false }
        isPortrait = nextPortrait
        return true
    }
}

/// One bounded diagnostic value paired with an admitted UI sample. It retains
/// no backend, query, lease or payload, and is never playback authority.
struct BufferedDisplayDiagnosticSample {
    let backendIdentity: ObjectIdentifier
    let runtimeGeneration: UInt64
    let loadGeneration: Int
    let ownerLeaseGeneration: UInt64
    let sampledAt: TimeInterval
    let rawEndpoint: TimeInterval
    let display: MediaBufferDisplaySample?
}

/// Admit bounded display queries separately from the player's lossless raw samples.
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

    /// Runs before the optional backend query, including when a rejected tick
    /// carries a large raw change. Media progression never waits for this gate.
    mutating func admitSample(at now: TimeInterval, force: Bool = false) -> Bool {
        guard now.isFinite else {
            invalidateSampling()
            return false
        }
        if !force, let lastSampleAt, now >= lastSampleAt, now - lastSampleAt < cadence {
            return false
        }
        lastSampleAt = now
        return true
    }

    /// Reset/seek edges need a fresh sample on the next admitted backend tick.
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
