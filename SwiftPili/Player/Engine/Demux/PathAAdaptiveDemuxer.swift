import Foundation
import os

actor PathAAdaptiveDemuxer: MediaDemuxing {
    private let makeChild: (@Sendable (MediaOpenRequest) -> any MediaDemuxing)?
    private let session: URLSession?
    private let byteStore: MediaByteRangeStore?
    private let displayEvidence =
        OSAllocatedUnfairLock<(any MediaDisplayEvidenceQuerying)?>(initialState: nil)
    private var active: (any MediaDemuxing)?
    private var activeGeneration: UInt64 = 0
    private var openedChildGeneration: UInt64?
    private var multiConnectionQuiet = false

    init(
        session: URLSession? = nil, byteStore: MediaByteRangeStore? = PathAByteCacheSwitch.vodStore,
        makeChild: (@Sendable (MediaOpenRequest) -> any MediaDemuxing)? = nil
    ) {
        self.makeChild = makeChild
        self.session = session
        self.byteStore = byteStore
    }

    var duration: TimeInterval {
        get async { await active?.duration ?? 0 }
    }

    var isEOF: Bool {
        get async { await active?.isEOF ?? true }
    }

    var providesAudioTrack: Bool {
        get async { await active?.providesAudioTrack ?? false }
    }

    var videoContinuityTopology: MediaVideoContinuityTopology {
        get async { await active?.videoContinuityTopology ?? .unsupported }
    }

    private func child(for request: MediaOpenRequest) -> any MediaDemuxing {
        if let makeChild { return makeChild(request) }
        guard let kind = request.liveSource?.kind else {
            if request.videoURL.pathExtension.lowercased() == "m3u8" {
                return PathAHLSFMP4Demuxer(session: session)
            }
            return PathAFMP4Demuxer(byteStore: byteStore)
        }
        switch kind {
        case .hlsFMP4: return PathAHLSFMP4Demuxer(session: session)
        case .progressiveFMP4: return PathAFMP4Demuxer(byteStore: byteStore)
        case .hlsMPEGTS, .httpFLV: return DemandLibavformatDemuxer(kind: kind)
        }
    }

    func open(_ request: MediaOpenRequest) async throws {
        let demux = child(for: request)
        activeGeneration &+= 1
        if activeGeneration == 0 { activeGeneration = 1 }
        let childGeneration = activeGeneration
        let previous = active
        openedChildGeneration = nil
        active = demux
        displayEvidence.withLock { $0 = nil }
        await previous?.close()
        guard activeGeneration == childGeneration, active === demux else { throw CancellationError() }
        await demux.setPacketRelay(packetRelay)
        await demux.setMultiConnectionQuiet(multiConnectionQuiet)
        do {
            try Task.checkCancellation()
            guard activeGeneration == childGeneration, active === demux else { throw CancellationError() }
            try await demux.open(request)
            try Task.checkCancellation()
            guard activeGeneration == childGeneration, active === demux else { throw CancellationError() }
            openedChildGeneration = childGeneration
            displayEvidence.withLock { $0 = demux.displayEvidenceQuery }
        } catch {
            guard !Task.isCancelled, activeGeneration == childGeneration, active === demux else {
                throw CancellationError()
            }
            displayEvidence.withLock { $0 = nil }
            if let source = request.liveSource, source.kind == .hlsMPEGTS || source.kind == .httpFLV,
               let engineError = error as? MediaEngineError,
               case .notImplemented(let diagnostic) = engineError {
                throw MediaEngineError.unsupportedLiveSource(
                    source, ownerGeneration: request.ownerGeneration, diagnostic: diagnostic
                )
            }
            throw error
        }
    }

    private var packetRelay: DemuxPacketRelay?

    func setPacketRelay(_ relay: DemuxPacketRelay?) async {
        packetRelay = relay
        await active?.setPacketRelay(relay)
    }

    func pump(contentBudget: TimeInterval) async throws -> [MediaPacket] {
        guard let active else { throw MediaEngineError.stopped }
        return try await active.pump(contentBudget: contentBudget)
    }

    func pump(videoBudget: TimeInterval, audioBudget: TimeInterval) async throws -> [MediaPacket] {
        guard let active else { throw MediaEngineError.stopped }
        return try await active.pump(videoBudget: videoBudget, audioBudget: audioBudget)
    }

    func pump(
        videoBudget: TimeInterval, audioBudget: TimeInterval,
        sourceWaitBudget: MediaSourceWaitBudget?
    ) async throws -> [MediaPacket] {
        guard let active else { throw MediaEngineError.stopped }
        return try await active.pump(
            videoBudget: videoBudget, audioBudget: audioBudget,
            sourceWaitBudget: sourceWaitBudget
        )
    }

    func seek(to mediaTime: TimeInterval) async throws {
        guard let active else { throw MediaEngineError.stopped }
        try await active.seek(to: mediaTime)
    }

    func prepareVideoContinuity(at mediaTime: TimeInterval) async throws -> Bool {
        guard let active else { throw MediaEngineError.stopped }
        return try await active.prepareVideoContinuity(at: mediaTime)
    }

    func prepareForwardVideoContinuity(
        _ request: MediaVideoForwardRequest
    ) async throws -> MediaVideoForwardOutcome {
        guard let active else { return .notSelected }
        return try await active.prepareForwardVideoContinuity(request)
    }

    func prepareEarlierVideoContinuity(
        before excludedAnchorPTS: TimeInterval
    ) async throws -> Bool {
        guard let active else { throw MediaEngineError.stopped }
        return try await active.prepareEarlierVideoContinuity(
            before: excludedAnchorPTS
        )
    }

    func pumpPositionedVideoContinuity(
        readGeneration: UInt64,
        contentBudget: TimeInterval
    ) async throws -> MediaVideoContinuityBatchOutcome {
        guard let active else { return .unsupported(.unavailable) }
        return try await active.pumpPositionedVideoContinuity(
            readGeneration: readGeneration,
            contentBudget: contentBudget
        )
    }

    func retireLiveStreams() async {
        await active?.retireLiveStreams()
    }

    func interruptActiveIO() async -> MediaDemuxIOInterruptResult {
        guard let child = active else { return .unsupported }
        let childGeneration = activeGeneration
        let result = await child.interruptActiveIO()
        guard activeGeneration == childGeneration,
              let current = active,
              current === child else {
            return .noActiveOperation
        }
        return result
    }

    nonisolated var measuresCachedContentAhead: Bool { byteStore != nil }

    nonisolated var displayEvidenceQuery: (any MediaDisplayEvidenceQuerying)? {
        displayEvidence.withLock { $0 }
    }

    func multiConnectionTelemetry() async -> MultiConnectionTelemetry {
        guard let child = active else { return .unsupported }
        let childGeneration = activeGeneration
        let result = await child.multiConnectionTelemetry()
        guard activeGeneration == childGeneration, let current = active, current === child else {
            return .unsupported
        }
        return result
    }

    func retireResidentDisplay(video: Bool, audio: Bool) async {
        guard let child = active else { return }
        await child.retireResidentDisplay(video: video, audio: audio)
    }

    func cachedContentAhead() async -> MediaCachedContentAhead {
        guard let child = active else { return .empty }
        let childGeneration = activeGeneration
        let result = await child.cachedContentAhead()
        guard activeGeneration == childGeneration, let current = active, current === child else {
            return .empty
        }
        return result
    }

    func setMultiConnectionQuiet(_ quiet: Bool) async {
        multiConnectionQuiet = quiet
        await active?.setMultiConnectionQuiet(quiet)
    }

    func updateMultiConnectionPlayback(position: TimeInterval, rate: Float) async {
        await active?.updateMultiConnectionPlayback(position: position, rate: rate)
    }

    func cancelMultiConnectionPrefetching() async {
        await active?.cancelMultiConnectionPrefetching()
    }

    func close() async {
        guard let active else { return }
        activeGeneration &+= 1
        if activeGeneration == 0 { activeGeneration = 1 }
        let childGeneration = activeGeneration
        openedChildGeneration = nil
        displayEvidence.withLock { $0 = nil }
        await active.close()
        guard activeGeneration == childGeneration,
              let current = self.active,
              current === active else {
            return
        }
        self.active = nil
        displayEvidence.withLock { $0 = nil }
    }

    func videoTrackConfiguration() async -> MediaVideoTrackConfiguration? {
        let childGeneration = activeGeneration
        guard openedChildGeneration == childGeneration, let child = active else { return nil }
        let configuration = await child.videoTrackConfiguration()
        guard activeGeneration == childGeneration, active === child, !Task.isCancelled else {
            return nil
        }
        return configuration
    }

    func codec(for kind: MediaTrackKind) async -> String? {
        await active?.codec(for: kind)
    }

    func formatConfig(for kind: MediaTrackKind) async -> Data {
        await active?.formatConfig(for: kind) ?? Data()
    }
}
