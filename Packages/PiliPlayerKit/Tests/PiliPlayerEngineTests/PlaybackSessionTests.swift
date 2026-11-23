import Foundation
import Testing
@testable import PiliPlayerEngine

@MainActor
private final class MockPlaybackMonotonicClock: PlaybackMonotonicClock {
    private var current: Duration

    init(initial: Duration = .zero) {
        self.current = initial
    }

    func advance(by delta: Duration) {
        current += delta
    }

    func now() -> Duration {
        current
    }
}

private final class MockPlaybackRuntime: PlaybackRuntime, @unchecked Sendable {
    private let lock = NSLock()
    let availability: PlaybackRuntimeAvailability
    let runtimeEvents: AsyncStream<PlaybackRuntimeEvent>
    private let continuation: AsyncStream<PlaybackRuntimeEvent>.Continuation

    private(set) var recordedCommands: [PlaybackRuntimeCommand] = []
    private var openGate: CheckedContinuation<PlaybackRuntimeDecision, Never>?
    private var seekGates: [CheckedContinuation<PlaybackRuntimeDecision, Never>] = []
    private var scriptedOpenDecision: PlaybackRuntimeDecision = .accepted
    private var scriptedRateDecision: PlaybackRuntimeDecision = .accepted
    private var holdOpen = false
    private var holdSeek = false

    init(availability: PlaybackRuntimeAvailability = .available) {
        self.availability = availability
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackRuntimeEvent.self)
        self.runtimeEvents = stream
        self.continuation = continuation
    }

    func setOpenBehavior(hold: Bool = false, decision: PlaybackRuntimeDecision = .accepted) {
        lock.withLock {
            holdOpen = hold
            scriptedOpenDecision = decision
        }
    }

    func setSeekBehavior(hold: Bool) {
        lock.withLock {
            holdSeek = hold
        }
    }

    func setRateDecision(_ decision: PlaybackRuntimeDecision) {
        lock.withLock {
            scriptedRateDecision = decision
        }
    }

    func emit(_ event: PlaybackRuntimeEvent) {
        continuation.yield(event)
    }

    func finishEvents() {
        continuation.finish()
    }

    func resumePendingOpen(with decision: PlaybackRuntimeDecision) {
        let gate = lock.withLock { () -> CheckedContinuation<PlaybackRuntimeDecision, Never>? in
            let current = openGate
            openGate = nil
            return current
        }
        gate?.resume(returning: decision)
    }

    func pendingSeekCount() -> Int {
        lock.withLock { seekGates.count }
    }

    func resumeNextSeek(with decision: PlaybackRuntimeDecision) {
        let gate = lock.withLock { () -> CheckedContinuation<PlaybackRuntimeDecision, Never>? in
            guard !seekGates.isEmpty else { return nil }
            return seekGates.removeFirst()
        }
        gate?.resume(returning: decision)
    }

    func execute(_ command: PlaybackRuntimeCommand) async -> PlaybackRuntimeDecision {
        lock.withLock {
            recordedCommands.append(command)
        }
        switch command {
        case .open:
            let shouldHold = lock.withLock { holdOpen }
            if shouldHold {
                return await withCheckedContinuation { continuation in
                    lock.withLock { openGate = continuation }
                }
            }
            return lock.withLock { scriptedOpenDecision }

        case .seek:
            let shouldHold = lock.withLock { holdSeek }
            if shouldHold {
                return await withCheckedContinuation { continuation in
                    lock.withLock { seekGates.append(continuation) }
                }
            }
            return .accepted

        case .setRate:
            return lock.withLock { scriptedRateDecision }

        case .play, .pause, .stop, .requestPictureInPicture, .environment, .close:
            return .accepted
        }
    }
}

private func makeVODSource(id: String = "vod-1", generation: UInt64 = 1) -> PlaybackSource {
    PlaybackSource(
        id: PlaybackSourceID(rawValue: id),
        authority: PlaybackAuthority(generation: generation),
        kind: .onDemand,
        duration: .finite(100),
        input: .muxed(MediaResource(url: URL(string: "https://example.com/video.mp4")!)),
        startPosition: 0
    )
}

@MainActor
private func waitUntil(
    maxAttempts: Int = 200,
    condition: () -> Bool
) async {
    for _ in 0..<maxAttempts {
        if condition() { return }
        await Task.yield()
    }
}

@Suite("PlaybackSession Runtime Contract Tests")
struct PlaybackSessionTests {
    @Test("Default initializer uses UnavailablePlaybackRuntime")
    @MainActor
    func defaultUnavailableRuntimeBehavior() async {
        let session = PlaybackSession()
        let source = makeVODSource()

        let openResult = await session.open(source)
        guard case let .failed(_, failure) = openResult else {
            Issue.record("Expected open to fail with engineUnavailable, got \(openResult)")
            return
        }
        #expect(failure == .engineUnavailable)
        #expect(session.snapshot.transport == .idle)
        #expect(session.snapshot.suppression == .resourceUnavailable)

        let playResult = await session.play()
        #expect(
            {
                if case .failed(_, .engineUnavailable) = playResult { return true }
                return false
            }()
        )
    }

    @Test("Full lifecycle: open -> ready -> play -> pause -> seek -> setRate -> events -> close")
    @MainActor
    func fullPlaybackLifecycleWithMockRuntime() async {
        let runtime = MockPlaybackRuntime()
        let clock = MockPlaybackMonotonicClock()
        let config = PlaybackConfiguration(
            autoplay: false,
            preferredRate: 1.0,
            backgroundAudioEnabled: true,
            pictureInPictureEnabled: true,
            diagnostics: PlaybackDiagnosticsConfiguration(enabled: true, capacity: 64)
        )
        let session = PlaybackSession(configuration: config, runtime: runtime, clock: clock)
        let source = makeVODSource()

        clock.advance(by: .milliseconds(10))
        let openResult = await session.open(source)
        guard case .accepted = openResult else {
            Issue.record("Expected open to succeed, got \(openResult)")
            return
        }
        #expect(session.snapshot.transport == .ready)
        #expect(session.snapshot.intent == .stopped)
        #expect(session.snapshot.capabilities.contains(.seeking))
        #expect(session.snapshot.capabilities.contains(.playbackRate))
        #expect(session.snapshot.capabilities.contains(.pictureInPicture))

        let playResult = await session.play()
        guard case .accepted = playResult else {
            Issue.record("Expected play to succeed, got \(playResult)")
            return
        }
        #expect(session.snapshot.intent == .playing)
        #expect(session.snapshot.audio == .active)

        let pauseResult = await session.pause()
        guard case .accepted = pauseResult else {
            Issue.record("Expected pause to succeed, got \(pauseResult)")
            return
        }
        #expect(session.snapshot.intent == .pausedByUser)
        #expect(session.snapshot.audio == .parked)

        let seekResult = await session.seek(to: 35.5, mode: .fast)
        guard case .accepted = seekResult else {
            Issue.record("Expected seek to succeed, got \(seekResult)")
            return
        }
        #expect(session.snapshot.mediaTime == 35.5)

        let rateResult = await session.setRate(2.0)
        guard case .accepted = rateResult else {
            Issue.record("Expected setRate to succeed, got \(rateResult)")
            return
        }
        #expect(session.snapshot.rate == 2.0)

        let invalidRateResult = await session.setRate(0)
        guard case .rejected(_, .invalidRate) = invalidRateResult else {
            Issue.record("Expected invalid rate rejection, got \(invalidRateResult)")
            return
        }

        // Reverse async runtime events advance snapshot
        runtime.emit(.ready(duration: .finite(240), capabilities: [.seeking, .playbackRate]))
        await waitUntil { session.snapshot.duration == .finite(240) }
        #expect(session.snapshot.duration == .finite(240))

        runtime.emit(.buffering(true))
        await waitUntil { session.snapshot.transport == .buffering }
        #expect(session.snapshot.transport == .buffering)

        runtime.emit(.progress(mediaTime: 88.25, duration: .finite(245)))
        runtime.emit(.buffering(false))
        await waitUntil { session.snapshot.transport == .ready }
        #expect(session.snapshot.mediaTime == 88.25)
        #expect(session.snapshot.duration == .finite(245))

        runtime.emit(.ended)
        await waitUntil { session.snapshot.transport == .ended }
        #expect(session.snapshot.transport == .ended)
        #expect(session.snapshot.intent == .stopped)

        let closeResult = await session.close()
        guard case .accepted = closeResult else {
            Issue.record("Expected close to succeed, got \(closeResult)")
            return
        }
        #expect(session.snapshot.transport == .closed)

        // Late runtime events after close must not mutate closed snapshot
        runtime.emit(.buffering(true))
        await Task.yield()
        #expect(session.snapshot.transport == .closed)

        let postClosePlay = await session.play()
        guard case .rejected(_, .closed) = postClosePlay else {
            Issue.record("Expected post-close play rejection, got \(postClosePlay)")
            return
        }

        // Verify payloads sent to runtime
        #expect(runtime.recordedCommands == [
            .open(source: source, configuration: config),
            .play,
            .pause,
            .seek(to: 35.5, mode: .fast),
            .setRate(2.0),
            .close,
        ])
        #expect(session.decisionJournal().records.isEmpty == false)
    }

    @Test("Consecutive seeks supersede the earlier in-flight seek")
    @MainActor
    func consecutiveSeekSupersedesEarlierSeek() async {
        let runtime = MockPlaybackRuntime()
        let session = PlaybackSession(runtime: runtime)
        let source = makeVODSource()

        _ = await session.open(source)
        runtime.setSeekBehavior(hold: true)

        async let firstSeek = session.seek(to: 20, mode: .accurate)
        await waitUntil { runtime.pendingSeekCount() == 1 }

        async let secondSeek = session.seek(to: 60, mode: .fast)
        await waitUntil { runtime.pendingSeekCount() == 2 }

        let firstResult = await firstSeek
        guard case let .superseded(op1, by: op2) = firstResult else {
            Issue.record("Expected first seek to be superseded, got \(firstResult)")
            return
        }
        #expect(op1 != op2)

        // Complete first stale seek gate, then second active seek gate
        runtime.resumeNextSeek(with: .accepted)
        await Task.yield()
        #expect(session.snapshot.mediaTime == 0)

        runtime.resumeNextSeek(with: .accepted)
        let secondResult = await secondSeek
        guard case let .accepted(acceptedOp) = secondResult else {
            Issue.record("Expected second seek to succeed, got \(secondResult)")
            return
        }
        #expect(acceptedOp == op2)
        #expect(session.snapshot.mediaTime == 60)
    }

    @Test("Runtime failure during active seek and open settles cleanly")
    @MainActor
    func runtimeFailureAndStopFlow() async {
        let runtime = MockPlaybackRuntime()
        let session = PlaybackSession(runtime: runtime)
        let source = makeVODSource()

        _ = await session.open(source)
        _ = await session.play()
        runtime.setSeekBehavior(hold: true)

        async let pendingSeek = session.seek(to: 45)
        await waitUntil { runtime.pendingSeekCount() == 1 }

        runtime.emit(.failed(.runtime(.mediaServicesReset)))
        let seekResult = await pendingSeek
        guard case let .failed(_, failure) = seekResult else {
            Issue.record("Expected seek to fail on runtime error, got \(seekResult)")
            return
        }
        #expect(failure == .runtime(.mediaServicesReset))
        #expect(session.snapshot.transport == .failed(.runtime(.mediaServicesReset)))
        #expect(session.snapshot.suppression == .mediaServicesUnavailable)
        #expect(session.snapshot.audio == .failed(.runtime(.mediaServicesReset)))
        #expect(session.snapshot.video == .failed(.runtime(.mediaServicesReset)))

        let stopResult = await session.stop(reason: .user)
        guard case .accepted = stopResult else {
            Issue.record("Expected stop to succeed, got \(stopResult)")
            return
        }
        #expect(session.snapshot.transport == .idle)
        #expect(session.snapshot.source == nil)
        #expect(runtime.recordedCommands.contains(.stop(reason: .user)))
    }
}
