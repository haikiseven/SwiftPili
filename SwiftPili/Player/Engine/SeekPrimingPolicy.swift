import Foundation

/// Seek readiness for the Demand engine, as a pure decision.
///
/// **The contract this type exists to state.** A fragmented-MP4 seek does not
/// land on the target. It lands on an ANCHOR at or before it — the enclosing
/// keyframe for video, the enclosing segment for audio — and those two anchors
/// are independent. Everything between the anchor and the target must still be
/// *decoded* (video reference state depends on it) and then *discarded*
/// (`outputMediaFloor`). So the only content that can launch playback at the
/// target is content that survives target-relative preroll:
///
/// > For target T, each required track must continue refilling until it holds
/// > usable data AFTER applying target-relative preroll. Pre-target queue depth
/// > must never satisfy launch readiness.
///
/// The bug this replaces asked the readiness question ONCE, after a refill whose
/// own stopping condition was packet-queue depth — a depth made entirely of
/// PRE-target samples. Preroll then threw all of it away and the seek aborted as
/// though MP4 demux had failed. Device capture 2026-08-26, target 169s, video
/// anchor 165.0, audio anchor 164.992: after the single refill
/// `dropV=26 dropA=140 pendingV=0 pcm=0` — 0.9s of a 4.0s video run-up and 3.0s
/// of a 4.0s audio run-up consumed, both short of the target. The same target
/// succeeded later at `dropV=117 dropA=187 pendingV=12 pcm≈4.9s`, i.e. once the
/// full run-up had actually been chewed. A 70s seek in the same capture shows
/// the asymmetry on its own: video anchor 70.000 (already target-ready, zero
/// drops) while the audio anchor was 65.026, so audio had 5s of run-up to
/// consume and stopped at `dropA=186 pcm=0`. Any rule that treats the two
/// tracks' anchors as equivalent keeps failing exactly there.
///
/// So readiness is a LOOP verdict, not a snapshot, and this type is that loop's
/// exit condition. It is deliberately free of Foundation-only-adjacent framework
/// types so the decision can be compiled and executed off-device (same rule as
/// `PlaybackHealth` / `ForegroundDecoderPolicy`).
///
/// **Why the bounds are what they are.** "Keep going until target-side content
/// exists" needs a floor that is not an attempt count — a fixed number of tries
/// is the same wrong answer as a fixed amount of supply, just later. The bounds
/// here all mean something:
/// - the demuxer reported EOF and the pass that saw it produced no new output,
/// - the pre-target run-up actually consumed exceeded a budget measured from the
///   OBSERVED anchors (a decoder that swallows the whole run-up and emits
///   nothing past the target is broken, not slow),
/// - the decode frontier stopped advancing across consecutive real demux pulls.
///
/// Each pass either advances a frontier (bounded by the run-up budget) or
/// increments the stall count (bounded by its limit), so the loop terminates.
enum SeekPrimingFailure: String, Sendable, Equatable, Hashable, CaseIterable {
    /// The demuxer is at end of stream and produced nothing at or past the
    /// target. A positioning/index truth, not a transport problem.
    case endOfStreamBeforeTarget
    /// More pre-target content was consumed than the observed anchors can
    /// justify, and still nothing survived preroll. The decoders are consuming
    /// the whole run-up and yielding nothing past the target.
    case prerollBudgetExhausted
    /// The decode frontier stopped advancing while bytes kept arriving: the
    /// input is fine and the pipeline is not turning it into output.
    case pipelineStalled
    /// The decode frontier stopped advancing and no new bytes arrived either.
    case inputStarved
}

/// What one priming pass measured. Every field is a POST-preroll or
/// progress-of-preroll quantity; there is deliberately no packet-queue depth
/// here, because queue depth is the input that made the old gate wrong.
struct SeekPrimingPass: Sendable, Equatable {
    /// Highest media position the VIDEO decoder has produced output for since
    /// the seek, whether that output was kept or discarded below the floor.
    /// `nil` = the video decoder has produced nothing at all yet.
    var videoDecodeFrontier: TimeInterval?
    /// The audio half, measured at the END of each decoded PCM chunk
    /// (`pts + duration`) because audio is trimmed at sample granularity, not
    /// frame granularity.
    var audioDecodeFrontier: TimeInterval?
    /// Monotonic session byte counter. Only used to tell "nothing is arriving"
    /// from "bytes arrive, the pipeline does not turn them into output".
    var bytesRead: Int64
    /// Decoded video frames banked ABOVE the floor (below-floor frames are
    /// dropped before they reach this queue, so this is already target-side).
    var postPrerollVideoFrames: Int
    /// PCM content seconds banked ABOVE the floor (below-floor PCM is dropped
    /// or trimmed on the way in, so this is already target-side).
    var postPrerollPCMContentSeconds: TimeInterval
    var videoDecoderOpened: Bool
    var audioDecoderOpened: Bool
    var demuxReachedEOF: Bool
    /// False when this pass could not pull from the demuxer because another
    /// filler owned it. Such a pass is not evidence about the demuxer and must
    /// not count toward the stalled-pull bound — it is bounded separately, by
    /// the accumulated wait below.
    var didAttemptDemuxPull: Bool
    /// Wall seconds this pass spent waiting for the demux fill gate.
    var demuxGateWaitSeconds: TimeInterval

    init(
        videoDecodeFrontier: TimeInterval? = nil,
        audioDecodeFrontier: TimeInterval? = nil,
        bytesRead: Int64 = 0,
        postPrerollVideoFrames: Int = 0,
        postPrerollPCMContentSeconds: TimeInterval = 0,
        videoDecoderOpened: Bool = true,
        audioDecoderOpened: Bool = true,
        demuxReachedEOF: Bool = false,
        didAttemptDemuxPull: Bool = true,
        demuxGateWaitSeconds: TimeInterval = 0
    ) {
        self.videoDecodeFrontier = videoDecodeFrontier
        self.audioDecodeFrontier = audioDecodeFrontier
        self.bytesRead = bytesRead
        self.postPrerollVideoFrames = postPrerollVideoFrames
        self.postPrerollPCMContentSeconds = postPrerollPCMContentSeconds
        self.videoDecoderOpened = videoDecoderOpened
        self.audioDecoderOpened = audioDecoderOpened
        self.demuxReachedEOF = demuxReachedEOF
        self.didAttemptDemuxPull = didAttemptDemuxPull
        self.demuxGateWaitSeconds = demuxGateWaitSeconds
    }
}

/// Fixed for the whole seek. `requiredPCMContentSeconds` is the audio
/// renderer's own seek-transition reserve — the gate must not invent a
/// different number, because the renderer refuses the transition below it.
struct SeekPrimingRequirements: Sendable, Equatable {
    /// Finite and >= 0, established by `init` — see the note there. Every bound
    /// in this file is measured against it, so a non-finite value would not
    /// weaken the bound, it would delete it.
    var target: TimeInterval
    /// A session with no audio track needs no audio to launch. A session WITH
    /// one whose decoder never opened is not "ready without audio" — it is a
    /// session that cannot launch, which is the pre-existing predicate and is
    /// preserved deliberately.
    var hasAudioTrack: Bool
    /// False while the video lane is locally suspended (audio-only background
    /// or PiP stop): that lane deliberately decodes nothing, so a video
    /// launch requirement could never be met. Video re-anchors to the current
    /// audio position when foreground preparation rebuilds the lane.
    var requiresVideo: Bool
    var requiredPCMContentSeconds: TimeInterval
    /// Head-room added to the measured anchor gap. A pass observes the anchor
    /// only AFTER it has already decoded a burst past it, so the measured gap
    /// under-reports the true run-up; the slack and the floor below absorb that.
    var prerollSlackSeconds: TimeInterval
    /// Floor for the run-up budget. DASH fragments are single-digit seconds, so
    /// a budget below this would be measurement noise rather than a bound.
    var minPrerollBudgetSeconds: TimeInterval
    /// Ceiling for the run-up budget. Past this the anchor is not a fragment
    /// boundary, it is a broken index.
    var maxPrerollBudgetSeconds: TimeInterval
    /// Consecutive REAL demux pulls that produced no frontier movement.
    var stalledPullLimit: Int
    /// Total wall seconds this seek may spend waiting for another filler to
    /// release the demuxer. Bounds a wait on a local re-entrancy gate, not a
    /// wait on content — the only reason a wall clock appears in this type.
    var maxDemuxGateWaitSeconds: TimeInterval

    init(
        target: TimeInterval,
        hasAudioTrack: Bool,
        requiresVideo: Bool = true,
        requiredPCMContentSeconds: TimeInterval,
        prerollSlackSeconds: TimeInterval = 4,
        minPrerollBudgetSeconds: TimeInterval = 8,
        maxPrerollBudgetSeconds: TimeInterval = 60,
        stalledPullLimit: Int = 4,
        maxDemuxGateWaitSeconds: TimeInterval = 3
    ) {
        // Sanitized like every sibling field below, and for a stronger reason
        // than symmetry: the run-up budget is the ONLY bound that stops a loop
        // whose frontier keeps advancing, and it is measured as
        // `target - anchor`. A non-finite target made `recomputeRunUp` bail
        // before assigning `prerollBudgetSeconds`, which left it 0, which made
        // the `prerollBudgetSeconds > 0` test skip the bound — so a pass that
        // advanced a frontier by any amount reset the stall count and the loop
        // ran without limit. Executed off-device: 2,000,000 passes, no verdict.
        // The only producer (`MediaEngineSession.outputMediaFloor`) already
        // guarantees a finite value, so this changes nothing reachable today;
        // it makes the type's stated termination guarantee TOTAL instead of
        // conditional on a caller nobody enforces, which is the whole reason
        // this decision lives in a pure type that can be run off-device.
        self.target = target.isFinite ? max(0, target) : 0
        self.hasAudioTrack = hasAudioTrack
        self.requiresVideo = requiresVideo
        self.requiredPCMContentSeconds = requiredPCMContentSeconds
        self.prerollSlackSeconds = max(0, prerollSlackSeconds)
        self.minPrerollBudgetSeconds = max(0, minPrerollBudgetSeconds)
        self.maxPrerollBudgetSeconds = max(
            self.minPrerollBudgetSeconds,
            maxPrerollBudgetSeconds
        )
        self.stalledPullLimit = max(1, stalledPullLimit)
        self.maxDemuxGateWaitSeconds = max(0, maxDemuxGateWaitSeconds)
    }
}

enum SeekPrimingVerdict: Sendable, Equatable {
    /// Both required tracks hold post-preroll content. Commit.
    case launchReady
    /// Neither ready nor broken. Run another pass.
    case continuePriming
    /// A newer seek (or a lifecycle teardown) owns the transaction. Settle as
    /// handed-off, NEVER as an error.
    case superseded
    case failed(SeekPrimingFailure)
}

/// The loop's accumulating state and its exit condition.
///
/// `evaluate` is the only mutating entry point and must be called exactly once
/// per pass, because the stall and run-up accounting are per-pass deltas.
struct SeekPrimingGate: Sendable, Equatable {
    /// Frontier movement below this is float noise, not progress. Deliberately
    /// coarser than the codebase's usual `1e-9` comparison epsilon: crediting
    /// a nanosecond of PTS drift as forward progress would defeat the stall
    /// bound entirely.
    static let frontierAdvanceEpsilon: TimeInterval = 1e-6

    let requirements: SeekPrimingRequirements

    private(set) var passCount = 0
    private(set) var stalledPulls = 0
    private(set) var demuxGateWaitSeconds: TimeInterval = 0
    /// First observed frontier per track — the closest this gate can get to the
    /// demuxer's anchor without the demuxer reporting it.
    private(set) var videoAnchorFrontier: TimeInterval?
    private(set) var audioAnchorFrontier: TimeInterval?
    private(set) var videoFrontier: TimeInterval?
    private(set) var audioFrontier: TimeInterval?
    private(set) var observedBytesRead: Int64 = 0
    private(set) var consumedPrerollSeconds: TimeInterval = 0
    private(set) var prerollBudgetSeconds: TimeInterval = 0
    private(set) var videoLaunchReady = false
    private(set) var audioLaunchReady = false
    private(set) var failure: SeekPrimingFailure?

    init(requirements: SeekPrimingRequirements) {
        self.requirements = requirements
    }

    /// Video launch readiness, evaluated on POST-preroll frames only. Matches
    /// the session's pre-existing `launchReadiness.video` predicate exactly —
    /// what changed is when it is asked, not what it asks.
    func videoIsLaunchReady(_ pass: SeekPrimingPass) -> Bool {
        guard requirements.requiresVideo else { return true }
        return pass.videoDecoderOpened && pass.postPrerollVideoFrames > 0
    }

    /// Audio launch readiness, evaluated on POST-preroll PCM only.
    func audioIsLaunchReady(_ pass: SeekPrimingPass) -> Bool {
        guard requirements.hasAudioTrack else { return true }
        guard pass.audioDecoderOpened else { return false }
        return pass.postPrerollPCMContentSeconds + 1e-9
            >= requirements.requiredPCMContentSeconds
    }

    mutating func evaluate(
        _ pass: SeekPrimingPass,
        isSuperseded: Bool
    ) -> SeekPrimingVerdict {
        // Supersession outranks readiness. Old-generation data must never
        // satisfy a new target, and a superseded transaction settles as
        // handed-off — it is not this seek's failure and must not reach the
        // recovery ladder.
        if isSuperseded { return .superseded }

        passCount += 1
        demuxGateWaitSeconds += max(0, sanitized(pass.demuxGateWaitSeconds) ?? 0)

        let videoReady = videoIsLaunchReady(pass)
        let audioReady = audioIsLaunchReady(pass)
        videoLaunchReady = videoReady
        audioLaunchReady = audioReady

        let observedVideo = sanitized(pass.videoDecodeFrontier)
        let observedAudio = sanitized(pass.audioDecodeFrontier)
        let videoAdvanced = advanced(from: videoFrontier, to: observedVideo)
        let audioAdvanced = advanced(from: audioFrontier, to: observedAudio)
        if videoAnchorFrontier == nil { videoAnchorFrontier = observedVideo }
        if audioAnchorFrontier == nil { audioAnchorFrontier = observedAudio }
        videoFrontier = later(videoFrontier, observedVideo)
        audioFrontier = later(audioFrontier, observedAudio)
        let bytesAdvanced = pass.bytesRead > observedBytesRead
        observedBytesRead = max(observedBytesRead, pass.bytesRead)

        recomputeRunUp(videoReady: videoReady, audioReady: audioReady)

        if videoReady, audioReady {
            failure = nil
            return .launchReady
        }

        // Progress is credited ONLY for a track that still owes content. A
        // track that reached the target stops decoding once its frame queue is
        // full, so its frozen frontier is success, not a stall — crediting it
        // would also mask the other track's stall (the 70s fixture: video ready
        // at the target, audio five seconds behind it).
        var advancedTowardTarget = false
        if !videoReady, videoAdvanced { advancedTowardTarget = true }
        if requirements.hasAudioTrack, !audioReady, audioAdvanced {
            advancedTowardTarget = true
        }

        // EOF alone is not terminal: the pass that first sees it may still have
        // produced the samples that satisfy the gate, and residual packets are
        // decoded after the demuxer is done. EOF plus a pass that produced
        // nothing new is the real end of the road.
        if pass.demuxReachedEOF, !advancedTowardTarget {
            return fail(.endOfStreamBeforeTarget)
        }

        if prerollBudgetSeconds > 0,
           consumedPrerollSeconds > prerollBudgetSeconds + Self.frontierAdvanceEpsilon {
            return fail(.prerollBudgetExhausted)
        }

        if !pass.didAttemptDemuxPull, !advancedTowardTarget {
            // No pull happened, so there is no evidence about the demuxer.
            // Wait (bounded) rather than spending a stalled pull on a local
            // re-entrancy gate.
            guard demuxGateWaitSeconds
                    >= requirements.maxDemuxGateWaitSeconds - Self.frontierAdvanceEpsilon
            else {
                return .continuePriming
            }
            return fail(bytesAdvanced ? .pipelineStalled : .inputStarved)
        }

        if advancedTowardTarget {
            stalledPulls = 0
            return .continuePriming
        }

        stalledPulls += 1
        guard stalledPulls >= requirements.stalledPullLimit else {
            return .continuePriming
        }
        return fail(bytesAdvanced ? .pipelineStalled : .inputStarved)
    }

    /// Bounded, log-safe summary. The numbers here are the ones a device report
    /// has to answer "was this positioning or priming?" with.
    var diagnosticSummary: String {
        func time(_ value: TimeInterval?) -> String {
            guard let value, value.isFinite else { return "none" }
            return String(format: "%.3f", value)
        }
        return "passes=\(passCount) vFrontier=\(time(videoFrontier)) " +
            "aFrontier=\(time(audioFrontier)) vAnchor=\(time(videoAnchorFrontier)) " +
            "aAnchor=\(time(audioAnchorFrontier)) " +
            "runUp=\(String(format: "%.2f", consumedPrerollSeconds)) " +
            "budget=\(String(format: "%.2f", prerollBudgetSeconds)) " +
            "stalled=\(stalledPulls) gateWait=" +
            String(format: "%.2f", demuxGateWaitSeconds)
    }

    // MARK: - Private

    /// The run-up budget is measured from the anchors of the tracks that still
    /// owe content, never from a track that already reached the target — a
    /// video track that raced 20s ahead must not spend the audio track's
    /// budget.
    private mutating func recomputeRunUp(videoReady: Bool, audioReady: Bool) {
        var earliestAnchor: TimeInterval?
        var consumed: TimeInterval = 0
        if !videoReady, let anchor = videoAnchorFrontier {
            earliestAnchor = min(earliestAnchor ?? anchor, anchor)
            if let frontier = videoFrontier {
                consumed = max(consumed, frontier - anchor)
            }
        }
        if requirements.hasAudioTrack, !audioReady, let anchor = audioAnchorFrontier {
            earliestAnchor = min(earliestAnchor ?? anchor, anchor)
            if let frontier = audioFrontier {
                consumed = max(consumed, frontier - anchor)
            }
        }
        // No track still owes content (or none has produced output yet): keep
        // the previous values rather than zeroing them. The bound is only ever
        // read while a track is short, and the retained numbers are what the
        // `[PathA]` diagnostic needs to say how much run-up this seek actually
        // had to chew — zeroing them on the winning pass erased exactly the
        // measurement the device report is read for.
        // No `target.isFinite` clause: `init` establishes that, so a guard here
        // could only ever hide a broken initializer by silently disabling the
        // bound — which is exactly what it used to do.
        guard let anchor = earliestAnchor else {
            return
        }
        consumedPrerollSeconds = max(0, consumed)
        let gap = max(0, requirements.target - anchor)
        prerollBudgetSeconds = min(
            max(gap + requirements.prerollSlackSeconds, requirements.minPrerollBudgetSeconds),
            requirements.maxPrerollBudgetSeconds
        )
    }

    private mutating func fail(_ reason: SeekPrimingFailure) -> SeekPrimingVerdict {
        failure = reason
        return .failed(reason)
    }

    private func sanitized(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private func advanced(from previous: TimeInterval?, to observed: TimeInterval?) -> Bool {
        guard let observed else { return false }
        guard let previous else { return true }
        return observed > previous + Self.frontierAdvanceEpsilon
    }

    private func later(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case let (value?, nil): return value
        case let (nil, value?): return value
        case let (left?, right?): return max(left, right)
        }
    }
}
