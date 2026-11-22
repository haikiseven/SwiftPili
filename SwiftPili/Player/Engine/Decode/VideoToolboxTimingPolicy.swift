import Foundation

/// The order in which compressed samples are submitted to VideoToolbox.
///
/// VideoToolbox expects decode-order input when a decoder timestamp is known.
/// A presentation-order stream must explicitly opt out of DTS; an unknown
/// order is treated the same as unavailable decode timing and never gets a
/// synthesized DTS.
enum VideoToolboxTimingInputOrder: String, Equatable, Sendable {
    case decodeOrder
    case presentationOrder
    case unknown
}

/// Identity shared by a compressed submission and every callback associated
/// with it. The native decoder generation is deliberately separate from the
/// submission sequence: replacing a decoder invalidates all of its delayed
/// callbacks even when a sequence number is reused by the successor.
struct VideoToolboxTimingIdentity: Equatable, Hashable, Sendable {
    let submissionID: UInt64
    let decoderGeneration: UInt64

    init(submissionID: UInt64, decoderGeneration: UInt64) {
        self.submissionID = submissionID
        self.decoderGeneration = decoderGeneration
    }
}

/// Scalar timing facts carried into one VideoToolbox decode submission.
///
/// This type intentionally has no Core Media dependency. The native adapter
/// maps the returned `VideoToolboxSampleTiming` to `CMSampleTimingInfo`, while
/// tests can exercise signed timing and identity fencing on every platform.
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

/// Timing values the native adapter should put in a CMSampleTimingInfo entry.
/// A nil value maps to `CMTime.invalid`; no timestamp or duration is invented
/// when the demuxer did not provide a finite value.
struct VideoToolboxSampleTiming: Equatable, Sendable {
    let duration: TimeInterval?
    let presentationTimeStamp: TimeInterval?
    let decodeTimeStamp: TimeInterval?
}

/// One scalar observation from one VideoToolbox output callback.
///
/// `imagePresent` is deliberately separate from timing. A callback with no
/// image is an observed decoder event, not a displayable frame.
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

/// Unconditionally collects every callback from one synchronous VT submission.
///
/// This collector deliberately has no audit switch. The audit may be disabled
/// (and normally is), but timing correctness still needs the complete callback
/// stream and the first failure status. Keeping this as a value type also gives
/// the Foundation-only seam a direct mutation-sensitive test surface.
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

/// Which callback timing fields had to be supplied by the one-to-one input
/// fallback. This is evidence, not a reason to broaden fallback to N outputs.
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

/// Resolution for one callback that owns one possible image.
///
/// Only the two resolved cases may be converted into `MediaVideoFrame`.
/// Unknown timing remains typed and withheld from the presentation pipeline.
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

/// Result of resolving every callback observed for one submission.
///
/// `firstFailureStatus` is independent of output ordering. It preserves the
/// first non-zero callback status even when a later callback supplies an image.
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

    /// Look up a resolution by the callback's explicit identity, not by the
    /// position of either array. A callback list can be reordered by a future
    /// adapter or test while the native image record keeps its own index.
    func resolution(
        for event: VideoToolboxTimingOutputEvent
    ) -> VideoToolboxTimingResolution? {
        guard firstFailureStatus == nil else { return nil }
        return outputResolutions.first {
            $0.event == event
        }?.resolution
    }
}

/// Pure timing authority at the VideoToolbox boundary.
///
/// This policy deliberately knows nothing about codecs, recovery, clocks,
/// renderers, or HEVC audit state. It only preserves input timing, resolves
/// each callback independently, and fails closed when callback identity or
/// timing is ambiguous.
struct VideoToolboxTimingPolicy: Sendable {
    static let callbackSuccessStatus: Int32 = 0

    init() {}

    /// Returns the exact finite timing values that the native adapter may put
    /// into `CMSampleTimingInfo`. Negative PTS/DTS are valid and preserved.
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

    /// Resolves all output callbacks belonging to `submission`.
    ///
    /// Input timing can be used only when exactly one callback was observed.
    /// Therefore a missing callback PTS/duration in a multi-output burst is
    /// always unknown, even if the submitted packet has complete timing.
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
        let allowsOneToOneFallback = outputEvents.count == 1
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

    /// A timestamp is valid when it is finite. Signed media timelines are
    /// expected, so negative values are intentionally accepted.
    static func validTimestamp(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// A frame duration must be finite and strictly positive. Zero, negative,
    /// NaN, and infinity are unresolved rather than silently changed to a
    /// made-up quantum.
    static func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
