import Foundation

actor PathAHLSFMP4Demuxer: MediaDemuxing {
    func multiConnectionTelemetry() async -> MultiConnectionTelemetry { .unsupported }
    func setMultiConnectionQuiet(_ quiet: Bool) async {}
    func updateMultiConnectionPlayback(position: TimeInterval, rate: Float) async {}
    func cancelMultiConnectionPrefetching() async {}

    private let session: URLSession
    private var generation: UInt64 = 0
    private var inFlightRequest: PathAHLSInFlightRequest?
    private var playlistURL: URL?
    private var headers: [String: String] = [:]
    private var networkBytes: MediaNetworkByteCounter?
    private var tracks: [PathAFMP4.TrackInfo] = []
    private var audioConfiguration: PathACodecConfig.AACConfiguration?
    private var audioTimingResolution: PathAFMP4.AudioTimingResolution?
    private var audioTimingMismatchLogged = false
    private var segmentWindow = PathAHLSSegmentWindow()
    private var activeMapURL: URL?
    private var timestampOrigin: TimeInterval?
    private var targetDuration: TimeInterval = 1
    private var nextRefreshUptime: TimeInterval = 0
    private var endListSeen = false
    private var closed = true
    private var latchedParseFailure: MediaEngineError?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    var duration: TimeInterval { 0 }
    var isEOF: Bool { endListSeen && segmentWindow.pending.isEmpty }
    var providesAudioTrack: Bool { tracks.contains { $0.kind == .audio } }
    var videoContinuityTopology: MediaVideoContinuityTopology { .muxedCurrentGOP }

    func videoTrackConfiguration() async -> MediaVideoTrackConfiguration? {
        track(for: .video)?.videoTrackConfiguration
    }

    func codec(for kind: MediaTrackKind) async -> String? {
        track(for: kind)?.codec
    }

    func formatConfig(for kind: MediaTrackKind) async -> Data {
        track(for: kind)?.config ?? Data()
    }

    func open(_ request: MediaOpenRequest) async throws {
        guard request.audioURL == nil else {
            throw MediaEngineError.demuxFailed("HLS live: separate audio URL unsupported")
        }

        let replacement = beginReplacement()
        if let request = replacement.request {
            await request.waitForCompletion()
        }
        guard generation == replacement.generation else {
            throw MediaEngineError.stopped
        }

        closed = false
        playlistURL = request.videoURL
        headers = request.headers
        networkBytes = request.networkByteCounter

        let playlist = try await fetchPlaylist(generation: replacement.generation)
        guard isCurrent(replacement.generation) else {
            throw MediaEngineError.stopped
        }
        activeMapURL = playlist.mapURL
        let initData = try await load(
            playlist.mapURL,
            stage: "map",
            generation: replacement.generation
        )
        guard isCurrent(replacement.generation) else {
            throw MediaEngineError.stopped
        }
        let movie: PathAFMP4.MovieInfo
        switch PathAFMP4.parseMovieResult(initData) {
        case .success(let parsed): movie = parsed
        case .needMoreData(let required):
            throw MediaEngineError.demuxFailed(
                "HLS map: fMP4 moov needs more data bytes=\(max(0, required))"
            )
        case .malformed(let failure):
            throw MediaEngineError.demuxFailed("HLS map: fMP4 malformed \(failure.summary)")
        case .unsupported(let unsupported):
            throw MediaEngineError.demuxFailed("HLS map: fMP4 unsupported \(unsupported.summary)")
        }
        guard movie.tracks.contains(where: { $0.kind == .video }) else {
            throw MediaEngineError.demuxFailed("HLS map: moov/video track missing")
        }
        tracks = movie.tracks
        if let audioTrack = tracks.first(where: { $0.kind == .audio }) {
            audioConfiguration = PathACodecConfig.aacConfiguration(
                fromESDSOrASC: audioTrack.config
            )
            if let audioConfiguration {
                PlayerLog.log(
                    "[PathA:HLS] AAC config aot=\(audioConfiguration.audioObjectType) " +
                    "coreAOT=\(audioConfiguration.coreAudioObjectType) " +
                    "core=\(Int(audioConfiguration.coreSampleRate))Hz " +
                    "ext=\(audioConfiguration.extensionSampleRate.map { String(Int($0)) } ?? "none")Hz " +
                    "out=\(Int(audioConfiguration.outputSampleRate))Hz " +
                    "sbr=\(audioConfiguration.sbrPresent ? 1 : 0) " +
                    "ps=\(audioConfiguration.psPresent ? 1 : 0) " +
                    "ch=\(audioConfiguration.channels) au=\(audioConfiguration.frameLength) " +
                    "trackSR=\(Int(audioTrack.sampleRate.rounded()))Hz"
                )
            }
        }
        apply(playlist)

        let codecs = tracks.map { "\($0.kind.rawValue)=\($0.codec)" }.joined(separator: ",")
        PlayerLog.log(
            "[PathA:HLS] open host=\(request.videoURL.host ?? "?") " +
            "seq=\(playlist.mediaSequence) window=\(playlist.segments.count) " +
            "target=\(String(format: "%.1f", targetDuration))s " +
            "map=\(playlist.mapURL.lastPathComponent) tracks=\(codecs)"
        )
    }

    func pump(contentBudget: TimeInterval) async throws -> [MediaPacket] {
        _ = contentBudget
        guard !closed else { throw MediaEngineError.stopped }
        if let latchedParseFailure {
            throw latchedParseFailure
        }
        let pumpGeneration = generation
        if segmentWindow.pending.isEmpty, !endListSeen {
            guard ProcessInfo.processInfo.systemUptime >= nextRefreshUptime else { return [] }
            let playlist = try await fetchPlaylist(generation: pumpGeneration)
            guard isCurrent(pumpGeneration) else {
                throw MediaEngineError.stopped
            }
            guard playlist.mapURL == activeMapURL else {
                throw MediaEngineError.demuxFailed("HLS map changed; live reload required")
            }
            let enqueued = apply(playlist)
            PlayerLog.log(
                "[PathA:HLS] refresh seq=\(playlist.mediaSequence) " +
                "window=\(playlist.segments.count) new=\(enqueued)"
            )
        }
        guard isCurrent(pumpGeneration) else {
            throw MediaEngineError.stopped
        }
        guard let segment = segmentWindow.firstPending() else { return [] }

        do {
            let data = try await load(
                segment.url,
                stage: "segment",
                generation: pumpGeneration
            )
            guard isCurrent(pumpGeneration) else {
                throw MediaEngineError.stopped
            }
            let packetized: [(sample: PathAFMP4.Sample, data: Data)]
            switch PathAFMP4.packetizeResult(
                segment: data,
                segmentByteOffset: 0,
                tracks: tracks
            ) {
            case .success(let parsed): packetized = parsed
            case .needMoreData(let required):
                throw PathAFMP4.ParseError.needMoreData(requiredBytes: required)
            case .malformed(let failure):
                throw PathAFMP4.ParseError.malformed(failure)
            case .unsupported(let unsupported):
                throw PathAFMP4.ParseError.unsupported(unsupported)
            }
            guard !packetized.isEmpty else {
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .packetize, field: "media", reason: "no_moof"
                ))
            }
            if let audioConfiguration,
               let audioTrack = tracks.first(where: { $0.kind == .audio }) {
                let audioDurations = packetized.compactMap { sample, _ in
                    sample.trackID == audioTrack.trackID ? sample.durationTicks : nil
                }
                if !audioDurations.isEmpty {
                        guard let resolved = PathAFMP4.resolveAudioTiming(
                        declaredTimescale: audioTrack.timescale,
                        codecSampleRate: audioConfiguration.coreSampleRate,
                        framesPerAccessUnit: audioConfiguration.frameLength,
                        sampleDurations: audioDurations,
                        containerSampleRate: audioTrack.sampleRate
                        ) else {
                            throw MediaEngineError.demuxFailed(
                                "HLS AAC sample durations are unstable for ASC core rate=" +
                                "\(Int(audioConfiguration.coreSampleRate))Hz " +
                                "timescale=\(audioTrack.timescale)"
                            )
                    }
                    if let audioTimingResolution {
                        guard abs(audioTimingResolution.effectiveTimescale - resolved.effectiveTimescale) <= 0.5 else {
                            throw MediaEngineError.demuxFailed("HLS AAC timing changed effective timescale")
                        }
                    } else {
                        self.audioTimingResolution = resolved
                    }
                    if resolved.timingMismatch, !audioTimingMismatchLogged {
                        audioTimingMismatchLogged = true
                        PlayerLog.diagnostic(
                            "[PathA:HLS] AAC timing mismatch keepsMP4TS=\(resolved.declaredTimescale) " +
                            "effectiveTS=\(String(format: "%.3f", resolved.effectiveTimescale)) " +
                            "codec=\(Int(resolved.codecSampleRate))Hz " +
                            "rawAU=\(String(format: "%.6f", resolved.observedDurationSeconds))s " +
                            "ascAU=\(String(format: "%.6f", resolved.expectedDurationSeconds))s " +
                            "trackSR=\(Int(audioTrack.sampleRate.rounded()))Hz"
                        )
                    }
                }
            }
            let audioTimescale = audioTimingResolution?.effectiveTimescale
            var packets: [MediaPacket] = []
            packets.reserveCapacity(packetized.count)
            for (sample, bytes) in packetized {
                guard let track = tracks.first(where: { $0.trackID == sample.trackID }) else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .packetize, trackID: sample.trackID,
                        field: "trackID", reason: "unknown"
                    ))
                }
                let timescale = track.kind == .audio
                    ? (audioTimescale ?? Double(max(track.timescale, 1)))
                    : Double(max(track.timescale, 1))
                packets.append(MediaPacket(
                    track: track.kind == .video ? .video : .audio,
                    pts: Double(sample.ptsTicks) / timescale,
                    dts: Double(sample.dtsTicks) / timescale,
                    duration: Double(sample.durationTicks) / timescale,
                    data: bytes,
                    isKeyframe: sample.isKeyframe,
                    audioTiming: track.kind == .audio ? MediaAudioPacketTiming(
                        ptsTicks: sample.ptsTicks,
                        dtsTicks: sample.dtsTicks,
                        durationTicks: sample.durationTicks,
                        trackTimescale: track.timescale,
                        effectiveTimescale: timescale
                    ) : nil,
                    containerSampleIndex: sample.sampleIndex,
                    containerFragmentSequence: sample.fragmentSequence,
                    containerSampleOffset: sample.offset
                ))
            }
            guard !packets.isEmpty else {
                throw MediaEngineError.demuxFailed(
                    "HLS segment \(segment.sequence): no packetizable media"
                )
            }

            let previousOrigin = timestampOrigin
            packets = PathAHLSTimeline.normalize(packets, origin: &timestampOrigin)
            if previousOrigin == nil, let timestampOrigin {
                PlayerLog.log(
                    "[PathA:HLS] timeline origin=\(String(format: "%.3f", timestampOrigin))s"
                )
            }
            packets.sort {
                let lhs = $0.dts ?? $0.pts
                let rhs = $1.dts ?? $1.pts
                if abs(lhs - rhs) > 1e-9 { return lhs < rhs }
                return $0.track == .audio && $1.track == .video
            }
            guard segmentWindow.commitFirst(segment) else {
                throw MediaEngineError.stopped
            }
            PlayerLog.log(
                "[PathA:HLS] segment-commit gen=\(pumpGeneration) "
                    + "sequence=\(segment.sequence) pkts=\(packets.count)"
            )
            return packets
        } catch {
            guard isCurrent(pumpGeneration) else {
                throw MediaEngineError.stopped
            }
            if let parserError = error as? PathAFMP4.ParseError {
                let mapped = Self.mediaError(for: parserError, context: "HLS segment")
                latchedParseFailure = mapped
                throw mapped
            }
            if let mediaError = error as? MediaEngineError,
               case .stopped = mediaError {
                throw mediaError
            }
            segmentWindow.retry(segment)
            if let mediaError = error as? MediaEngineError { throw mediaError }
            throw MediaEngineError.demuxFailed(
                "HLS segment \(segment.sequence): \(error.localizedDescription)"
            )
        }
    }

    func seek(to mediaTime: TimeInterval) async throws {
        _ = mediaTime
        throw MediaEngineError.notImplemented("live HLS is not seekable")
    }

    func pumpPositionedVideoContinuity(
        readGeneration: UInt64,
        contentBudget: TimeInterval
    ) async throws -> MediaVideoContinuityBatchOutcome {
        _ = readGeneration
        _ = contentBudget
        return .unsupported(.topology)
    }

    func close() async {
        let replacement = beginReplacement()
        if let request = replacement.request {
            await request.waitForCompletion()
        }
        guard generation == replacement.generation else { return }
        reset()
    }

    private func fetchPlaylist(generation: UInt64) async throws -> PathAHLSPlaylist {
        guard isCurrent(generation), let playlistURL else {
            throw MediaEngineError.stopped
        }
        let data = try await load(playlistURL, stage: "playlist", generation: generation)
        guard isCurrent(generation) else {
            throw MediaEngineError.stopped
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MediaEngineError.demuxFailed("HLS playlist: invalid UTF-8")
        }
        return try PathAHLSPlaylist.parse(text, relativeTo: playlistURL)
    }

    private func load(
        _ url: URL,
        stage: String,
        generation: UInt64
    ) async throws -> Data {
        guard isCurrent(generation) else { throw MediaEngineError.stopped }
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let counter = networkBytes
        let responseLimit: Int
        switch stage {
        case "playlist": responseLimit = PathAHLSPlaylist.maxPlaylistBytes
        case "map": responseLimit = 2 * 1024 * 1024
        default: responseLimit = PathAFMP4.maxPacketizedBytes
        }
        let inFlight = PathAHLSInFlightRequest(generation: generation)
        let task = MediaNetworkDataTask.makeTask(
            session: session, request: request, policy: .complete(maximumBytes: responseLimit), counter: counter
        ) {
            inFlight.finish($0)
        }
        inFlight.install(task)
        self.inFlightRequest = inFlight
        task.resume()
        defer {
            if self.inFlightRequest === inFlight {
                self.inFlightRequest = nil
            }
            inFlight.markComplete()
        }

        do {
            let result = try await withTaskCancellationHandler(operation: {
                try await inFlight.value()
            }, onCancel: {
                inFlight.cancel()
            })
            guard isCurrent(generation) else { throw MediaEngineError.stopped }
            guard let http = result.response as? HTTPURLResponse else {
                throw MediaEngineError.demuxFailed("HLS \(stage): non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MediaEngineError.demuxFailed("HLS \(stage): HTTP \(http.statusCode)")
            }
            guard result.data.count <= responseLimit else {
                throw MediaEngineError.demuxFailed(
                    "HLS \(stage): response exceeds bound"
                )
            }
            return result.data
        } catch {
            if Self.isCancellation(error) || !isCurrent(generation) {
                throw MediaEngineError.stopped
            }
            if let mediaError = error as? MediaEngineError {
                throw mediaError
            }
            throw MediaEngineError.demuxFailed(
                "HLS \(stage): \(error.localizedDescription)"
            )
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    @discardableResult
    private func apply(_ playlist: PathAHLSPlaylist) -> Int {
        targetDuration = playlist.targetDuration
        endListSeen = playlist.isEndList
        let enqueued = segmentWindow.apply(playlist)
        nextRefreshUptime = ProcessInfo.processInfo.systemUptime
            + max(0.25, min(targetDuration * 0.5, 2))
        return enqueued
    }

    private func track(for kind: MediaTrackKind) -> PathAFMP4.TrackInfo? {
        tracks.first { $0.kind.rawValue == kind.rawValue }
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        !closed && generation == candidate
    }

    private static func mediaError(
        for error: PathAFMP4.ParseError,
        context: String
    ) -> MediaEngineError {
        switch error {
        case .needMoreData(let requiredBytes):
            return .demuxFailed(
                "\(context) needs more data (bytes=\(max(0, requiredBytes)))"
            )
        case .malformed(let failure):
            return .demuxFailed("\(context) malformed: \(failure.summary)")
        case .unsupported(let unsupported):
            return .demuxFailed("\(context) unsupported: \(unsupported.summary)")
        }
    }

    private func beginReplacement() -> (
        generation: UInt64,
        request: PathAHLSInFlightRequest?
    ) {
        generation &+= 1
        closed = true
        let request = inFlightRequest
        inFlightRequest = nil
        reset()
        request?.cancel()
        return (generation, request)
    }

    private func reset() {
        playlistURL = nil
        headers = [:]
        networkBytes = nil
        tracks = []
        audioConfiguration = nil
        audioTimingResolution = nil
        audioTimingMismatchLogged = false
        latchedParseFailure = nil
        segmentWindow = PathAHLSSegmentWindow()
        activeMapURL = nil
        timestampOrigin = nil
        targetDuration = 1
        nextRefreshUptime = 0
        endListSeen = false
        closed = true
    }
}
