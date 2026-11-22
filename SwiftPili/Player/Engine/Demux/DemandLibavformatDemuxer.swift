import CLiveMediaDemux
import Foundation

/// Owns publication for the selected muxed live input. A retired operation
/// may finish a native call, but it cannot publish into a successor.
actor DemandLibavformatDemuxer: MediaDemuxing {
    static var isAvailable: Bool {
        mld_format_available(Int32(MLD_TS)) != 0 && mld_format_available(Int32(MLD_FLV)) != 0
    }

    private let kind: DemandLiveSourceKind
    private var active: DemandLibavformatOperation?
    private var tracks: DemandLibavformatOperation.Tracks?
    private var terminalFailure: MediaEngineError?
    private var reading = false
    private(set) var isEOF = false

    init(kind: DemandLiveSourceKind) { self.kind = kind }

    var duration: TimeInterval { 0 }
    var providesAudioTrack: Bool { tracks != nil }
    var videoContinuityTopology: MediaVideoContinuityTopology { .muxedCurrentGOP }

    func videoTrackConfiguration() async -> MediaVideoTrackConfiguration? {
        tracks?.video
    }

    func codec(for kind: MediaTrackKind) -> String? {
        guard let tracks else { return nil }
        return kind == .video ? tracks.video.codec : "mp4a"
    }

    func formatConfig(for kind: MediaTrackKind) -> Data {
        guard let tracks else { return Data() }
        return kind == .video ? tracks.video.config : tracks.audio
    }

    func open(_ request: MediaOpenRequest) async throws {
        let operation = DemandLibavformatOperation(
            kind: kind, source: try DemandLiveByteSourceFactory.make(kind: kind, request: request)
        )
        let previous = replaceActive(with: operation)
        await previous?.close()
        do {
            try Task.checkCancellation()
            guard active === operation else { throw MediaEngineError.stopped }
            let description = try await withTaskCancellationHandler {
                try await operation.open()
            } onCancel: {
                operation.cancel()
            }
            try Task.checkCancellation()
            guard active === operation else { throw MediaEngineError.stopped }
            tracks = description
            PlayerLog.log("[PathA:libavformat] opened kind=\(kind.rawValue) video=avc1 audio=mp4a")
        } catch {
            let wasCurrent = active === operation
            if wasCurrent { _ = replaceActive(with: nil) }
            await operation.close()
            guard wasCurrent else { throw MediaEngineError.stopped }
            throw error
        }
    }

    func pump(contentBudget: TimeInterval) async throws -> [MediaPacket] {
        guard contentBudget > 0, !isEOF else { return [] }
        try Task.checkCancellation()
        if let terminalFailure { throw terminalFailure }
        guard tracks != nil, let operation = active, !reading else { throw MediaEngineError.stopped }
        reading = true
        // Return the complete access unit before issuing another potentially
        // blocking read. The session owns per-track residuals for muxed sources.
        // A cooperative fill handoff still ingests this in-flight result.
        let result = await operation.next()
        guard active === operation else { throw MediaEngineError.stopped }
        reading = false
        switch result {
        case .success(let packet):
            isEOF = packet == nil
            return packet.map { [$0] } ?? []
        case .failure(let error):
            // A broken native cursor cannot make progress on another pump.
            // The session's terminal-input path settles current playback.
            let failure: MediaEngineError
            if case .demuxFailed(let diagnostic) = error, error.demuxFailureKind == nil {
                failure = .liveInputRejected(diagnostic)
            } else {
                failure = error
            }
            terminalFailure = failure
            throw failure
        }
    }

    // The source has one serial HTTP cursor and no range prefetch helpers.
    func setMultiConnectionQuiet(_: Bool) async {}
    func updateMultiConnectionPlayback(position _: TimeInterval, rate _: Float) async {}
    func cancelMultiConnectionPrefetching() async {}

    func seek(to _: TimeInterval) async throws {
        throw MediaEngineError.notImplemented("libavformat live input is not seekable")
    }

    // A custom AVIO interruption is terminal. The default local interrupt
    // result is unsupported so warm video recovery cannot kill live audio.
    func close() async {
        let previous = replaceActive(with: nil)
        await previous?.close()
    }

    private func replaceActive(with next: DemandLibavformatOperation?) -> DemandLibavformatOperation? {
        let previous = active
        active = next
        tracks = nil
        reading = false
        isEOF = false
        terminalFailure = nil
        previous?.cancel()
        return previous
    }
}

/// A per-open serial worker owns the C pointer, callback errors and byte
/// cursor. Only cancellation crosses the queue. Its lock guards the flag,
/// and the byte source wakes and cancels its exact in-flight transfer.
private final class DemandLibavformatOperation: @unchecked Sendable {
    struct Tracks: Sendable {
        let video: MediaVideoTrackConfiguration
        let audio: Data
    }

    private let queue = DispatchQueue(label: "SwiftPili.demand.libavformat", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private let kind: DemandLiveSourceKind
    private let source: any DemandLiveByteSource
    private var cancelled = false
    private var context: OpaquePointer?
    private var readError: MediaEngineError?

    init(kind: DemandLiveSourceKind, source: any DemandLiveByteSource) {
        self.kind = kind
        self.source = source
    }

    deinit {
        // Queued calls retain this owner until they have returned from C.
        source.cancel()
        if let context { mld_destroy(context) }
    }

    func cancel() {
        cancellationLock.withLock { cancelled = true }
        source.cancel()
    }

    func close() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async {
                self.destroyContext()
                continuation.resume()
            }
        }
    }

    func open() async throws -> Tracks {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.openOnWorker())
                } catch {
                    self.cancel()
                    self.destroyContext()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func next() async -> Result<MediaPacket?, MediaEngineError> {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = self.readPacket()
                // EOF and failures are terminal. Release the network body and
                // native probe storage even if the session stays on this item.
                switch result {
                case .success(.some): break
                case .success(.none), .failure:
                    self.cancel()
                    self.destroyContext()
                }
                continuation.resume(returning: result)
            }
        }
    }

    private var isCancelled: Bool { cancellationLock.withLock { cancelled } }

    private func destroyContext() {
        if let context { mld_destroy(context) }
        context = nil
    }

    private func openOnWorker() throws -> Tracks {
        guard !isCancelled else { throw MediaEngineError.stopped }
        let format = kind == .hlsMPEGTS ? MLD_TS : MLD_FLV
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let context = mld_create(Int32(format), opaque, { opaque, output, size, remainingMicroseconds in
            guard let opaque, let output, size > 0 else { return -1 }
            return Unmanaged<DemandLibavformatOperation>.fromOpaque(opaque).takeUnretainedValue()
                .readBytes(into: output, maximum: Int(size), timeLimit: Int(remainingMicroseconds))
        }, { opaque in
            guard let opaque else { return 1 }
            return Unmanaged<DemandLibavformatOperation>.fromOpaque(opaque).takeUnretainedValue()
                .isCancelled ? 1 : 0
        }) else {
            throw MediaEngineError.demuxFailed("libavformat context allocation failed")
        }
        self.context = context
        let status = mld_open(context)
        guard !isCancelled, status == MLD_OK else { throw failure(status, opening: true) }
        return try Tracks(
            video: MediaVideoTrackConfiguration(
                codec: "avc1", config: config(context, kind: Int32(MLD_VIDEO), codec: Int32(MLD_AVC)),
                codedDimensions: nil
            ),
            audio: config(context, kind: Int32(MLD_AUDIO), codec: Int32(MLD_AAC))
        )
    }

    private func config(_ context: OpaquePointer, kind: Int32, codec: Int32) throws -> Data {
        var track = MLDTrack()
        guard mld_track(context, kind, &track) == MLD_OK, track.codec == codec,
              let bytes = track.config, track.config_size > 0 else {
            throw MediaEngineError.notImplemented("libavformat live codec configuration unavailable")
        }
        return Data(bytes: bytes, count: Int(track.config_size))
    }

    private func readBytes(into output: UnsafeMutablePointer<UInt8>, maximum: Int, timeLimit: Int) -> Int32 {
        guard !isCancelled else { return -2 }
        do {
            let deadline = DispatchTime.now() + .microseconds(timeLimit)
            guard let bytes = try source.read(maximumBytes: maximum, deadline: deadline) else { return 0 }
            guard !bytes.isEmpty, bytes.count <= maximum else {
                throw MediaEngineError.demuxFailed("libavformat invalid AVIO read length")
            }
            bytes.copyBytes(to: output, count: bytes.count)
            return Int32(bytes.count)
        } catch {
            if isCancelled { return -2 }
            readError = (error as? MediaEngineError) ?? .demuxFailed("libavformat AVIO read failed")
            return -1
        }
    }

    private func readPacket() -> Result<MediaPacket?, MediaEngineError> {
        guard !isCancelled, let context else { return .failure(.stopped) }
        var packet = MLDPacket()
        let status = mld_next(context, &packet)
        guard !isCancelled else { return .failure(.stopped) }
        if status == MLD_EOF, readError == nil { return .success(nil) }
        guard status == MLD_OK else { return .failure(failure(status, opening: false)) }
        let isVideo = packet.kind == MLD_VIDEO
        let dts = packet.dts.isFinite ? packet.dts : nil
        // AAC has no presentation reordering. AVC may reorder, so an absent
        // PTS cannot be replaced by its DTS without changing display order.
        let pts = packet.pts.isFinite ? packet.pts : (isVideo ? nil : dts)
        guard isVideo || packet.kind == MLD_AUDIO,
              let pts, let bytes = packet.data, packet.size > 0 else {
            return .failure(.demuxFailed("libavformat packet missing timing or payload"))
        }
        return .success(MediaPacket(
            track: isVideo ? .video : .audio,
            pts: pts, dts: dts,
            duration: packet.duration.isFinite && packet.duration > 0 ? packet.duration : 0,
            data: Data(bytes: bytes, count: Int(packet.size)),
            isKeyframe: packet.is_key != 0,
            emittedAt: .now
        ))
    }

    private func failure(_ status: Int32, opening: Bool) -> MediaEngineError {
        if isCancelled || status == MLD_INTERRUPTED { return .stopped }
        if let readError {
            if !opening, case .unsupportedLiveSource = readError {
                return .demuxFailed(MediaEngineError.liveMapChangedReloadRequiredDiagnostic)
            }
            return readError
        }
        if status == MLD_RELOAD {
            return .demuxFailed(MediaEngineError.liveMapChangedReloadRequiredDiagnostic)
        }
        if status == MLD_UNSUPPORTED {
            return opening ? .notImplemented("libavformat live AVC/AAC admission refused")
                : .demuxFailed("libavformat live track changed format")
        }
        if status == MLD_EOF { return .demuxFailed("libavformat input ended before track admission") }
        return .demuxFailed(opening ? "libavformat live probe failed" : "libavformat live packet read failed")
    }
}
