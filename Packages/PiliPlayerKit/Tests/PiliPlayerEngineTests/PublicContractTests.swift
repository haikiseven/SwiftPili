import Foundation
import Testing
import PiliPlayerEngine

private final class PublicClock: PlaybackMonotonicClock {
    @MainActor func now() -> Duration {
        .milliseconds(42)
    }
}

private final class PublicMockRuntime: PlaybackRuntime, @unchecked Sendable {
    let availability: PlaybackRuntimeAvailability = .available
    let runtimeEvents: AsyncStream<PlaybackRuntimeEvent>
    private let continuation: AsyncStream<PlaybackRuntimeEvent>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackRuntimeEvent.self)
        self.runtimeEvents = stream
        self.continuation = continuation
    }

    func execute(_ command: PlaybackRuntimeCommand) async -> PlaybackRuntimeDecision {
        switch command {
        case .open:
            return .acceptedWithCapabilities([.seeking, .playbackRate])
        case .play, .pause, .seek, .setRate, .stop, .requestPictureInPicture, .environment, .close:
            return .accepted
        }
    }

    func emit(_ event: PlaybackRuntimeEvent) {
        continuation.yield(event)
    }
}

@Suite("Public PiliPlayerEngine Contract Tests")
struct PublicContractTests {
    @Test("External module can implement PlaybackRuntime and PlaybackMonotonicClock without @testable")
    @MainActor
    func externalModuleCanInjectPublicRuntimeAndClock() async {
        let runtime = PublicMockRuntime()
        let clock = PublicClock()
        let systemClock = SystemPlaybackMonotonicClock()
        let unavailable = UnavailablePlaybackRuntime()
        #expect(unavailable.availability == .unavailable)
        #expect(systemClock.now() >= .zero)

        let session = PlaybackSession(
            configuration: PlaybackConfiguration(autoplay: true, preferredRate: 1.5),
            runtime: runtime,
            clock: clock
        )
        let source = PlaybackSource(
            id: PlaybackSourceID(rawValue: "pub-1"),
            authority: PlaybackAuthority(generation: 1),
            kind: .onDemand,
            duration: .finite(60),
            input: .muxed(MediaResource(url: URL(string: "https://example.com/pub.mp4")!))
        )

        let openResult = await session.open(source)
        guard case .accepted = openResult else {
            Issue.record("Expected accepted open result, got \(openResult)")
            return
        }
        #expect(session.snapshot.transport == .ready)
        #expect(session.snapshot.intent == .playing)
        #expect(session.snapshot.rate == 1.5)

        runtime.emit(.progress(mediaTime: 12, duration: .finite(65)))
        runtime.emit(.ended)
        for _ in 0..<200 where session.snapshot.transport != .ended {
            await Task.yield()
        }
        #expect(session.snapshot.mediaTime == 12)
        #expect(session.snapshot.duration == .finite(65))
        #expect(session.snapshot.transport == .ended)

        _ = await session.close()
    }
}
