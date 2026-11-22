import Foundation

enum SeekPrimingFailure: String, Sendable, Equatable, Hashable, CaseIterable {
    case endOfStreamBeforeTarget
    case prerollBudgetExhausted
    case pipelineStalled
    case inputStarved
}

struct SeekPrimingPass: Sendable, Equatable {
    var videoDecodeFrontier: TimeInterval?
    var audioDecodeFrontier: TimeInterval?
    var bytesRead: Int64
    var postPrerollVideoFrames: Int
    var postPrerollPCMContentSeconds: TimeInterval
    var videoDecoderOpened: Bool
    var audioDecoderOpened: Bool
    var demuxReachedEOF: Bool
    var didAttemptDemuxPull: Bool
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

struct SeekPrimingRequirements: Sendable, Equatable {
    var target: TimeInterval
    var hasAudioTrack: Bool
    var requiresVideo: Bool
    var requiredPCMContentSeconds: TimeInterval
    var prerollSlackSeconds: TimeInterval
    var minPrerollBudgetSeconds: TimeInterval
    var maxPrerollBudgetSeconds: TimeInterval
    var stalledPullLimit: Int
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
    case launchReady
    case continuePriming
    case superseded
    case failed(SeekPrimingFailure)
}

struct SeekPrimingGate: Sendable, Equatable {
    static let frontierAdvanceEpsilon: TimeInterval = 1e-6

    let requirements: SeekPrimingRequirements

    private(set) var passCount = 0
    private(set) var stalledPulls = 0
    private(set) var demuxGateWaitSeconds: TimeInterval = 0
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

    func videoIsLaunchReady(_ pass: SeekPrimingPass) -> Bool {
        guard requirements.requiresVideo else { return true }
        return pass.videoDecoderOpened && pass.postPrerollVideoFrames > 0
    }

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

        var advancedTowardTarget = false
        if !videoReady, videoAdvanced { advancedTowardTarget = true }
        if requirements.hasAudioTrack, !audioReady, audioAdvanced {
            advancedTowardTarget = true
        }

        if pass.demuxReachedEOF, !advancedTowardTarget {
            return fail(.endOfStreamBeforeTarget)
        }

        if prerollBudgetSeconds > 0,
           consumedPrerollSeconds > prerollBudgetSeconds + Self.frontierAdvanceEpsilon {
            return fail(.prerollBudgetExhausted)
        }

        if !pass.didAttemptDemuxPull, !advancedTowardTarget {
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
