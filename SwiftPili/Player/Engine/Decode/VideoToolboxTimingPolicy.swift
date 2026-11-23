import Foundation

enum VideoToolboxTimingInputOrder: String, Equatable, Sendable {
    case decodeOrder
    case presentationOrder
    case unknown
}

struct VideoToolboxTimingIdentity: Equatable, Hashable, Sendable {
    let submissionID: UInt64
    let decoderGeneration: UInt64

    init(submissionID: UInt64, decoderGeneration: UInt64) {
        self.submissionID = submissionID
        self.decoderGeneration = decoderGeneration
    }
}

struct VideoToolboxTimingSubmission: Equatable, Sendable {
    let identity: VideoToolboxTimingIdentity
    let inputPTS: TimeInterval?
    let inputDTS: TimeInterval?
    let inputDuration: TimeInterval?
    let inputOrder: VideoToolboxTimingInputOrder

    init(
        identity: VideoToolboxTimingIdentity,
        inputPTS: TimeInterval?,
        inputDTS: TimeInterval?,
        inputDuration: TimeInterval?,
        inputOrder: VideoToolboxTimingInputOrder
    ) {
        self.identity = identity
        self.inputPTS = inputPTS
        self.inputDTS = inputDTS
        self.inputDuration = inputDuration
        self.inputOrder = inputOrder
    }

    init(
        submissionID: UInt64,
        decoderGeneration: UInt64,
        inputPTS: TimeInterval?,
        inputDTS: TimeInterval?,
        inputDuration: TimeInterval?,
        inputOrder: VideoToolboxTimingInputOrder
    ) {
        self.init(
            identity: VideoToolboxTimingIdentity(
                submissionID: submissionID,
                decoderGeneration: decoderGeneration
            ),
            inputPTS: inputPTS,
            inputDTS: inputDTS,
            inputDuration: inputDuration,
            inputOrder: inputOrder
        )
    }
}

struct VideoToolboxSampleTiming: Equatable, Sendable {
    let duration: TimeInterval?
    let presentationTimeStamp: TimeInterval?
    let decodeTimeStamp: TimeInterval?
}

struct VideoToolboxTimingOutputEvent: Equatable, Sendable {
    let identity: VideoToolboxTimingIdentity
    let callbackIndex: Int
    let status: Int32
    let imagePresent: Bool
    let callbackPTS: TimeInterval?
    let callbackDuration: TimeInterval?
    let infoFlags: UInt32

    init(
        identity: VideoToolboxTimingIdentity,
        callbackIndex: Int,
        status: Int32 = 0,
        imagePresent: Bool,
        callbackPTS: TimeInterval?,
        callbackDuration: TimeInterval?,
        infoFlags: UInt32 = 0
    ) {
        self.identity = identity
        self.callbackIndex = callbackIndex
        self.status = status
        self.imagePresent = imagePresent
        self.callbackPTS = callbackPTS
        self.callbackDuration = callbackDuration
        self.infoFlags = infoFlags
    }

    init(
        submissionID: UInt64,
        decoderGeneration: UInt64,
        callbackIndex: Int,
        status: Int32 = 0,
        imagePresent: Bool,
        callbackPTS: TimeInterval?,
        callbackDuration: TimeInterval?,
        infoFlags: UInt32 = 0
    ) {
        self.init(
            identity: VideoToolboxTimingIdentity(
                submissionID: submissionID,
                decoderGeneration: decoderGeneration
            ),
            callbackIndex: callbackIndex,
            status: status,
            imagePresent: imagePresent,
            callbackPTS: callbackPTS,
            callbackDuration: callbackDuration,
            infoFlags: infoFlags
        )
    }
}

struct VideoToolboxTimingOutputCollector: Equatable, Sendable {
    private(set) var events: [VideoToolboxTimingOutputEvent] = []
    private(set) var firstFailureStatus: Int32?

    init() {}

    @discardableResult
    mutating func append(
        identity: VideoToolboxTimingIdentity,
        status: Int32,
        imagePresent: Bool,
        callbackPTS: TimeInterval?,
        callbackDuration: TimeInterval?,
        infoFlags: UInt32
    ) -> VideoToolboxTimingOutputEvent {
        if firstFailureStatus == nil, status != VideoToolboxTimingPolicy.callbackSuccessStatus {
            firstFailureStatus = status
        }
        let event = VideoToolboxTimingOutputEvent(
            identity: identity,
            callbackIndex: events.count,
            status: status,
            imagePresent: imagePresent,
            callbackPTS: callbackPTS,
            callbackDuration: callbackDuration,
            infoFlags: infoFlags
        )
        events.append(event)
        return event
    }
}

struct VideoToolboxTimingMissingFields: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let callbackPTS = Self(rawValue: 1 << 0)
    static let callbackDuration = Self(rawValue: 1 << 1)
}

enum VideoToolboxTimingUnknownReason: String, Equatable, Sendable {
    case staleIdentity
    case callbackFailure
    case noImage
    case missingCallbackPTS
    case missingCallbackDuration
    case missingCallbackPTSandDuration
    case ambiguousOutputTiming
    case invalidCallbackIndex
}

enum VideoToolboxTimingResolution: Equatable, Sendable {
    case callback(pts: TimeInterval, duration: TimeInterval)
    case oneToOneInputFallback(
        pts: TimeInterval,
        duration: TimeInterval,
        missing: VideoToolboxTimingMissingFields
    )
    case unknown(VideoToolboxTimingUnknownReason)
}

struct VideoToolboxTimingOutputResolution: Equatable, Sendable {
    let event: VideoToolboxTimingOutputEvent
    let resolution: VideoToolboxTimingResolution
}

enum VideoToolboxTimingBatchOutcome: Equatable, Sendable {
    case noOutput
    case outputs([VideoToolboxTimingOutputResolution])
}

struct VideoToolboxTimingBatchResolution: Equatable, Sendable {
    let identity: VideoToolboxTimingIdentity
    let outcome: VideoToolboxTimingBatchOutcome
    let firstFailureStatus: Int32?

    var outputResolutions: [VideoToolboxTimingOutputResolution] {
        switch outcome {
        case .noOutput:
            return []
        case .outputs(let outputs):
            return outputs
        }
    }

    func resolution(
        for event: VideoToolboxTimingOutputEvent
    ) -> VideoToolboxTimingResolution? {
        guard firstFailureStatus == nil else { return nil }
        return outputResolutions.first {
            $0.event == event
        }?.resolution
    }
}

struct VideoToolboxTimingPolicy: Sendable {
    static let callbackSuccessStatus: Int32 = 0

    init() {}

    func sampleTiming(for submission: VideoToolboxTimingSubmission) -> VideoToolboxSampleTiming {
        let presentationTimeStamp = Self.validTimestamp(submission.inputPTS)
        let duration = Self.validDuration(submission.inputDuration)
        let decodeTimeStamp: TimeInterval?
        switch submission.inputOrder {
        case .decodeOrder:
            decodeTimeStamp = Self.validTimestamp(submission.inputDTS)
        case .presentationOrder, .unknown:
            decodeTimeStamp = nil
        }
        return VideoToolboxSampleTiming(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp
        )
    }

    func resolve(
        submission: VideoToolboxTimingSubmission,
        outputEvents: [VideoToolboxTimingOutputEvent]
    ) -> VideoToolboxTimingBatchResolution {
        guard !outputEvents.isEmpty else {
            return VideoToolboxTimingBatchResolution(
                identity: submission.identity,
                outcome: .noOutput,
                firstFailureStatus: nil
            )
        }

        var firstFailureStatus: Int32?
        var resolutions: [VideoToolboxTimingOutputResolution] = []
        resolutions.reserveCapacity(outputEvents.count)
        let imageOutputCount = outputEvents.reduce(into: 0) { count, event in
            if event.status == Self.callbackSuccessStatus && event.imagePresent {
                count += 1
            }
        }
        let allowsOneToOneFallback = imageOutputCount == 1
        let expectedCallbackIndices = Set(outputEvents.indices)
        let observedCallbackIndices = Set(outputEvents.map(\.callbackIndex))
        let callbackIndicesAreValid = observedCallbackIndices == expectedCallbackIndices

        for event in outputEvents {
            if event.identity != submission.identity {
                resolutions.append(VideoToolboxTimingOutputResolution(
                    event: event,
                    resolution: .unknown(.staleIdentity)
                ))
                continue
            }

            if event.status != Self.callbackSuccessStatus {
                if firstFailureStatus == nil {
                    firstFailureStatus = event.status
                }
                resolutions.append(VideoToolboxTimingOutputResolution(
                    event: event,
                    resolution: .unknown(.callbackFailure)
                ))
                continue
            }

            guard callbackIndicesAreValid else {
                resolutions.append(VideoToolboxTimingOutputResolution(
                    event: event,
                    resolution: .unknown(.invalidCallbackIndex)
                ))
                continue
            }

            guard event.imagePresent else {
                resolutions.append(VideoToolboxTimingOutputResolution(
                    event: event,
                    resolution: .unknown(.noImage)
                ))
                continue
            }

            let callbackPTS = Self.validTimestamp(event.callbackPTS)
            let callbackDuration = Self.validDuration(event.callbackDuration)
            if let callbackPTS, let callbackDuration {
                resolutions.append(VideoToolboxTimingOutputResolution(
                    event: event,
                    resolution: .callback(
                        pts: callbackPTS,
                        duration: callbackDuration
                    )
                ))
                continue
            }

            if let callbackPTS,
               !allowsOneToOneFallback,
               let inputDuration = Self.validDuration(submission.inputDuration) {
                resolutions.append(VideoToolboxTimingOutputResolution(
                    event: event,
                    resolution: .oneToOneInputFallback(
                        pts: callbackPTS,
                        duration: inputDuration / Double(max(1, imageOutputCount)),
                        missing: .callbackDuration
                    )
                ))
                continue
            }

            guard allowsOneToOneFallback else {
                resolutions.append(VideoToolboxTimingOutputResolution(
                    event: event,
                    resolution: .unknown(.ambiguousOutputTiming)
                ))
                continue
            }

            let inputPTS = Self.validTimestamp(submission.inputPTS)
            let inputDuration = Self.validDuration(submission.inputDuration)
            var missing = VideoToolboxTimingMissingFields()
            let resolvedPTS: TimeInterval?
            if let callbackPTS {
                resolvedPTS = callbackPTS
            } else if let inputPTS {
                resolvedPTS = inputPTS
                missing.insert(.callbackPTS)
            } else {
                resolvedPTS = nil
                missing.insert(.callbackPTS)
            }

            let resolvedDuration: TimeInterval?
            if let callbackDuration {
                resolvedDuration = callbackDuration
            } else if let inputDuration {
                resolvedDuration = inputDuration
                missing.insert(.callbackDuration)
            } else {
                resolvedDuration = nil
                missing.insert(.callbackDuration)
            }

            guard let resolvedPTS, let resolvedDuration else {
                let reason: VideoToolboxTimingUnknownReason
                if resolvedPTS == nil, resolvedDuration == nil {
                    reason = .missingCallbackPTSandDuration
                } else if resolvedPTS == nil {
                    reason = .missingCallbackPTS
                } else {
                    reason = .missingCallbackDuration
                }
                resolutions.append(VideoToolboxTimingOutputResolution(
                    event: event,
                    resolution: .unknown(reason)
                ))
                continue
            }

            resolutions.append(VideoToolboxTimingOutputResolution(
                event: event,
                resolution: .oneToOneInputFallback(
                    pts: resolvedPTS,
                    duration: resolvedDuration,
                    missing: missing
                )
            ))
        }

        return VideoToolboxTimingBatchResolution(
            identity: submission.identity,
            outcome: .outputs(resolutions),
            firstFailureStatus: firstFailureStatus
        )
    }

    static func validTimestamp(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
