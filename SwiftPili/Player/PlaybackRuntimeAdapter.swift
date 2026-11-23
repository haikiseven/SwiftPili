import Foundation
import PiliPlayerEngine

@MainActor
final class PlayerBackendPlaybackRuntimeAdapter: PlaybackRuntime {
    struct LoadDefaults: Sendable {
        let hardwareDecode: Bool
        let networkCaching: TimeInterval
        let maxBuffer: TimeInterval
        let preferNativeVideoToolbox: Bool

        init(
            hardwareDecode: Bool = true,
            networkCaching: TimeInterval = 2,
            maxBuffer: TimeInterval = 30,
            preferNativeVideoToolbox: Bool = true
        ) {
            self.hardwareDecode = hardwareDecode
            self.networkCaching = networkCaching
            self.maxBuffer = maxBuffer
            self.preferNativeVideoToolbox = preferNativeVideoToolbox
        }
    }

    nonisolated let availability: PlaybackRuntimeAvailability
    nonisolated let runtimeEvents: AsyncStream<PlaybackRuntimeEvent>

    private let backend: (any PlayerBackend)?
    private let loadDefaults: LoadDefaults
    private let eventContinuation: AsyncStream<PlaybackRuntimeEvent>.Continuation
    private var currentSourceKind: PlaybackSourceKind?
    private var pendingOpenContinuation: CheckedContinuation<PlaybackRuntimeDecision, Never>?
    private var pendingSeekContinuation: CheckedContinuation<PlaybackRuntimeDecision, Never>?
    private var isClosed = false

    init(
        backend: (any PlayerBackend)?,
        loadDefaults: LoadDefaults = .init()
    ) {
        self.backend = backend
        self.loadDefaults = loadDefaults
        self.availability = backend == nil ? .unavailable : .available
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackRuntimeEvent.self)
        self.runtimeEvents = stream
        self.eventContinuation = continuation
        if let backend {
            bindCallbacks(to: backend)
        }
    }

    isolated deinit {
        pendingOpenContinuation?.resume(returning: .unavailable)
        pendingOpenContinuation = nil
        pendingSeekContinuation?.resume(returning: .unavailable)
        pendingSeekContinuation = nil
        unbindCallbacks()
        eventContinuation.finish()
    }

    static func makeSession(
        configuration: PlaybackConfiguration = .init(),
        backend: (any PlayerBackend)?,
        loadDefaults: LoadDefaults = .init()
    ) -> PlaybackSession {
        PlaybackSession(
            configuration: configuration,
            runtime: PlayerBackendPlaybackRuntimeAdapter(
                backend: backend,
                loadDefaults: loadDefaults
            )
        )
    }

    func execute(_ command: PlaybackRuntimeCommand) async -> PlaybackRuntimeDecision {
        guard !isClosed else { return .rejected(.closed) }
        guard let backend else { return .unavailable }

        switch command {
        case let .open(source, configuration):
            return await executeOpen(source: source, configuration: configuration, on: backend)

        case .play:
            backend.play()
            return .accepted

        case .pause:
            backend.pause()
            return .accepted

        case let .seek(time, _):
            return await executeSeek(to: time, on: backend)

        case let .setRate(rate):
            backend.playbackRate = rate
            return .accepted

        case .stop:
            settlePendingOpen(.rejected(.stale))
            settlePendingSeek(.rejected(.stale))
            currentSourceKind = nil
            backend.stop()
            return .accepted

        case let .requestPictureInPicture(request):
            switch request {
            case .start: backend.startPiP()
            case .stop: backend.stopPiP()
            }
            return .accepted

        case .environment:
            return .accepted

        case .close:
            isClosed = true
            settlePendingOpen(.rejected(.closed))
            settlePendingSeek(.rejected(.closed))
            currentSourceKind = nil
            unbindCallbacks()
            backend.stop()
            eventContinuation.finish()
            return .accepted
        }
    }

    private func executeOpen(
        source: PlaybackSource,
        configuration: PlaybackConfiguration,
        on backend: any PlayerBackend
    ) async -> PlaybackRuntimeDecision {
        settlePendingOpen(.rejected(.stale))
        settlePendingSeek(.rejected(.stale))
        currentSourceKind = source.kind

        let resolved = resolvedURLs(for: source.input)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingOpenContinuation = continuation
                backend.load(
                    url: resolved.videoURL,
                    audioURL: resolved.audioURL,
                    headers: resolved.headers,
                    startPosition: source.startPosition,
                    playbackRate: configuration.preferredRate,
                    hardwareDecode: loadDefaults.hardwareDecode,
                    networkCaching: loadDefaults.networkCaching,
                    maxBuffer: loadDefaults.maxBuffer,
                    preferNativeVideoToolbox: loadDefaults.preferNativeVideoToolbox,
                    alternateVideoURLs: [],
                    alternateAudioURLs: [],
                    readAheadSeconds: nil,
                    multiConnectionPolicy: nil,
                    liveSource: nil
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.settlePendingOpen(.unavailable)
            }
        }
    }

    private func executeSeek(
        to time: TimeInterval,
        on backend: any PlayerBackend
    ) async -> PlaybackRuntimeDecision {
        settlePendingSeek(.rejected(.stale))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingSeekContinuation = continuation
                backend.seek(to: time) { [weak self] succeeded in
                    self?.settlePendingSeek(succeeded ? .accepted : .failed(.runtime(.unknown)))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.settlePendingSeek(.unavailable)
            }
        }
    }

    private func bindCallbacks(to backend: any PlayerBackend) {
        backend.onStateChanged = { [weak self] event in
            self?.handleBackendStateEvent(event)
        }
        backend.onTickWithGeneration = { [weak self] currentTime, totalTime, _, _ in
            guard let self, !self.isClosed else { return }
            let duration = self.resolvedDuration(totalTime)
            self.eventContinuation.yield(.progress(mediaTime: currentTime, duration: duration))
        }
        backend.setRuntimeFaultHandler { [weak self] fault in
            guard let self, !self.isClosed else { return }
            let code: PlaybackFailureCode = fault.recoverability.isAutomatic ? .mediaInput : .terminal
            let failure = PlaybackFailure.runtime(code)
            self.settlePendingOpen(.failed(failure))
            self.settlePendingSeek(.failed(failure))
            self.eventContinuation.yield(.failed(failure))
        }
    }

    private func unbindCallbacks() {
        backend?.onStateChanged = nil
        backend?.onTickWithGeneration = nil
        backend?.setRuntimeFaultHandler(nil)
    }

    private func handleBackendStateEvent(_ event: PlayerStateEvent) {
        guard !isClosed else { return }
        switch event {
        case .readyToPlay:
            let duration = backend.flatMap { resolvedDuration($0.duration) }
            if pendingOpenContinuation != nil {
                settlePendingOpen(.accepted)
            }
            eventContinuation.yield(.ready(duration: duration, capabilities: nil))
        case .buffering:
            eventContinuation.yield(.buffering(true))
        case .bufferFinished:
            eventContinuation.yield(.buffering(false))
        case .paused:
            break
        case .playedToTheEnd:
            eventContinuation.yield(.ended)
        case .error:
            let failure = PlaybackFailure.runtime(.mediaInput)
            if pendingOpenContinuation != nil {
                settlePendingOpen(.failed(failure))
            } else {
                eventContinuation.yield(.failed(failure))
            }
        }
    }

    private func settlePendingOpen(_ decision: PlaybackRuntimeDecision) {
        guard let continuation = pendingOpenContinuation else { return }
        pendingOpenContinuation = nil
        continuation.resume(returning: decision)
    }

    private func settlePendingSeek(_ decision: PlaybackRuntimeDecision) {
        guard let continuation = pendingSeekContinuation else { return }
        pendingSeekContinuation = nil
        continuation.resume(returning: decision)
    }

    private func resolvedURLs(
        for input: PlaybackInput
    ) -> (videoURL: URL, audioURL: URL?, headers: [String: String]) {
        switch input {
        case let .split(video, audio):
            return (video.url, audio?.url, video.headers)
        case let .muxed(resource), let .local(resource):
            return (resource.url, nil, resource.headers)
        }
    }

    private func resolvedDuration(_ rawDuration: TimeInterval) -> PlaybackDuration? {
        if currentSourceKind == .live {
            return .live
        }
        guard rawDuration.isFinite, rawDuration > 0 else { return nil }
        return .finite(rawDuration)
    }
}
