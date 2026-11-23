import Foundation

@MainActor
public final class PlaybackSession {
    private enum SnapshotChange<Value> {
        case keep
        case set(Value?)
    }

    private enum Command {
        case open(PlaybackSource)
        case play
        case pause
        case seek(TimeInterval, mode: PlaybackSeekMode)
        case setRate(Float)
        case stop(PlaybackStopReason)
        case requestPictureInPicture(PlaybackPictureInPictureRequest)
        case close
    }

    private struct PendingSeek {
        let operation: PlaybackOperationID
        let target: TimeInterval
        let source: PlaybackSource
        let identities: PlaybackIdentityContext
        let continuation: CheckedContinuation<PlaybackCommandResult, Never>
    }

    private struct PendingOpen {
        let operation: PlaybackOperationID
        let source: PlaybackSource
        let identities: PlaybackIdentityContext
        let continuation: CheckedContinuation<PlaybackRuntimeDecision, Never>
    }

    private let configuration: PlaybackConfiguration
    private let runtime: any PlaybackRuntime
    private let clock: any PlaybackMonotonicClock
    private let sessionID: PlaybackSessionID
    private let eventStream: AsyncStream<PlaybackEventEnvelope>
    private var eventContinuation: AsyncStream<PlaybackEventEnvelope>.Continuation
    private let defaultSurface: PlaybackSurface

    private var currentSource: PlaybackSource?
    private var currentSnapshot: PlaybackSnapshot
    private var pendingOpen: PendingOpen?
    private var pendingSeek: PendingSeek?
    private var openTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var runtimeEventTask: Task<Void, Never>?
    private var isClosed = false
    private var isClosing = false

    private var operationSerial: UInt64 = 0
    private var environmentSerial: UInt64 = 0
    private var lastIssuedOperation: PlaybackOperationID?
    private var eventSequence: UInt64 = 0
    private var lastMonotonicOffset: Duration = .zero
    private var journalSequence: UInt64 = 0
    private var journalDroppedCount: UInt64 = 0
    private var journal: [PlaybackDecisionRecord] = []
    private var latestEnvironmentSerials: [PlaybackEnvironmentEventKind: UInt64] = [:]
    private var highestApplicationEpochSeen: UInt64?

    public convenience init(configuration: PlaybackConfiguration = .init()) {
        self.init(
            configuration: configuration,
            runtime: UnavailablePlaybackRuntime(),
            clock: SystemPlaybackMonotonicClock()
        )
    }

    public init(
        configuration: PlaybackConfiguration = .init(),
        runtime: any PlaybackRuntime,
        clock: any PlaybackMonotonicClock = SystemPlaybackMonotonicClock()
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.clock = clock
        self.sessionID = PlaybackSessionID(rawValue: "session-\(UUID().uuidString)")
        self.defaultSurface = PlaybackSurface(
            id: PlaybackSurfaceID(rawValue: "surface-\(UUID().uuidString)"),
            kind: .unavailable,
            isAvailable: false
        )
        var continuation: AsyncStream<PlaybackEventEnvelope>.Continuation!
        let eventStream = AsyncStream<PlaybackEventEnvelope> { continuation = $0 }
        self.eventStream = eventStream
        self.eventContinuation = continuation
        self.currentSnapshot = PlaybackSnapshot(
            session: self.sessionID,
            rate: Self.validatedRate(configuration.preferredRate)
        )
        let runtimeEvents = runtime.runtimeEvents
        self.runtimeEventTask = Task { @MainActor [weak self] in
            for await event in runtimeEvents {
                guard !Task.isCancelled else { break }
                await self?.handleRuntimeEvent(event)
            }
        }
    }

    private static func validatedRate(_ rate: Float) -> Float {
        rate.isFinite && rate > 0 && rate <= 8 ? rate : 1
    }

    deinit {
        runtimeEventTask?.cancel()
        openTask?.cancel()
        if let pendingOpen {
            pendingOpen.continuation.resume(returning: .unavailable)
        }
        seekTask?.cancel()
        if let pendingSeek {
            pendingSeek.continuation.resume(
                returning: .failed(
                    operation: pendingSeek.operation,
                    failure: .closed
                )
            )
        }
        eventContinuation.finish()
    }

    public var snapshot: PlaybackSnapshot {
        currentSnapshot
    }

    public var events: AsyncStream<PlaybackEventEnvelope> {
        eventStream
    }

    public var surface: PlaybackSurface {
        currentSnapshot.presentation.surface ?? defaultSurface
    }

    public func decisionJournal() -> PlaybackDecisionJournalSnapshot {
        PlaybackDecisionJournalSnapshot(
            records: journal,
            droppedCount: journalDroppedCount,
            firstRetainedSequence: journal.first?.sequence,
            lastRetainedSequence: journal.last?.sequence
        )
    }

    public func open(_ source: PlaybackSource) async -> PlaybackCommandResult {
        await dispatch(.open(source))
    }

    public func play() async -> PlaybackCommandResult {
        await dispatch(.play)
    }

    public func pause() async -> PlaybackCommandResult {
        await dispatch(.pause)
    }

    public func seek(
        to time: TimeInterval,
        mode: PlaybackSeekMode = .accurate
    ) async -> PlaybackCommandResult {
        await dispatch(.seek(time, mode: mode))
    }

    public func setRate(_ rate: Float) async -> PlaybackCommandResult {
        await dispatch(.setRate(rate))
    }

    public func stop(reason: PlaybackStopReason) async -> PlaybackCommandResult {
        await dispatch(.stop(reason))
    }

    public func requestPictureInPicture(
        _ request: PlaybackPictureInPictureRequest
    ) async -> PlaybackCommandResult {
        await dispatch(.requestPictureInPicture(request))
    }

    public func handle(_ event: PlaybackEnvironmentEvent) async -> PlaybackEnvironmentResult {
        let (eventID, serial) = nextEnvironmentEventID(for: event)
        return await dispatchEnvironment(event, eventID: eventID, serial: serial)
    }

    public func close() async -> PlaybackCommandResult {
        await dispatch(.close)
    }

    // MARK: - One command dispatcher

    private func dispatch(_ command: Command) async -> PlaybackCommandResult {
        switch command {
        case let .open(source):
            return await dispatchOpen(source)
        case .play:
            return await dispatchPlay()
        case .pause:
            return await dispatchPause()
        case let .seek(time, mode):
            return await dispatchSeek(time, mode: mode)
        case let .setRate(rate):
            return await dispatchSetRate(rate)
        case let .stop(reason):
            return await dispatchStop(reason)
        case let .requestPictureInPicture(request):
            return await dispatchPictureInPicture(request)
        case .close:
            return await dispatchClose()
        }
    }

    private func dispatchOpen(_ source: PlaybackSource) async -> PlaybackCommandResult {
        let operation = nextOperation()
        guard !isClosed && !isClosing else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .closed),
                command: .open,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .closed,
                before: currentSnapshot.transport
            )
        }
        guard isValid(source: source) else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .invalidSource),
                command: .open,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .invalidSource,
                before: currentSnapshot.transport
            )
        }

        await supersedePendingSeek(by: operation)
        let before = currentSnapshot
        let identities = PlaybackIdentityContext(
            ownerLease: currentSnapshot.identities.ownerLease,
            lifecycleEpoch: currentSnapshot.identities.lifecycleEpoch
        )
        updateSnapshot(
            source: .set(source),
            identities: .set(identities),
            intent: .set(.stopped),
            transport: .set(.opening),
            suppression: .set(nil),
            audio: .set(.priming),
            video: .set(.priming),
            presentation: .set(.init()),
            operation: .set(operation),
            mediaTime: .set(source.startPosition),
            capabilities: .set([])
        )
        await supersedePendingOpen(by: operation)
        await publishSnapshotChanges(
            from: before,
            operation: operation,
            sourceOverride: source
        )

        let decision = await awaitOpenDecision(
            operation: operation,
            source: source,
            identities: identities
        )
        guard isCurrent(operation: operation, source: source, identities: identities) else {
            let result = staleOrSupersededResult(
                for: operation,
                source: source,
                identities: identities
            )
            return await finishStaleOrSuperseded(
                result,
                command: .open,
                source: source,
                identities: identities,
                before: currentSnapshot.transport
            )
        }
        return await finishOpen(operation: operation, source: source, decision: decision)
    }

    private func dispatchPlay() async -> PlaybackCommandResult {
        let operation = nextOperation()
        guard !isClosed && !isClosing else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .closed),
                command: .play,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .closed,
                before: currentSnapshot.transport
            )
        }
        guard let source = currentSource else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .noSource),
                command: .play,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .rejected,
                before: currentSnapshot.transport
            )
        }
        guard runtime.availability == .available else {
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .play,
                source: source,
                effects: [.publish(.commandFailed)],
                reason: .engineUnavailable,
                before: currentSnapshot.transport
            )
        }
        guard canPlay else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .invalidState),
                command: .play,
                source: source,
                effects: [.publish(.commandRejected)],
                reason: .invalidState,
                before: currentSnapshot.transport
            )
        }

        await supersedePendingSeek(by: operation)
        let before = currentSnapshot
        updateSnapshot(operation: .set(operation))
        await supersedePendingOpen(by: operation)
        let identities = before.identities
        let decision = await runtime.execute(.play)
        guard isCurrent(operation: operation, source: source, identities: identities) else {
            return await finishStaleOrSuperseded(
                staleOrSupersededResult(for: operation, source: source, identities: identities),
                command: .play,
                source: source,
                identities: identities,
                before: currentSnapshot.transport
            )
        }

        switch decision {
        case .accepted, .acceptedWithCapabilities:
            updateSnapshot(
                intent: .set(.playing),
                transport: currentSnapshot.transport == .failed(.runtime(.mediaServicesReset)) ? .set(.ready) : .keep,
                suppression: .set(nil),
                audio: .set(.active),
                video: .set(videoStateForPlaying)
            )
            await publishSnapshotChanges(from: before, operation: operation, sourceOverride: source)
            await emit(.transportPlaying, operation: operation, source: source)
            return await finishImmediate(
                .accepted(operation: operation),
                command: .play,
                source: source,
                effects: [.runtimeCommand(.play), .publish(.intentChanged), .publish(.audioLaneChanged), .publish(.commandAccepted)],
                reason: .accepted,
                before: before.transport
            )
        case let .rejected(reason):
            return await finishImmediate(
                .rejected(operation: operation, reason: reason),
                command: .play,
                source: source,
                effects: [.runtimeCommand(.play), .publish(.commandRejected)],
                reason: reasonCode(for: reason),
                before: before.transport
            )
        case let .failed(failure):
            return await finishImmediate(
                .failed(operation: operation, failure: failure),
                command: .play,
                source: source,
                effects: [.runtimeCommand(.play), .publish(.commandFailed)],
                reason: reasonCode(for: failure),
                before: before.transport
            )
        case .unavailable:
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .play,
                source: source,
                effects: [.runtimeCommand(.play), .publish(.commandFailed)],
                reason: .engineUnavailable,
                before: before.transport
            )
        }
    }

    private func dispatchPause() async -> PlaybackCommandResult {
        let operation = nextOperation()
        guard !isClosed && !isClosing else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .closed),
                command: .pause,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .closed,
                before: currentSnapshot.transport
            )
        }
        guard let source = currentSource else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .noSource),
                command: .pause,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .rejected,
                before: currentSnapshot.transport
            )
        }
        guard runtime.availability == .available else {
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .pause,
                source: source,
                effects: [.publish(.commandFailed)],
                reason: .engineUnavailable,
                before: currentSnapshot.transport
            )
        }
        guard canPause else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .invalidState),
                command: .pause,
                source: source,
                effects: [.publish(.commandRejected)],
                reason: .invalidState,
                before: currentSnapshot.transport
            )
        }

        await supersedePendingSeek(by: operation)
        let before = currentSnapshot
        updateSnapshot(operation: .set(operation))
        let identities = before.identities
        let decision = await runtime.execute(.pause)
        guard isCurrent(operation: operation, source: source, identities: identities) else {
            return await finishStaleOrSuperseded(
                staleOrSupersededResult(for: operation, source: source, identities: identities),
                command: .pause,
                source: source,
                identities: identities,
                before: currentSnapshot.transport
            )
        }

        switch decision {
        case .accepted, .acceptedWithCapabilities:
            updateSnapshot(
                intent: .set(.pausedByUser),
                suppression: .set(nil),
                audio: .set(.parked),
                video: .set(.parked)
            )
            await publishSnapshotChanges(from: before, operation: operation, sourceOverride: source)
            await emit(.transportPaused, operation: operation, source: source)
            return await finishImmediate(
                .accepted(operation: operation),
                command: .pause,
                source: source,
                effects: [.runtimeCommand(.pause), .publish(.intentChanged), .publish(.audioLaneChanged), .publish(.videoLaneChanged), .publish(.commandAccepted)],
                reason: .accepted,
                before: before.transport
            )
        case let .rejected(reason):
            return await finishImmediate(
                .rejected(operation: operation, reason: reason),
                command: .pause,
                source: source,
                effects: [.runtimeCommand(.pause), .publish(.commandRejected)],
                reason: reasonCode(for: reason),
                before: before.transport
            )
        case let .failed(failure):
            return await finishImmediate(
                .failed(operation: operation, failure: failure),
                command: .pause,
                source: source,
                effects: [.runtimeCommand(.pause), .publish(.commandFailed)],
                reason: reasonCode(for: failure),
                before: before.transport
            )
        case .unavailable:
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .pause,
                source: source,
                effects: [.runtimeCommand(.pause), .publish(.commandFailed)],
                reason: .engineUnavailable,
                before: before.transport
            )
        }
    }

    private func dispatchSeek(_ time: TimeInterval, mode: PlaybackSeekMode) async -> PlaybackCommandResult {
        let operation = nextOperation()
        guard !isClosed && !isClosing else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .closed),
                command: .seek,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .closed,
                before: currentSnapshot.transport
            )
        }
        guard let source = currentSource else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .noSource),
                command: .seek,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .rejected,
                before: currentSnapshot.transport
            )
        }
        guard time.isFinite, time >= 0 else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .invalidSeek),
                command: .seek,
                source: source,
                effects: [.publish(.commandRejected)],
                reason: .invalidValue,
                before: currentSnapshot.transport
            )
        }
        guard runtime.availability == .available else {
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .seek,
                source: source,
                effects: [.publish(.commandFailed)],
                reason: .engineUnavailable,
                before: currentSnapshot.transport
            )
        }
        guard currentSnapshot.capabilities.contains(.seeking) else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .unsupported(.seeking)),
                command: .seek,
                source: source,
                effects: [.publish(.commandRejected)],
                reason: .unsupported,
                before: currentSnapshot.transport
            )
        }

        await supersedePendingSeek(by: operation)
        let before = currentSnapshot
        let identities = currentSnapshot.identities
        updateSnapshot(operation: .set(operation))
        let runtime = self.runtime
        return await withCheckedContinuation { continuation in
            pendingSeek = PendingSeek(
                operation: operation,
                target: time,
                source: source,
                identities: identities,
                continuation: continuation
            )
            seekTask = Task { @MainActor [weak self] in
                let decision = await runtime.execute(.seek(to: time, mode: mode))
                await self?.finishSeek(
                    operation: operation,
                    target: time,
                    source: source,
                    before: before,
                    decision: decision
                )
            }
        }
    }

    private func dispatchSetRate(_ rate: Float) async -> PlaybackCommandResult {
        let operation = nextOperation()
        guard !isClosed && !isClosing else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .closed),
                command: .setRate,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .closed,
                before: currentSnapshot.transport
            )
        }
        guard let source = currentSource else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .noSource),
                command: .setRate,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .rejected,
                before: currentSnapshot.transport
            )
        }
        guard rate.isFinite, rate > 0, rate <= 8 else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .invalidRate),
                command: .setRate,
                source: source,
                effects: [.publish(.commandRejected)],
                reason: .invalidValue,
                before: currentSnapshot.transport
            )
        }
        guard runtime.availability == .available else {
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .setRate,
                source: source,
                effects: [.publish(.commandFailed)],
                reason: .engineUnavailable,
                before: currentSnapshot.transport
            )
        }
        guard currentSnapshot.capabilities.contains(.playbackRate) else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .unsupported(.playbackRate)),
                command: .setRate,
                source: source,
                effects: [.publish(.commandRejected)],
                reason: .unsupported,
                before: currentSnapshot.transport
            )
        }

        await supersedePendingSeek(by: operation)
        let before = currentSnapshot
        updateSnapshot(operation: .set(operation))
        await supersedePendingOpen(by: operation)
        let identities = before.identities
        let decision = await runtime.execute(.setRate(rate))
        guard isCurrent(operation: operation, source: source, identities: identities) else {
            return await finishStaleOrSuperseded(
                staleOrSupersededResult(for: operation, source: source, identities: identities),
                command: .setRate,
                source: source,
                identities: identities,
                before: currentSnapshot.transport
            )
        }

        switch decision {
        case .accepted, .acceptedWithCapabilities:
            updateSnapshot(rate: .set(rate))
            return await finishImmediate(
                .accepted(operation: operation),
                command: .setRate,
                source: source,
                effects: [.runtimeCommand(.setRate), .snapshotRevision, .publish(.commandAccepted)],
                reason: .accepted,
                before: before.transport
            )
        case let .rejected(reason):
            return await finishImmediate(
                .rejected(operation: operation, reason: reason),
                command: .setRate,
                source: source,
                effects: [.runtimeCommand(.setRate), .publish(.commandRejected)],
                reason: reasonCode(for: reason),
                before: before.transport
            )
        case let .failed(failure):
            return await finishImmediate(
                .failed(operation: operation, failure: failure),
                command: .setRate,
                source: source,
                effects: [.runtimeCommand(.setRate), .publish(.commandFailed)],
                reason: reasonCode(for: failure),
                before: before.transport
            )
        case .unavailable:
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .setRate,
                source: source,
                effects: [.runtimeCommand(.setRate), .publish(.commandFailed)],
                reason: .engineUnavailable,
                before: before.transport
            )
        }
    }

    private func dispatchStop(_ stopReason: PlaybackStopReason) async -> PlaybackCommandResult {
        let operation = nextOperation()
        guard !isClosed && !isClosing else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .closed),
                command: .stop,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .closed,
                before: currentSnapshot.transport
            )
        }

        let source = currentSource
        let identities = currentSnapshot.identities
        let before = currentSnapshot
        updateSnapshot(operation: .set(operation))
        await supersedePendingOpen(by: operation)
        await supersedePendingSeek(by: operation)
        _ = await runtime.execute(.stop(reason: stopReason))
        guard isCurrent(operation: operation, source: source, identities: identities) else {
            return await finishStaleOrSuperseded(
                staleOrSupersededResult(for: operation, source: source, identities: identities),
                command: .stop,
                source: source,
                identities: identities,
                before: before.transport
            )
        }
        updateSnapshot(
            source: .set(nil),
            identities: .set(.init()),
            intent: .set(.stopped),
            transport: .set(.idle),
            suppression: .set(nil),
            audio: .set(.unavailable),
            video: .set(.unavailable),
            presentation: .set(.init()),
            operation: .set(nil),
            mediaTime: .set(0),
            capabilities: .set([])
        )
        await publishSnapshotChanges(
            from: before,
            operation: operation,
            sourceOverride: source,
            identitiesOverride: identities
        )
        await emit(
            .stopped(reason: stopReason),
            operation: operation,
            source: source,
            identities: identities
        )
        return await finishImmediate(
            .accepted(operation: operation),
            command: .stop,
            source: source,
            identities: identities,
            effects: [.runtimeCommand(.stop), .publish(.stopped), .publish(.commandAccepted)],
            reason: .stopped,
            before: before.transport
        )
    }

    private func dispatchPictureInPicture(
        _ request: PlaybackPictureInPictureRequest
    ) async -> PlaybackCommandResult {
        let operation = nextOperation()
        guard !isClosed && !isClosing else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .closed),
                command: .requestPictureInPicture,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .closed,
                before: currentSnapshot.transport
            )
        }
        guard let source = currentSource else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .noSource),
                command: .requestPictureInPicture,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .rejected,
                before: currentSnapshot.transport
            )
        }
        guard runtime.availability == .available else {
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .requestPictureInPicture,
                source: source,
                effects: [.publish(.commandFailed)],
                reason: .engineUnavailable,
                before: currentSnapshot.transport
            )
        }
        guard currentSnapshot.capabilities.contains(.pictureInPicture) else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .unsupported(.pictureInPicture)),
                command: .requestPictureInPicture,
                source: source,
                effects: [.publish(.commandRejected)],
                reason: .unsupported,
                before: currentSnapshot.transport
            )
        }

        if case .start = request, currentSnapshot.identities.pictureInPictureBinding != nil {
            return await finishImmediate(
                .rejected(operation: operation, reason: .invalidState),
                command: .requestPictureInPicture,
                source: source,
                effects: [.publish(.commandRejected)],
                reason: .invalidState,
                before: currentSnapshot.transport
            )
        }
        if case .stop = request, currentSnapshot.identities.pictureInPictureBinding == nil {
            return await finishImmediate(
                .rejected(operation: operation, reason: .noPictureInPictureBinding),
                command: .requestPictureInPicture,
                source: source,
                effects: [.publish(.commandRejected)],
                reason: .invalidState,
                before: currentSnapshot.transport
            )
        }

        await supersedePendingSeek(by: operation)
        let before = currentSnapshot
        if case .start = request {
            let binding = PlaybackPictureInPictureBindingID(rawValue: "pip-\(UUID().uuidString)")
            updateSnapshot(
                identities: .set(PlaybackIdentityContext(
                    ownerLease: currentSnapshot.identities.ownerLease,
                    lifecycleEpoch: currentSnapshot.identities.lifecycleEpoch,
                    surfaceBinding: currentSnapshot.identities.surfaceBinding,
                    pictureInPictureBinding: binding
                )),
                video: .set(.waitingForSurface),
                presentation: .set(PlaybackPresentationState(
                    route: .pictureInPicture,
                    surface: PlaybackSurface(
                        id: PlaybackSurfaceID(rawValue: "surface-\(binding.rawValue)"),
                        kind: .pictureInPicture,
                        isAvailable: false
                    ),
                    proof: nil
                )),
                operation: .set(operation)
            )
        } else {
            updateSnapshot(operation: .set(operation))
        }

        let identities = currentSnapshot.identities
        await publishSnapshotChanges(from: before, operation: operation, sourceOverride: source)
        await emit(
            .pictureInPictureRequest(request),
            operation: operation,
            source: source
        )
        let decision = await runtime.execute(.requestPictureInPicture(request))
        guard isCurrent(
            operation: operation,
            source: source,
            identities: identities,
            includePictureInPictureBinding: true
        ) else {
            return await finishStaleOrSuperseded(
                staleOrSupersededResult(
                    for: operation,
                    source: source,
                    identities: identities,
                    includePictureInPictureBinding: true
                ),
                command: .requestPictureInPicture,
                source: source,
                identities: identities,
                before: before.transport
            )
        }
        let isStartRequest: Bool
        if case .start = request { isStartRequest = true } else { isStartRequest = false }
        switch decision {
        case .accepted, .acceptedWithCapabilities:
            return await finishImmediate(
                .accepted(operation: operation),
                command: .requestPictureInPicture,
                source: source,
                identities: identities,
                effects: [.runtimeCommand(.requestPictureInPicture), .publish(.pictureInPictureRequest), .publish(.commandAccepted)],
                reason: .accepted,
                before: before.transport
            )
        case let .rejected(reason):
            if isStartRequest {
                await clearPictureInPictureBindingIfCurrent(
                    operation: operation,
                    source: source,
                    identities: identities
                )
            }
            return await finishImmediate(
                .rejected(operation: operation, reason: reason),
                command: .requestPictureInPicture,
                source: source,
                identities: identities,
                effects: [.runtimeCommand(.requestPictureInPicture), .publish(.commandRejected)],
                reason: reasonCode(for: reason),
                before: before.transport
            )
        case let .failed(failure):
            if isStartRequest {
                await clearPictureInPictureBindingIfCurrent(operation: operation, source: source, identities: identities)
            }
            return await finishImmediate(
                .failed(operation: operation, failure: failure),
                command: .requestPictureInPicture,
                source: source,
                identities: identities,
                effects: [.runtimeCommand(.requestPictureInPicture), .publish(.commandFailed)],
                reason: reasonCode(for: failure),
                before: before.transport
            )
        case .unavailable:
            if isStartRequest {
                await clearPictureInPictureBindingIfCurrent(operation: operation, source: source, identities: identities)
            }
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .requestPictureInPicture,
                source: source,
                identities: identities,
                effects: [.runtimeCommand(.requestPictureInPicture), .publish(.commandFailed)],
                reason: .engineUnavailable,
                before: before.transport
            )
        }
    }

    private func dispatchClose() async -> PlaybackCommandResult {
        let operation = nextOperation()
        guard !isClosed && !isClosing else {
            return await finishImmediate(
                .rejected(operation: operation, reason: .closed),
                command: .close,
                source: nil,
                effects: [.publish(.commandRejected)],
                reason: .closed,
                before: currentSnapshot.transport
            )
        }

        isClosing = true
        let source = currentSource
        let identities = currentSnapshot.identities
        let before = currentSnapshot
        updateSnapshot(operation: .set(operation))
        await supersedePendingOpen(by: operation)
        await supersedePendingSeek(by: operation)
        runtimeEventTask?.cancel()
        runtimeEventTask = nil
        _ = await runtime.execute(.close)
        updateSnapshot(
            source: .set(nil),
            identities: .set(.init()),
            intent: .set(.stopped),
            transport: .set(.closed),
            suppression: .set(nil),
            audio: .set(.unavailable),
            video: .set(.unavailable),
            presentation: .set(.init()),
            operation: .set(nil),
            mediaTime: .set(0),
            capabilities: .set([])
        )
        await publishSnapshotChanges(
            from: before,
            operation: operation,
            sourceOverride: source,
            identitiesOverride: identities
        )
        await emit(.closed, operation: operation, source: source, identities: identities)
        let result = await finishImmediate(
            .accepted(operation: operation),
            command: .close,
            source: source,
            identities: identities,
            effects: [.runtimeCommand(.close), .publish(.closed), .publish(.commandAccepted), .close],
            reason: .accepted,
            before: before.transport
        )
        isClosed = true
        isClosing = false
        eventContinuation.finish()
        return result
    }

    // MARK: - Environment dispatcher and policy projection

    private func dispatchEnvironment(
        _ event: PlaybackEnvironmentEvent,
        eventID: PlaybackEnvironmentEventID,
        serial: UInt64
    ) async -> PlaybackEnvironmentResult {
        if isClosed || isClosing {
            return await finishEnvironmentIgnored(event, eventID: eventID, reason: .closed)
        }
        if let reason = staleReason(for: event) {
            return await finishEnvironmentIgnored(event, eventID: eventID, reason: reason)
        }

        let before = currentSnapshot
        _ = await runtime.execute(.environment(event.kind))
        if isClosed || isClosing {
            return await finishEnvironmentIgnored(event, eventID: eventID, reason: .closed)
        }
        if let reason = staleReason(for: event) {
            return await finishEnvironmentIgnored(event, eventID: eventID, reason: reason)
        }
        guard latestEnvironmentSerials[event.kind] == serial else {
            return await finishEnvironmentIgnored(event, eventID: eventID, reason: .stale)
        }
        let invalidatesOperation = environmentInvalidatesCurrentOperation(event)
        let recoveryDisposition = applyEnvironment(event)
        if invalidatesOperation {
            await abandonPendingOperationsAsStale()
        }
        await publishSnapshotChanges(
            from: before,
            operation: nil,
            environmentEvent: eventID
        )
        await emit(
            .environmentApplied(event.kind),
            operation: nil,
            source: currentSource,
            environmentEvent: eventID
        )
        if case let .pictureInPicture(nativeEvent) = event {
            await emit(
                .pictureInPictureNative(nativeEvent.kind),
                operation: nil,
                source: currentSource,
                environmentEvent: eventID
            )
        }
        if let recoveryDisposition {
            await emit(
                .recoveryDisposition(recoveryDisposition),
                operation: nil,
                source: currentSource,
                environmentEvent: eventID
            )
        }
        await recordDecision(
            input: .environment(event.kind),
            source: currentSource,
            operation: nil,
            identities: currentSnapshot.identities,
            before: before.transport,
            effects: [
                .environment(event.kind),
                .publish(.environmentApplied),
                recoveryDisposition.map { .recovery($0) } ?? .none
            ],
            result: .accepted,
            reason: recoveryDisposition == .systemResetRequiresUser ? .mediaServicesReset : .accepted
        )
        return .accepted(event: eventID)
    }

    private func finishEnvironmentIgnored(
        _ event: PlaybackEnvironmentEvent,
        eventID: PlaybackEnvironmentEventID,
        reason: PlaybackEnvironmentRejection
    ) async -> PlaybackEnvironmentResult {
        await emit(
            .environmentIgnored(event.kind, reason: reason),
            operation: nil,
            source: currentSource,
            environmentEvent: eventID
        )
        await recordDecision(
            input: .environment(event.kind),
            source: currentSource,
            operation: nil,
            identities: currentSnapshot.identities,
            before: currentSnapshot.transport,
            effects: [.publish(.environmentIgnored)],
            result: .ignored,
            reason: reason == .closed ? .closed : .stale
        )
        return .ignored(event: eventID, reason: reason)
    }

    private func applyEnvironment(
        _ event: PlaybackEnvironmentEvent
    ) -> PlaybackRecoveryDisposition? {
        switch event {
        case let .ownerLeaseChanged(owner):
            let ownerChanged = currentSnapshot.identities.ownerLease != owner
            updateSnapshot(identities: .set(PlaybackIdentityContext(
                ownerLease: owner,
                lifecycleEpoch: currentSnapshot.identities.lifecycleEpoch,
                surfaceBinding: ownerChanged ? nil : currentSnapshot.identities.surfaceBinding,
                pictureInPictureBinding: ownerChanged ? nil : currentSnapshot.identities.pictureInPictureBinding
            )), operation: ownerChanged ? .set(nil) : .keep)
            if ownerChanged {
                updateSnapshot(video: .set(.parked), presentation: .set(.init()))
            }
            return nil

        case let .applicationPhaseChanged(phase, epoch):
            let lifecycleChanged = currentSnapshot.identities.lifecycleEpoch != epoch
            updateSnapshot(identities: .set(PlaybackIdentityContext(
                ownerLease: currentSnapshot.identities.ownerLease,
                lifecycleEpoch: epoch,
                surfaceBinding: currentSnapshot.identities.surfaceBinding,
                pictureInPictureBinding: currentSnapshot.identities.pictureInPictureBinding
            )), operation: lifecycleChanged ? .set(nil) : .keep)
            switch phase {
            case .background:
                if currentSnapshot.intent == .playing,
                   configuration.backgroundAudioEnabled,
                   currentSnapshot.capabilities.contains(.backgroundAudio) {
                    updateSnapshot(
                        suppression: .set(nil),
                        audio: .set(.active),
                        video: .set(.parked),
                        presentation: .set(PlaybackPresentationState())
                    )
                } else {
                    updateSnapshot(
                        suppression: currentSnapshot.intent == .playing ? .set(.backgroundPolicy) : .set(nil),
                        audio: .set(.parked),
                        video: .set(.parked),
                        presentation: .set(PlaybackPresentationState())
                    )
                }
            case .foreground:
                guard currentSnapshot.intent == .playing else { return nil }
                if currentSnapshot.suppression == .backgroundPolicy {
                    updateSnapshot(suppression: .set(nil))
                }
                if currentSnapshot.suppression == nil {
                    updateSnapshot(
                        audio: .set(.active),
                        video: .set(videoStateForPlaying)
                    )
                }
            case .inactive:
                break
            }
            return nil

        case let .audioInterruption(interruption):
            switch interruption {
            case .began:
                guard currentSnapshot.intent == .playing else { return nil }
                updateSnapshot(
                    suppression: .set(.audioInterruption),
                    audio: .set(.interrupted)
                )
            case let .ended(shouldResume):
                guard currentSnapshot.intent == .playing else { return nil }
                if shouldResume {
                    updateSnapshot(
                        suppression: .set(nil),
                        audio: .set(.active),
                        video: .set(videoStateForPlaying)
                    )
                } else {
                    updateSnapshot(
                        suppression: .set(.audioInterruption),
                        audio: .set(.parked)
                    )
                }
            }
            return nil

        case .mediaServices:
            let failure = PlaybackFailure.runtime(.mediaServicesReset)
            updateSnapshot(
                transport: .set(.failed(failure)),
                suppression: .set(.mediaServicesUnavailable),
                audio: .set(.failed(failure)),
                video: .set(.failed(failure)),
                presentation: .set(.init())
            )
            return .systemResetRequiresUser

        case let .surface(surfaceEvent):
            switch surfaceEvent {
            case let .attached(binding):
                let surface = PlaybackSurface(
                    id: PlaybackSurfaceID(rawValue: "surface-\(binding.rawValue)"),
                    kind: .inline,
                    isAvailable: true
                )
                updateSnapshot(
                    identities: .set(PlaybackIdentityContext(
                        ownerLease: currentSnapshot.identities.ownerLease,
                        lifecycleEpoch: currentSnapshot.identities.lifecycleEpoch,
                        surfaceBinding: binding,
                        pictureInPictureBinding: currentSnapshot.identities.pictureInPictureBinding
                    )),
                    video: .set(.waitingForSurface),
                    presentation: .set(PlaybackPresentationState(route: .inline, surface: surface, proof: nil))
                )
            case let .detached(binding):
                guard currentSnapshot.identities.surfaceBinding == binding else { return nil }
                updateSnapshot(
                    identities: .set(PlaybackIdentityContext(
                        ownerLease: currentSnapshot.identities.ownerLease,
                        lifecycleEpoch: currentSnapshot.identities.lifecycleEpoch,
                        surfaceBinding: nil,
                        pictureInPictureBinding: currentSnapshot.identities.pictureInPictureBinding
                    )),
                    video: .set(.parked),
                    presentation: .set(.init())
                )
            case let .visibilityChanged(binding, visible):
                guard currentSnapshot.identities.surfaceBinding == binding else { return nil }
                let surface = currentSnapshot.presentation.surface
                    ?? PlaybackSurface(
                        id: PlaybackSurfaceID(rawValue: "surface-\(binding.rawValue)"),
                        kind: .inline,
                        isAvailable: visible
                    )
                let updatedSurface = PlaybackSurface(
                    id: surface.id,
                    kind: .inline,
                    isAvailable: visible
                )
                updateSnapshot(
                    video: .set(visible ? .waitingForSurface : .parked),
                    presentation: .set(PlaybackPresentationState(
                        route: visible ? .inline : .none,
                        surface: updatedSurface,
                        proof: nil
                    ))
                )
            }
            return nil

        case let .pictureInPicture(nativeEvent):
            let binding = nativeEvent.binding
            guard currentSnapshot.identities.pictureInPictureBinding == binding else { return nil }
            switch nativeEvent {
            case .willStart:
                break
            case .didStart:
                let surface = PlaybackSurface(
                    id: PlaybackSurfaceID(rawValue: "surface-\(binding.rawValue)"),
                    kind: .pictureInPicture,
                    isAvailable: true
                )
                updateSnapshot(
                    video: .set(.waitingForSurface),
                    presentation: .set(PlaybackPresentationState(
                        route: .pictureInPicture,
                        surface: surface,
                        proof: nil
                    ))
                )
            case .failedToStart:
                updateSnapshot(
                    identities: .set(PlaybackIdentityContext(
                        ownerLease: currentSnapshot.identities.ownerLease,
                        lifecycleEpoch: currentSnapshot.identities.lifecycleEpoch,
                        surfaceBinding: currentSnapshot.identities.surfaceBinding,
                        pictureInPictureBinding: nil
                    )),
                    video: .set(.parked),
                    presentation: .set(.init())
                )
            case .willStop:
                break
            case .didStop:
                let inlineSurface = currentSnapshot.identities.surfaceBinding.map { binding in
                    PlaybackSurface(
                        id: PlaybackSurfaceID(rawValue: "surface-\(binding.rawValue)"),
                        kind: .inline,
                        isAvailable: true
                    )
                }
                updateSnapshot(
                    identities: .set(PlaybackIdentityContext(
                        ownerLease: currentSnapshot.identities.ownerLease,
                        lifecycleEpoch: currentSnapshot.identities.lifecycleEpoch,
                        surfaceBinding: currentSnapshot.identities.surfaceBinding,
                        pictureInPictureBinding: nil
                    )),
                    video: .set(currentSnapshot.identities.surfaceBinding == nil ? .parked : .waitingForSurface),
                    presentation: .set(inlineSurface.map {
                        PlaybackPresentationState(route: .inline, surface: $0, proof: nil)
                    } ?? .init())
                )
            case .restoreUIRequested, .restoreUICompleted:
                break
            }
            return nil
        }
    }

    private func staleReason(for event: PlaybackEnvironmentEvent) -> PlaybackEnvironmentRejection? {
        switch event {
        case let .applicationPhaseChanged(_, epoch):
            if let highest = highestApplicationEpochSeen,
               epoch.rawValue < highest {
                return .stale
            }
            if let current = currentSnapshot.identities.lifecycleEpoch,
               epoch.rawValue < current.rawValue {
                return .stale
            }
        case let .surface(surfaceEvent):
            switch surfaceEvent {
            case .attached:
                break
            case let .detached(binding), let .visibilityChanged(binding, _):
                if currentSnapshot.identities.surfaceBinding != binding { return .stale }
            }
        case let .pictureInPicture(nativeEvent):
            if currentSnapshot.identities.pictureInPictureBinding != nativeEvent.binding {
                return .stale
            }
        case .ownerLeaseChanged, .audioInterruption, .mediaServices:
            break
        }
        return nil
    }

    private func environmentInvalidatesCurrentOperation(
        _ event: PlaybackEnvironmentEvent
    ) -> Bool {
        switch event {
        case let .ownerLeaseChanged(owner):
            return currentSnapshot.identities.ownerLease != owner
        case let .applicationPhaseChanged(_, epoch):
            return currentSnapshot.identities.lifecycleEpoch != epoch
        case .audioInterruption, .mediaServices, .surface, .pictureInPicture:
            return false
        }
    }

    // MARK: - Command settlement

    private func awaitOpenDecision(
        operation: PlaybackOperationID,
        source: PlaybackSource,
        identities: PlaybackIdentityContext
    ) async -> PlaybackRuntimeDecision {
        let runtime = self.runtime
        let configuration = self.configuration
        return await withCheckedContinuation { continuation in
            pendingOpen = PendingOpen(
                operation: operation,
                source: source,
                identities: identities,
                continuation: continuation
            )
            openTask = Task { @MainActor [weak self] in
                let decision = await runtime.execute(.open(source: source, configuration: configuration))
                self?.finishOpenRuntime(operation: operation, decision: decision)
            }
        }
    }

    private func finishOpenRuntime(
        operation: PlaybackOperationID,
        decision: PlaybackRuntimeDecision
    ) {
        guard let pendingOpen, pendingOpen.operation == operation else { return }
        self.pendingOpen = nil
        openTask = nil
        pendingOpen.continuation.resume(returning: decision)
    }

    private func supersedePendingOpen(by _: PlaybackOperationID) async {
        guard let pendingOpen else { return }
        openTask?.cancel()
        openTask = nil
        self.pendingOpen = nil
        pendingOpen.continuation.resume(returning: .unavailable)
    }

    private func abandonPendingOperationsAsStale() async {
        if let pendingOpen {
            openTask?.cancel()
            openTask = nil
            self.pendingOpen = nil
            pendingOpen.continuation.resume(returning: .unavailable)
        }
        guard let pendingSeek else { return }
        seekTask?.cancel()
        seekTask = nil
        self.pendingSeek = nil
        let result = await finishStaleOrSuperseded(
            .rejected(operation: pendingSeek.operation, reason: .stale),
            command: .seek,
            source: pendingSeek.source,
            identities: pendingSeek.identities,
            before: currentSnapshot.transport
        )
        pendingSeek.continuation.resume(returning: result)
    }

    private func finishOpen(
        operation: PlaybackOperationID,
        source: PlaybackSource,
        decision: PlaybackRuntimeDecision
    ) async -> PlaybackCommandResult {
        let beforeSnapshot = currentSnapshot
        let before = currentSnapshot.transport
        switch decision {
        case .accepted, .acceptedWithCapabilities:
            let reported: Set<PlaybackCapability>?
            if case let .acceptedWithCapabilities(value) = decision {
                reported = value
            } else {
                reported = nil
            }
            let capabilities = resolvedCapabilities(for: source, reported: reported)
            let intent: PlaybackIntent = configuration.autoplay ? .playing : .stopped
            updateSnapshot(
                intent: .set(intent),
                transport: .set(.ready),
                suppression: .set(nil),
                audio: .set(configuration.autoplay ? .active : .parked),
                video: .set(.waitingForSurface),
                presentation: .set(.init()),
                capabilities: .set(capabilities)
            )
            await publishSnapshotChanges(from: beforeSnapshot, operation: operation, sourceOverride: source)
            if configuration.autoplay {
                await emit(.transportPlaying, operation: operation, source: source)
            }
            var effects: [PlaybackEffectSummary] = [
                .runtimeCommand(.open),
                .publish(.transportChanged),
                .publish(.transportReady)
            ]
            if configuration.autoplay { effects.append(.publish(.transportPlaying)) }
            effects.append(.publish(.commandAccepted))
            return await finishImmediate(
                .accepted(operation: operation),
                command: .open,
                source: source,
                effects: effects,
                reason: .accepted,
                before: before
            )
        case let .rejected(reason):
            updateSnapshot(
                transport: .set(.idle),
                suppression: .set(nil),
                audio: .set(.unavailable),
                video: .set(.unavailable),
                presentation: .set(.init()),
                capabilities: .set([])
            )
            await publishSnapshotChanges(from: beforeSnapshot, operation: operation, sourceOverride: source)
            return await finishImmediate(
                .rejected(operation: operation, reason: reason),
                command: .open,
                source: source,
                effects: [.runtimeCommand(.open), .publish(.transportChanged), .publish(.commandRejected)],
                reason: reasonCode(for: reason),
                before: before
            )
        case let .failed(failure):
            updateSnapshot(
                transport: .set(.failed(failure)),
                audio: .set(.failed(failure)),
                video: .set(.failed(failure))
            )
            await publishSnapshotChanges(from: beforeSnapshot, operation: operation, sourceOverride: source)
            return await finishImmediate(
                .failed(operation: operation, failure: failure),
                command: .open,
                source: source,
                effects: [.runtimeCommand(.open), .publish(.transportChanged), .publish(.commandFailed)],
                reason: reasonCode(for: failure),
                before: before
            )
        case .unavailable:
            updateSnapshot(
                transport: .set(.idle),
                suppression: .set(.resourceUnavailable),
                audio: .set(.unavailable),
                video: .set(.unavailable),
                presentation: .set(.init()),
                capabilities: .set([])
            )
            await publishSnapshotChanges(from: beforeSnapshot, operation: operation, sourceOverride: source)
            return await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .open,
                source: source,
                effects: [.runtimeCommand(.open), .publish(.transportChanged), .publish(.commandFailed)],
                reason: .engineUnavailable,
                before: before
            )
        }
    }

    private func finishSeek(
        operation: PlaybackOperationID,
        target: TimeInterval,
        source: PlaybackSource,
        before: PlaybackSnapshot,
        decision: PlaybackRuntimeDecision
    ) async {
        guard let pendingSeek, pendingSeek.operation == operation else { return }
        self.pendingSeek = nil
        seekTask = nil

        guard isCurrent(operation: operation, source: source, identities: pendingSeek.identities) else {
            let result = staleOrSupersededResult(
                for: operation,
                source: source,
                identities: pendingSeek.identities
            )
            let settled = await finishStaleOrSuperseded(
                result,
                command: .seek,
                source: source,
                identities: pendingSeek.identities,
                before: before.transport
            )
            pendingSeek.continuation.resume(returning: settled)
            return
        }

        switch decision {
        case .accepted, .acceptedWithCapabilities:
            updateSnapshot(mediaTime: .set(target))
            let result = await finishImmediate(
                .accepted(operation: operation),
                command: .seek,
                source: source,
                effects: [.runtimeCommand(.seek), .snapshotRevision, .publish(.commandAccepted)],
                reason: .accepted,
                before: before.transport
            )
            pendingSeek.continuation.resume(returning: result)
        case let .rejected(reason):
            let result = await finishImmediate(
                .rejected(operation: operation, reason: reason),
                command: .seek,
                source: source,
                effects: [.runtimeCommand(.seek), .publish(.commandRejected)],
                reason: reasonCode(for: reason),
                before: before.transport
            )
            pendingSeek.continuation.resume(returning: result)
        case let .failed(failure):
            let result = await finishImmediate(
                .failed(operation: operation, failure: failure),
                command: .seek,
                source: source,
                effects: [.runtimeCommand(.seek), .publish(.commandFailed)],
                reason: reasonCode(for: failure),
                before: before.transport
            )
            pendingSeek.continuation.resume(returning: result)
        case .unavailable:
            let result = await finishImmediate(
                .failed(operation: operation, failure: .engineUnavailable),
                command: .seek,
                source: source,
                effects: [.runtimeCommand(.seek), .publish(.commandFailed)],
                reason: .engineUnavailable,
                before: before.transport
            )
            pendingSeek.continuation.resume(returning: result)
        }
    }

    private func finishImmediate(
        _ result: PlaybackCommandResult,
        command: PlaybackCommandKind,
        source: PlaybackSource?,
        identities: PlaybackIdentityContext? = nil,
        effects: [PlaybackEffectSummary],
        reason: PlaybackReasonCode,
        before: PlaybackTransportState
    ) async -> PlaybackCommandResult {
        if !isClosed {
            switch result {
            case .accepted:
                await emit(.commandAccepted, operation: result.operation, source: source, identities: identities)
            case let .rejected(_, rejection):
                await emit(.commandRejected(reason: rejection), operation: result.operation, source: source, identities: identities)
            case let .superseded(_, by):
                await emit(.commandSuperseded(by: by), operation: result.operation, source: source, identities: identities)
            case let .failed(_, failure):
                await emit(.commandFailed(failure: failure), operation: result.operation, source: source, identities: identities)
            }
        }
        await recordDecision(
            input: .command(command),
            source: source,
            operation: result.operation,
            identities: identities ?? currentSnapshot.identities,
            before: before,
            effects: effects,
            result: decisionResult(for: result),
            reason: reason
        )
        return result
    }

    private func finishStaleOrSuperseded(
        _ result: PlaybackCommandResult,
        command: PlaybackCommandKind,
        source: PlaybackSource?,
        identities: PlaybackIdentityContext,
        before: PlaybackTransportState
    ) async -> PlaybackCommandResult {
        switch result {
        case .superseded:
            return await finishImmediate(
                result,
                command: command,
                source: source,
                identities: identities,
                effects: [.publish(.commandSuperseded)],
                reason: .superseded,
                before: before
            )
        case .rejected(_, .stale):
            return await finishImmediate(
                result,
                command: command,
                source: source,
                identities: identities,
                effects: [.publish(.commandRejected)],
                reason: .stale,
                before: before
            )
        default:
            return await finishImmediate(
                .rejected(operation: result.operation, reason: .stale),
                command: command,
                source: source,
                identities: identities,
                effects: [.publish(.commandRejected)],
                reason: .stale,
                before: before
            )
        }
    }

    private func resolvedCapabilities(
        for source: PlaybackSource,
        reported: Set<PlaybackCapability>?
    ) -> Set<PlaybackCapability> {
        var capabilities = source.sourceCapabilities
        if let reported {
            var allowed = capabilities
            if configuration.backgroundAudioEnabled { allowed.insert(.backgroundAudio) }
            if configuration.pictureInPictureEnabled { allowed.insert(.pictureInPicture) }
            capabilities.formUnion(reported.intersection(allowed))
        }
        if configuration.backgroundAudioEnabled { capabilities.insert(.backgroundAudio) }
        if configuration.pictureInPictureEnabled { capabilities.insert(.pictureInPicture) }
        return capabilities
    }

    private func handleRuntimeEvent(_ event: PlaybackRuntimeEvent) async {
        guard !isClosed && !isClosing, let source = currentSource else { return }
        let before = currentSnapshot
        let operation = currentSnapshot.currentOperation

        switch event {
        case let .ready(duration, reportedCapabilities):
            guard currentSnapshot.transport == .opening
                || currentSnapshot.transport == .buffering
                || currentSnapshot.transport == .ready else {
                return
            }
            let durationChange: SnapshotChange<PlaybackDuration>
            if let duration, valid(duration: duration) {
                durationChange = .set(duration)
            } else {
                durationChange = .keep
            }
            let capabilitiesChange: SnapshotChange<Set<PlaybackCapability>> = reportedCapabilities.map {
                .set(resolvedCapabilities(for: source, reported: $0))
            } ?? .keep
            updateSnapshot(
                transport: .set(.ready),
                suppression: currentSnapshot.suppression == .resourceUnavailable ? .set(nil) : .keep,
                audio: currentSnapshot.intent == .playing ? .set(.active) : .keep,
                video: currentSnapshot.intent == .playing ? .set(videoStateForPlaying) : .keep,
                duration: durationChange,
                capabilities: capabilitiesChange
            )
            await publishSnapshotChanges(from: before, operation: operation, sourceOverride: source)

        case let .buffering(isBuffering):
            if isBuffering {
                guard currentSnapshot.transport == .ready || currentSnapshot.transport == .buffering else {
                    return
                }
                guard currentSnapshot.transport != .buffering else { return }
                updateSnapshot(transport: .set(.buffering))
            } else {
                guard currentSnapshot.transport == .buffering else { return }
                updateSnapshot(transport: .set(.ready))
            }
            await publishSnapshotChanges(from: before, operation: operation, sourceOverride: source)

        case let .progress(mediaTime, duration):
            guard currentSnapshot.transport == .ready || currentSnapshot.transport == .buffering,
                  pendingSeek == nil,
                  mediaTime.isFinite,
                  mediaTime >= 0 else {
                return
            }
            let durationChange: SnapshotChange<PlaybackDuration>
            if let duration, valid(duration: duration) {
                durationChange = .set(duration)
            } else {
                durationChange = .keep
            }
            updateSnapshot(mediaTime: .set(mediaTime), duration: durationChange)

        case .ended:
            guard currentSnapshot.transport == .ready
                || currentSnapshot.transport == .buffering
                || currentSnapshot.transport == .opening else {
                return
            }
            updateSnapshot(
                intent: .set(.stopped),
                transport: .set(.ended),
                suppression: .set(nil),
                audio: .set(.parked),
                video: .set(.parked)
            )
            await publishSnapshotChanges(from: before, operation: operation, sourceOverride: source)
            await emit(.stopped(reason: .ended), operation: operation, source: source)

        case let .failed(failure):
            guard currentSnapshot.transport != .closed else { return }
            if let pendingOpen {
                finishOpenRuntime(operation: pendingOpen.operation, decision: .failed(failure))
                return
            }
            if let pendingSeek {
                seekTask?.cancel()
                seekTask = nil
                self.pendingSeek = nil
                let result = await finishImmediate(
                    .failed(operation: pendingSeek.operation, failure: failure),
                    command: .seek,
                    source: pendingSeek.source,
                    identities: pendingSeek.identities,
                    effects: [.runtimeCommand(.seek), .publish(.commandFailed)],
                    reason: reasonCode(for: failure),
                    before: before.transport
                )
                pendingSeek.continuation.resume(returning: result)
            }
            updateSnapshot(
                intent: .set(.stopped),
                transport: .set(.failed(failure)),
                suppression: failure == .runtime(.mediaServicesReset)
                    ? .set(.mediaServicesUnavailable)
                    : .keep,
                audio: .set(.failed(failure)),
                video: .set(.failed(failure))
            )
            await publishSnapshotChanges(from: before, operation: operation, sourceOverride: source)
        }
    }

    private func supersedePendingSeek(by operation: PlaybackOperationID) async {
        guard let pendingSeek else { return }
        seekTask?.cancel()
        seekTask = nil
        self.pendingSeek = nil
        let result = PlaybackCommandResult.superseded(operation: pendingSeek.operation, by: operation)
        let settled = await finishImmediate(
            result,
            command: .seek,
            source: pendingSeek.source,
            identities: pendingSeek.identities,
            effects: [.runtimeCommand(.seek), .publish(.commandSuperseded)],
            reason: .superseded,
            before: currentSnapshot.transport
        )
        pendingSeek.continuation.resume(returning: settled)
    }

    private func clearPictureInPictureBindingIfCurrent(
        operation: PlaybackOperationID,
        source: PlaybackSource,
        identities: PlaybackIdentityContext
    ) async {
        guard isCurrent(
            operation: operation,
            source: source,
            identities: identities,
            includePictureInPictureBinding: true
        ) else { return }
        let before = currentSnapshot
        updateSnapshot(
            identities: .set(PlaybackIdentityContext(
                ownerLease: currentSnapshot.identities.ownerLease,
                lifecycleEpoch: currentSnapshot.identities.lifecycleEpoch,
                surfaceBinding: currentSnapshot.identities.surfaceBinding,
                pictureInPictureBinding: nil
            )),
            video: .set(.parked),
            presentation: .set(.init())
        )
        await publishSnapshotChanges(from: before, operation: operation, sourceOverride: source)
    }

    // MARK: - Snapshot, events, and journal

    private func updateSnapshot(
        source: SnapshotChange<PlaybackSource> = .keep,
        identities: SnapshotChange<PlaybackIdentityContext> = .keep,
        intent: SnapshotChange<PlaybackIntent> = .keep,
        transport: SnapshotChange<PlaybackTransportState> = .keep,
        suppression: SnapshotChange<PlaybackSuppressionReason> = .keep,
        audio: SnapshotChange<PlaybackAudioLaneState> = .keep,
        video: SnapshotChange<PlaybackVideoLaneState> = .keep,
        presentation: SnapshotChange<PlaybackPresentationState> = .keep,
        operation: SnapshotChange<PlaybackOperationID> = .keep,
        mediaTime: SnapshotChange<TimeInterval> = .keep,
        duration: SnapshotChange<PlaybackDuration> = .keep,
        rate: SnapshotChange<Float> = .keep,
        capabilities: SnapshotChange<Set<PlaybackCapability>> = .keep
    ) {
        let nextSource: PlaybackSource?
        switch source {
        case .keep: nextSource = currentSource
        case let .set(value): nextSource = value
        }
        currentSource = nextSource

        let nextIdentities: PlaybackIdentityContext
        switch identities {
        case .keep: nextIdentities = currentSnapshot.identities
        case let .set(value): nextIdentities = value ?? .init()
        }
        let nextIntent = value(for: intent, fallback: currentSnapshot.intent) ?? .stopped
        let nextTransport = value(for: transport, fallback: currentSnapshot.transport) ?? .idle
        let nextSuppression = value(for: suppression, fallback: currentSnapshot.suppression)
        let nextAudio = value(for: audio, fallback: currentSnapshot.audio) ?? .unavailable
        let nextVideo = value(for: video, fallback: currentSnapshot.video) ?? .unavailable
        let nextPresentation = value(for: presentation, fallback: currentSnapshot.presentation) ?? .init()
        let nextOperation = value(for: operation, fallback: currentSnapshot.currentOperation)
        let nextMediaTime = value(for: mediaTime, fallback: currentSnapshot.mediaTime) ?? 0
        let nextDuration: PlaybackDuration
        switch duration {
        case .keep:
            switch source {
            case let .set(value):
                nextDuration = value?.duration ?? .unknown
            case .keep:
                nextDuration = currentSnapshot.duration
            }
        case let .set(value):
            nextDuration = value ?? .unknown
        }
        let nextRate = value(for: rate, fallback: currentSnapshot.rate) ?? 1
        let nextCapabilities = value(for: capabilities, fallback: currentSnapshot.capabilities) ?? []

        currentSnapshot = PlaybackSnapshot(
            session: sessionID,
            source: nextSource?.id,
            authority: nextSource?.authority,
            identities: nextIdentities,
            intent: nextIntent,
            transport: nextTransport,
            suppression: nextSuppression,
            audio: nextAudio,
            video: nextVideo,
            presentation: nextPresentation,
            currentOperation: nextOperation,
            mediaTime: nextMediaTime,
            duration: nextDuration,
            rate: nextRate,
            capabilities: nextCapabilities,
            revision: currentSnapshot.revision &+ 1
        )
    }

    private func value<Value>(
        for change: SnapshotChange<Value>,
        fallback: Value?
    ) -> Value? {
        switch change {
        case .keep: return fallback
        case let .set(value): return value
        }
    }

    private func publishSnapshotChanges(
        from before: PlaybackSnapshot,
        operation: PlaybackOperationID?,
        sourceOverride: PlaybackSource? = nil,
        identitiesOverride: PlaybackIdentityContext? = nil,
        environmentEvent: PlaybackEnvironmentEventID? = nil
    ) async {
        let source = sourceOverride ?? currentSource
        let identities = identitiesOverride ?? currentSnapshot.identities
        if before.source != currentSnapshot.source || before.authority != currentSnapshot.authority {
            await emit(.sourceChanged, operation: operation, source: source, identities: identities, environmentEvent: environmentEvent)
        }
        if before.transport != currentSnapshot.transport {
            await emit(.transportChanged(currentSnapshot.transport), operation: operation, source: source, identities: identities, environmentEvent: environmentEvent)
            if currentSnapshot.transport == .ready {
                await emit(.transportReady, operation: operation, source: source, identities: identities, environmentEvent: environmentEvent)
            }
        }
        if before.intent != currentSnapshot.intent {
            await emit(.intentChanged(currentSnapshot.intent), operation: operation, source: source, identities: identities, environmentEvent: environmentEvent)
        }
        if before.suppression != currentSnapshot.suppression {
            await emit(.suppressionChanged(currentSnapshot.suppression), operation: operation, source: source, identities: identities, environmentEvent: environmentEvent)
        }
        if before.audio != currentSnapshot.audio {
            await emit(.audioLaneChanged(currentSnapshot.audio), operation: operation, source: source, identities: identities, environmentEvent: environmentEvent)
        }
        if before.video != currentSnapshot.video {
            await emit(.videoLaneChanged(currentSnapshot.video), operation: operation, source: source, identities: identities, environmentEvent: environmentEvent)
        }
        if before.presentation != currentSnapshot.presentation {
            await emit(.presentationChanged(currentSnapshot.presentation), operation: operation, source: source, identities: identities, environmentEvent: environmentEvent)
            if let proof = currentSnapshot.presentation.proof,
               proof != before.presentation.proof {
                await emit(.presentationProof(proof), operation: operation, source: source, identities: identities, environmentEvent: environmentEvent)
            }
        }
    }

    private func emit(
        _ event: PlaybackEvent,
        operation: PlaybackOperationID?,
        source: PlaybackSource?,
        identities: PlaybackIdentityContext? = nil,
        environmentEvent: PlaybackEnvironmentEventID? = nil
    ) async {
        guard !isClosed else { return }
        eventSequence &+= 1
        let envelope = PlaybackEventEnvelope(
            session: sessionID,
            source: source?.id,
            authority: source?.authority,
            operation: operation,
            identities: identities ?? currentSnapshot.identities,
            environmentEvent: environmentEvent,
            sequence: eventSequence,
            monotonicOffset: nextMonotonicOffset(),
            event: event
        )
        eventContinuation.yield(envelope)
    }

    private func recordDecision(
        input: PlaybackDecisionInput,
        source: PlaybackSource?,
        operation: PlaybackOperationID?,
        identities: PlaybackIdentityContext,
        before: PlaybackTransportState,
        effects: [PlaybackEffectSummary],
        result: PlaybackDecisionResult,
        reason: PlaybackReasonCode
    ) async {
        guard configuration.diagnostics.enabled else { return }
        journalSequence &+= 1
        let capacity = configuration.diagnostics.capacity
        guard capacity > 0 else {
            journalDroppedCount &+= 1
            return
        }
        let after = currentSnapshot.transport
        journal.append(PlaybackDecisionRecord(
            sequence: journalSequence,
            monotonicOffset: nextMonotonicOffset(),
            session: sessionID,
            source: source?.id,
            operation: operation,
            identities: identities,
            generation: source?.authority.generation ?? 0,
            input: input,
            transition: before == after ? nil : PlaybackStateTransition(from: before, to: after),
            effects: effects,
            result: result,
            reason: reason
        ))
        if journal.count > capacity {
            let evicted = journal.count - capacity
            journal.removeFirst(evicted)
            journalDroppedCount &+= UInt64(evicted)
        }
    }

    private func nextMonotonicOffset() -> Duration {
        let candidate = clock.now()
        if candidate > lastMonotonicOffset {
            lastMonotonicOffset = candidate
        }
        return lastMonotonicOffset
    }

    // MARK: - Identity and validation

    private func nextOperation() -> PlaybackOperationID {
        operationSerial &+= 1
        let operation = PlaybackOperationID(rawValue: "\(sessionID.rawValue):operation-\(operationSerial)")
        lastIssuedOperation = operation
        return operation
    }

    private func nextEnvironmentEventID(
        for event: PlaybackEnvironmentEvent
    ) -> (PlaybackEnvironmentEventID, UInt64) {
        environmentSerial &+= 1
        let kind = event.kind
        var supersedesPrevious = true
        if case let .applicationPhaseChanged(_, epoch) = event {
            if epoch.rawValue < (highestApplicationEpochSeen ?? 0) {
                supersedesPrevious = false
            } else if epoch.rawValue > (highestApplicationEpochSeen ?? 0) {
                highestApplicationEpochSeen = epoch.rawValue
            }
        }
        if supersedesPrevious {
            latestEnvironmentSerials[kind] = environmentSerial
        }
        return (
            PlaybackEnvironmentEventID(rawValue: "\(sessionID.rawValue):environment-\(environmentSerial)"),
            environmentSerial
        )
    }

    private func isCurrent(
        operation: PlaybackOperationID,
        source: PlaybackSource?,
        identities: PlaybackIdentityContext? = nil,
        includePictureInPictureBinding: Bool = false
    ) -> Bool {
        guard currentSnapshot.currentOperation == operation,
              currentSource?.id == source?.id,
              currentSource?.authority == source?.authority else {
            return false
        }
        guard let identities else { return true }
        guard currentSnapshot.identities.ownerLease == identities.ownerLease,
              currentSnapshot.identities.lifecycleEpoch == identities.lifecycleEpoch else {
            return false
        }
        if includePictureInPictureBinding {
            return currentSnapshot.identities.pictureInPictureBinding
                == identities.pictureInPictureBinding
        }
        return true
    }

    private func staleOrSupersededResult(
        for operation: PlaybackOperationID,
        source: PlaybackSource?,
        identities: PlaybackIdentityContext,
        includePictureInPictureBinding: Bool = false
    ) -> PlaybackCommandResult {
        if isCurrent(
            operation: operation,
            source: source,
            identities: identities,
            includePictureInPictureBinding: includePictureInPictureBinding
        ) {
            return .rejected(operation: operation, reason: .stale)
        }
        return supersededResult(for: operation)
    }

    private func supersededResult(for operation: PlaybackOperationID) -> PlaybackCommandResult {
        guard let successor = currentSnapshot.currentOperation ?? lastIssuedOperation,
              successor != operation else {
            return .rejected(operation: operation, reason: .stale)
        }
        return .superseded(operation: operation, by: successor)
    }

    private func isValid(source: PlaybackSource) -> Bool {
        guard !source.id.rawValue.isEmpty,
              source.startPosition.isFinite,
              source.startPosition >= 0,
              valid(duration: source.duration),
              startPositionIsWithinDuration(source) else {
            return false
        }
        switch source.kind {
        case .onDemand:
            guard !isLive(source.duration) else { return false }
            return networkInput(source.input)
        case .live:
            guard !isFinite(source.duration), source.startPosition == 0 else { return false }
            return networkInput(source.input)
        case .offline:
            guard !isLive(source.duration) else { return false }
            return localInput(source.input)
        }
    }

    private func valid(duration: PlaybackDuration) -> Bool {
        guard case let .finite(value) = duration else { return true }
        return value.isFinite && value >= 0
    }

    private func startPositionIsWithinDuration(_ source: PlaybackSource) -> Bool {
        guard case let .finite(duration) = source.duration else { return true }
        return source.startPosition <= duration
    }

    private func isLive(_ duration: PlaybackDuration) -> Bool {
        if case .live = duration { return true }
        return false
    }

    private func isFinite(_ duration: PlaybackDuration) -> Bool {
        if case .finite = duration { return true }
        return false
    }

    private func networkInput(_ input: PlaybackInput) -> Bool {
        switch input {
        case let .split(video, audio):
            return network(resource: video) && (audio.map(network(resource:)) ?? true)
        case let .muxed(resource):
            return network(resource: resource)
        case .local:
            return false
        }
    }

    private func localInput(_ input: PlaybackInput) -> Bool {
        switch input {
        case let .split(video, audio):
            return file(resource: video) && (audio.map(file(resource:)) ?? true)
        case let .muxed(resource), let .local(resource):
            return file(resource: resource)
        }
    }

    private func network(resource: MediaResource) -> Bool {
        guard !resource.url.isFileURL,
              let scheme = resource.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              resource.url.host != nil else {
            return false
        }
        return true
    }

    private func file(resource: MediaResource) -> Bool {
        resource.url.isFileURL && !resource.url.path.isEmpty
    }

    private var canPlay: Bool {
        switch currentSnapshot.transport {
        case .ready, .buffering:
            return true
        case let .failed(failure):
            return failure == .runtime(.mediaServicesReset)
                && currentSnapshot.suppression == .mediaServicesUnavailable
        case .idle, .opening, .ended, .closed:
            return false
        }
    }

    private var canPause: Bool {
        switch currentSnapshot.transport {
        case .ready, .buffering:
            return true
        case .idle, .opening, .ended, .closed, .failed:
            return currentSnapshot.intent == .playing
        }
    }

    private var videoStateForPlaying: PlaybackVideoLaneState {
        if currentSnapshot.presentation.proof != nil { return .presenting }
        if currentSnapshot.presentation.surface != nil { return .waitingForSurface }
        return .parked
    }

    private func decisionResult(for result: PlaybackCommandResult) -> PlaybackDecisionResult {
        switch result {
        case .accepted: return .accepted
        case .rejected: return .rejected
        case .superseded: return .superseded
        case .failed: return .failed
        }
    }

    private func reasonCode(for rejection: PlaybackRejection) -> PlaybackReasonCode {
        switch rejection {
        case .invalidSource: return .invalidSource
        case .invalidRate, .invalidSeek: return .invalidValue
        case .invalidState, .noPictureInPictureBinding: return .invalidState
        case .noSource: return .rejected
        case .unsupported: return .unsupported
        case .closed: return .closed
        case .stale: return .stale
        }
    }

    private func reasonCode(for failure: PlaybackFailure) -> PlaybackReasonCode {
        switch failure {
        case .engineUnavailable: return .engineUnavailable
        case .closed: return .closed
        case .invalidSource: return .invalidSource
        case .invalidRate, .invalidSeek: return .invalidValue
        case .unsupported: return .unsupported
        case .runtime(.mediaServicesReset): return .mediaServicesReset
        case .runtime: return .runtimeFailure
        }
    }
}
