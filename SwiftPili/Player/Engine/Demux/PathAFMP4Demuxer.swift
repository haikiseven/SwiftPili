import Foundation

actor PathAFMP4Demuxer: MediaDemuxing {
    nonisolated let displayAvailability = MediaDisplayAvailability()

    private struct ResidentDisplayOwnership: Sendable {
        let nextOffset: Int
        let leases: [MediaDisplayLease]
    }

    private var futureDisplayLeases: [MediaTrackKind: [Int64: ResidentDisplayOwnership]] = [:]
    private var residentDisplayChanges: MediaByteRangeStore.ResidentChanges?
    private var residentDisplayRefreshTask: Task<Void, Never>?

    private struct FragmentIndexEntry: Sendable {
        let offset: Int
        let startPTS: TimeInterval
        let endPTS: TimeInterval
        let startsWithKeyframe: Bool
    }

    private struct AudioTimingState: Sendable {
        let configuration: PathACodecConfig.AACConfiguration
        let declaredTimescale: UInt32
        let containerSampleRate: Double
        var resolution: PathAFMP4.AudioTimingResolution?
        var timingMismatchLogged = false

        mutating func observe(_ durations: [UInt32]) throws -> PathAFMP4.AudioTimingResolution {
            guard let candidate = PathAFMP4.resolveAudioTiming(
                declaredTimescale: declaredTimescale,
                codecSampleRate: configuration.coreSampleRate,
                framesPerAccessUnit: configuration.frameLength,
                sampleDurations: durations,
                containerSampleRate: containerSampleRate
            ) else {
                throw MediaEngineError.demuxFailed(
                    "AAC sample durations are unstable for ASC core rate=" +
                    "\(Int(configuration.coreSampleRate))Hz " +
                    "timescale=\(declaredTimescale)"
                )
            }
            if let resolution {
                guard abs(resolution.effectiveTimescale - candidate.effectiveTimescale) <= 0.5 else {
                    throw MediaEngineError.demuxFailed(
                        "AAC timing changed effective timescale " +
                        "from \(String(format: "%.3f", resolution.effectiveTimescale)) " +
                        "to \(String(format: "%.3f", candidate.effectiveTimescale))"
                    )
                }
            } else {
                resolution = candidate
            }
            return resolution ?? candidate
        }
    }

    private struct ParsedDisplayFragment: Sendable {
        let bytes: Range<Int64>
        let metadataResidency: MediaByteRangeStore.ResidentValidity
        let lower: TimeInterval
        let upper: TimeInterval
    }

    private struct TrackReader: Sendable {
        let source: PathAHTTPMediaSource
        let track: PathAFMP4.TrackInfo
        let mediaStart: Int
        let endByte: Int
        var segments: [PathAFMP4.SidxEntry]
        var cursor: Int
        var eof: Bool
        var fragmentIndex: [FragmentIndexEntry]
        var fragmentIndexCursor: Int
        var fragmentIndexComplete: Bool
        var audioTiming: AudioTimingState?
        var requiresExactFragmentTrackID: Bool
        let parallelPumpIdentity: NetworkResourceIdentity?
        let isFileSource: Bool
        var activeFragment: ActiveFragmentStream? = nil
        var armFragmentTrace = true
        var storeBinding: PathAByteStoreBinding?
        var displayUsability = MediaResidentDisplayUsability()
        var parsedDisplayFragment: ParsedDisplayFragment?
        var displayTrack: MediaDisplayTrack?
        var displayResidentBytes: [MediaDisplayLease] = []
    }

    private struct ActiveFragmentStream: Sendable {
        var streamID: UInt64?
        let fragmentStart: Int
        let fragmentTotal: Int
        var assembler: PathAMdatStreamAssembler
        let samples: [PathAFMP4.Sample]
        let effectiveTimescale: Double
        var synthesizedEmitted = 0
        var trace: FragmentStreamTrace?
    }

    private struct FragmentStreamTrace: Sendable {
        let start: ContinuousClock.Instant
        var loggedStreamStart = false
        var loggedFirstByte = false
        var loggedFirstSample = false
        var loggedFirstPacket = false

        func elapsedMs() -> Int {
            Int(start.duration(to: ContinuousClock.now) / .milliseconds(1))
        }
    }

    private struct FragmentReopenBudget: Sendable {
        static let maxBackpressureReopens = 256
        static let maxZeroProgressErrorReopens = 2
        static let maxTotalErrorReopens = 64

        private(set) var lastProgressOffset: Int64
        private(set) var zeroProgressReopens = 0
        private(set) var backpressureReopens = 0
        private(set) var errorReopens = 0

        init(initialOffset: Int64) {
            lastProgressOffset = initialOffset
        }

        mutating func admitBackpressure(resumeOffset: Int64) -> Bool {
            guard backpressureReopens < Self.maxBackpressureReopens else { return false }
            backpressureReopens += 1
            if resumeOffset > lastProgressOffset {
                lastProgressOffset = resumeOffset
                zeroProgressReopens = 0
                return true
            }
            zeroProgressReopens += 1
            return zeroProgressReopens <= 1
        }

        mutating func admitError(currentOffset: Int64) -> Bool {
            guard errorReopens < Self.maxTotalErrorReopens else { return false }
            errorReopens += 1
            if currentOffset > lastProgressOffset {
                lastProgressOffset = currentOffset
                zeroProgressReopens = 0
                return true
            }
            zeroProgressReopens += 1
            return zeroProgressReopens <= Self.maxZeroProgressErrorReopens
        }
    }

    private struct PumpPacing: Sendable {
        let start = ContinuousClock.now
        var netWaits = 0
        var maxNetWaitMs = 0
        var reopens = 0

        mutating func recordWait(since instant: ContinuousClock.Instant) {
            netWaits += 1
            let ms = Int(instant.duration(to: ContinuousClock.now) / .milliseconds(1))
            if ms > maxNetWaitMs { maxNetWaitMs = ms }
        }
    }

    private struct NetworkResourceIdentity: Hashable, Sendable {
        let scheme: String
        let host: String
        let port: Int?
        let path: String

        init?(url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased(),
                  !host.isEmpty else {
                return nil
            }
            self.scheme = scheme
            self.host = host
            switch (scheme, url.port) {
            case ("http", 80), ("https", 443):
                port = nil
            default:
                port = url.port
            }
            path = url.path
        }
    }

    private enum DeferredOpenDiagnostic: Sendable {
        case log(String)
    }

    private enum DeferredPumpDiagnostic: Sendable {
        case synthesizedDuration(count: Int, kind: MediaTrackKind, cursor: Int)
        case audioTimingMismatch(
            resolution: PathAFMP4.AudioTimingResolution,
            containerSampleRate: Double
        )
    }

    private struct TrackPumpResult: Sendable {
        let reader: TrackReader
        let packets: [MediaPacket]
        let diagnostics: [DeferredPumpDiagnostic]
    }

    private enum TaggedTrackPumpResult: Sendable {
        case video(TrackPumpResult)
        case audio(TrackPumpResult)
    }

    private struct RequiredTrackPumpResult: Sendable {
        let video: TrackPumpResult?
        let audio: TrackPumpResult?
    }

    private struct TrackOpenResult: Sendable {
        let reader: TrackReader
        let movieDuration: TimeInterval
        let diagnostics: [DeferredOpenDiagnostic]
    }

    private enum TaggedTrackOpenResult: Sendable {
        case video(TrackOpenResult)
        case audio(TrackOpenResult)
    }

    private struct RequiredTrackOpenResult: Sendable {
        let video: TrackOpenResult
        let audio: TrackOpenResult?
    }

    private enum TaggedInitialPositioningResult: Sendable {
        case video(TrackReader)
        case audio(TrackReader)
    }

    private var video: TrackReader? {
        didSet {
            readerProgressRevision &+= 1
            residentDisplayChanges?.requestRefresh()
        }
    }
    private var audio: TrackReader? {
        didSet {
            readerProgressRevision &+= 1
            residentDisplayChanges?.requestRefresh()
        }
    }
    private var readerProgressRevision: UInt64 = 0
    private var _duration: TimeInterval = 0
    private var _movieDuration: TimeInterval = 0
    private var openGeneration: UInt64 = 0
    private var readerMutationGeneration: UInt64 = 0
    private var activeForwardReceipt: MediaVideoForwardReceipt?
    private var latchedParseFailure: MediaEngineError? {
        didSet {
            if latchedParseFailure != nil { retireDisplayUsability() }
        }
    }

    private func retireDisplayUsability() {
        video?.displayUsability.revoke()
        audio?.displayUsability.revoke()
        video?.displayTrack?.clearLayouts()
        audio?.displayTrack?.clearLayouts()
        futureDisplayLeases.removeAll()
    }

    private func retireDisplayTracks() {
        video?.displayTrack?.retire()
        audio?.displayTrack?.retire()
    }

    private var packetRelay: DemuxPacketRelay?

    func setPacketRelay(_ relay: DemuxPacketRelay?) async {
        packetRelay = relay
    }

    private func commitStreamedProgress(
        kind: MediaTrackKind,
        reader: TrackReader,
        packets: [MediaPacket],
        generation: UInt64,
        relay: DemuxPacketRelay?,
        waitBudget: MediaSourceWaitBudget? = nil
    ) -> Bool {
        guard generation == readerMutationGeneration, !Task.isCancelled,
              waitBudget?.isCancelled != true else { return false }
        let previous = kind == .video ? video : audio
        let fragmentChanged = previous?.cursor != reader.cursor
            || previous?.activeFragment?.fragmentStart != reader.activeFragment?.fragmentStart
        switch kind {
        case .video: video = reader
        case .audio: audio = reader
        }
        relay?.publish(packets, track: kind)
        if fragmentChanged, prefetchSeekGeneration == nil, multiConnectionPrefetcher != nil {
            let generation = openGeneration
            Task { await self.notifyPrimaryTailSplit(generation: generation) }
        }
        return true
    }

    private func isCurrentReaderMutation(_ generation: UInt64) -> Bool {
        generation == readerMutationGeneration
    }
    private let injectedSession: URLSession?
    private let byteStore: MediaByteRangeStore?
    private var activeStorePathsToken: UUID?
    private var multiConnectionPrefetcher: MultiConnectionPrefetcher?
    private var multiConnectionAdmission = MultiConnectionTelemetry.State.notConfigured
    private var prefetchTrackKinds: [MediaTrackKind] = []
    private var multiConnectionQuiet = false
    private var multiConnectionPosition: TimeInterval = 0
    private var multiConnectionRate: Float = 1
    private var prefetchSeekGeneration: UInt64?
    private static let initialHeadBytes = 256 * 1024
    private static let headMaxBytes = 2 * 1024 * 1024
    private static let fragmentProbeBytes = 16 * 1024
    private static let earlierContinuitySidxScanLimit = 32
    private static let maxFragmentIndexEntries = PathAFMP4.maxSidxEntries
    private static let maxDeferredPumpDiagnostics = 512

    init(session: URLSession? = nil, byteStore: MediaByteRangeStore? = nil) {
        injectedSession = session
        self.byteStore = byteStore
    }

    deinit {
        residentDisplayRefreshTask?.cancel()
        residentDisplayChanges?.finish()
        if let store = byteStore, let token = activeStorePathsToken {
            Task { await store.unregisterActivePaths(token) }
        }
    }

    var duration: TimeInterval { _duration }
    var isEOF: Bool { (video?.eof ?? true) && (audio?.eof ?? true) }
    var providesAudioTrack: Bool { audio != nil }

    func videoTrackConfiguration() async -> MediaVideoTrackConfiguration? {
        video?.track.videoTrackConfiguration
    }

    func formatConfig(for kind: MediaTrackKind) async -> Data {
        (kind == .video ? video?.track.config : audio?.track.config) ?? Data()
    }
    func codec(for kind: MediaTrackKind) async -> String? {
        kind == .video ? video?.track.codec : audio?.track.codec
    }

    var videoContinuityTopology: MediaVideoContinuityTopology {
        guard let video else { return .unsupported }
        return video.isFileSource ? .localFileIndex : .splitTrack
    }

    // MARK: - open

    func open(_ request: MediaOpenRequest) async throws {
        openGeneration &+= 1
        stopResidentDisplayObservation()
        let generation = openGeneration
        activeForwardReceipt = nil
        readerMutationGeneration &+= 1
        let readerGeneration = readerMutationGeneration
        retireDisplayUsability()
        retireDisplayTracks()
        await retireOpenPrefetchAndStoreProtection(closeStreams: true, resetReaders: true)
        let loadSession = makeLoadSession()
        var stagedSources: (video: PathAHTTPMediaSource, audio: PathAHTTPMediaSource?)?
        var stagedDisplayTracks: [MediaDisplayTrack] = []

        do {
            let opened = try await Self.openRequiredTracks(
                request: request,
                session: loadSession,
                byteStore: byteStore
            )
            var stagedVideo = opened.video.reader
            var stagedAudio = opened.audio?.reader
            stagedSources = (stagedVideo.source, stagedAudio?.source)
            if let audioURL = request.audioURL,
               Self.sameMediaResource(request.videoURL, audioURL) {
                stagedVideo.requiresExactFragmentTrackID = true
                stagedAudio?.requiresExactFragmentTrackID = true
            }

            try checkOpenFence(generation, readerGeneration: readerGeneration)
            if request.startPosition > 0.5 {
                (stagedVideo, stagedAudio) = try await Self.positionInitialReaders(
                    video: stagedVideo,
                    audio: stagedAudio,
                    at: request.startPosition
                )
            }

            try checkOpenFence(generation, readerGeneration: readerGeneration)

            let movieDuration = max(
                opened.video.movieDuration,
                opened.audio?.movieDuration ?? 0
            )
            let stagedDuration: TimeInterval
            if stagedVideo.segments.isEmpty {
                stagedDuration = movieDuration
            } else {
                var indexedDuration = 0.0
                for segment in stagedVideo.segments {
                    indexedDuration += segment.durationSeconds
                    guard indexedDuration.isFinite else {
                        throw MediaEngineError.demuxFailed("fMP4 sidx duration overflow")
                    }
                }
                stagedDuration = indexedDuration
            }
            if !stagedVideo.isFileSource, !stagedVideo.requiresExactFragmentTrackID,
               stagedVideo.storeBinding != nil, stagedVideo.track.timescale > 0,
               stagedAudio == nil || stagedAudio?.storeBinding != nil {
                stagedVideo.displayTrack = displayAvailability.makeTrack(.video)
                let audioDisplayTrack = stagedAudio?.storeBinding != nil
                    ? displayAvailability.makeTrack(.audio) : nil
                stagedAudio?.displayTrack = audioDisplayTrack
                stagedDisplayTracks = [stagedVideo.displayTrack, audioDisplayTrack].compactMap { $0 }
                await stagedVideo.source.setDisplayTrack(stagedVideo.displayTrack)
                if let stagedAudio { await stagedAudio.source.setDisplayTrack(stagedAudio.displayTrack) }
            }
            try checkOpenFence(generation, readerGeneration: readerGeneration)
            video = stagedVideo
            audio = stagedAudio
            _movieDuration = movieDuration
            _duration = stagedDuration
            publishOpenDiagnostics(
                opened.video.diagnostics + (opened.audio?.diagnostics ?? [])
            )
            try await registerActiveStorePaths(generation: generation, readerGeneration: readerGeneration)
            await openMultiConnectionPrefetcher(request, generation: generation)
            try checkOpenFence(generation, readerGeneration: readerGeneration)
            await startResidentDisplayObservation(generation: generation)
            try checkOpenFence(generation, readerGeneration: readerGeneration)
        } catch {
            if generation == openGeneration { stopResidentDisplayObservation() }
            stagedDisplayTracks.forEach { $0.retire() }
            if let stagedSources {
                await stagedSources.video.closeActiveChunkStream()
                await stagedSources.audio?.closeActiveChunkStream()
            }
            let wasReplaced = generation != openGeneration
                || readerGeneration != readerMutationGeneration
            if !wasReplaced {
                await retireOpenPrefetchAndStoreProtection(closeStreams: false, resetReaders: true)
            }
            if wasReplaced || Task.isCancelled || Self.isCancellation(error) {
                throw MediaEngineError.stopped
            }
            throw error
        }
    }

    private func checkOpenFence(_ generation: UInt64, readerGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard generation == openGeneration,
              readerGeneration == readerMutationGeneration else {
            throw MediaEngineError.stopped
        }
    }

    private static func positionInitialReaders(
        video: TrackReader,
        audio: TrackReader?,
        at target: TimeInterval
    ) async throws -> (video: TrackReader, audio: TrackReader?) {
        if let audio, allowsParallelPump(video: video, audio: audio),
           video.segments.isEmpty, audio.segments.isEmpty {
            return try await withThrowingTaskGroup(of: TaggedInitialPositioningResult.self) { group in
                group.addTask {
                    .video(try await seekReader(video, to: target, kind: "video"))
                }
                group.addTask {
                    .audio(try await seekReader(audio, to: target, kind: "audio"))
                }

                var positionedVideo: TrackReader?
                var positionedAudio: TrackReader?
                do {
                    for try await result in group {
                        switch result {
                        case .video(let reader): positionedVideo = reader
                        case .audio(let reader): positionedAudio = reader
                        }
                    }
                } catch {
                    group.cancelAll()
                    throw error
                }
                guard let positionedVideo, let positionedAudio else {
                    throw MediaEngineError.stopped
                }
                return (positionedVideo, positionedAudio)
            }
        }

        let positionedVideo = try await seekReader(video, to: target, kind: "video")
        let positionedAudio: TrackReader?
        if let audio {
            positionedAudio = try await seekReader(audio, to: target, kind: "audio")
        } else {
            positionedAudio = nil
        }
        return (positionedVideo, positionedAudio)
    }

    private static let sharedLoadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private func makeLoadSession() -> URLSession {
        injectedSession ?? Self.sharedLoadSession
    }

    private static func openRequiredTracks(
        request: MediaOpenRequest,
        session: URLSession,
        byteStore: MediaByteRangeStore?
    ) async throws -> RequiredTrackOpenResult {
        guard let audioURL = request.audioURL else {
            return RequiredTrackOpenResult(
                video: try await openTrack(
                    url: request.videoURL,
                    request: request,
                    want: .video,
                    session: session,
                    byteStore: byteStore
                ),
                audio: nil
            )
        }

        if sameMediaResource(request.videoURL, audioURL) {
            let video = try await openTrack(
                url: request.videoURL,
                request: request,
                want: .video,
                session: session,
                byteStore: byteStore
            )
            let audio = try await openTrack(
                url: audioURL,
                request: request,
                want: .audio,
                session: session,
                byteStore: byteStore
            )
            return RequiredTrackOpenResult(video: video, audio: audio)
        }

        return try await withThrowingTaskGroup(of: TaggedTrackOpenResult.self) { group in
            group.addTask {
                .video(try await openTrack(
                    url: request.videoURL,
                    request: request,
                    want: .video,
                    session: session,
                    byteStore: byteStore
                ))
            }
            group.addTask {
                .audio(try await openTrack(
                    url: audioURL,
                    request: request,
                    want: .audio,
                    session: session,
                    byteStore: byteStore
                ))
            }

            var video: TrackOpenResult?
            var audio: TrackOpenResult?
            do {
                for try await result in group {
                    switch result {
                    case .video(let opened): video = opened
                    case .audio(let opened): audio = opened
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }
            guard let video else {
                throw MediaEngineError.demuxFailed("no video track")
            }
            guard let audio else {
                throw MediaEngineError.demuxFailed("no audio track")
            }
            return RequiredTrackOpenResult(video: video, audio: audio)
        }
    }

    private static func openTrack(
        url: URL,
        request: MediaOpenRequest,
        want: MediaTrackKind,
        session: URLSession,
        byteStore: MediaByteRangeStore?
    ) async throws -> TrackOpenResult {
        let selectedIdentity = want == .video
            ? request.videoBootstrapIdentity : request.audioBootstrapIdentity
        let source = PathAHTTPMediaSource(
            url: url,
            headers: request.headers,
            session: session,
            byteStore: byteStore,
            networkBytes: request.networkByteCounter,
            bootstrapIdentity: selectedIdentity?.track == want ? selectedIdentity : nil
        )
        let initial = try await source.initialHead(count: initialHeadBytes)
        let total: Int
        if let contentLength = initial.info.contentLength {
            guard contentLength >= 0,
                  contentLength <= Int64(Int.max) else {
                throw MediaEngineError.demuxFailed("fMP4 resource length overflow")
            }
            total = Int(contentLength)
        } else {
            total = 0
        }
        guard initial.data.count <= Self.initialHeadBytes else {
            throw MediaEngineError.demuxFailed("fMP4 initial head exceeds request")
        }
        var diagnostics: [DeferredOpenDiagnostic] = []

        var head = initial.data
        var movie: PathAFMP4.MovieInfo?
        var headNeedsMoreData = false
        switch PathAFMP4.parseMovieResult(head) {
        case .success(let parsed): movie = parsed
        case .needMoreData: headNeedsMoreData = true
        case .malformed(let failure):
            throw Self.mediaError(for: .malformed(failure), context: "moov")
        case .unsupported(let unsupported):
            throw Self.mediaError(for: .unsupported(unsupported), context: "moov")
        }
        let extendedHeadBytes = total > 0 ? min(headMaxBytes, total) : headMaxBytes
        if headNeedsMoreData, extendedHeadBytes > head.count {
            head = try await source.read(offset: 0, count: extendedHeadBytes)
            guard head.count <= extendedHeadBytes else {
                throw MediaEngineError.demuxFailed("fMP4 extended head exceeds request")
            }
            switch PathAFMP4.parseMovieResult(head) {
            case .success(let parsed): movie = parsed
            case .needMoreData(let required):
                throw Self.mediaError(
                    for: .needMoreData(requiredBytes: required), context: "moov head"
                )
            case .malformed(let failure):
                throw Self.mediaError(for: .malformed(failure), context: "moov")
            case .unsupported(let unsupported):
                throw Self.mediaError(for: .unsupported(unsupported), context: "moov")
            }
        }
        guard let movie else {
            throw MediaEngineError.demuxFailed("fMP4 moov head is incomplete (\(want.rawValue))")
        }
        guard let track = movie.tracks.first(where: { pathAKind($0.kind) == want }) else {
            throw MediaEngineError.demuxFailed("no \(want.rawValue) track in moov")
        }

        let headBoxes: [PathAFMP4.Box]
        switch PathAFMP4.movieHeaderBoxesResult(head) {
        case .success(let boxes): headBoxes = boxes
        case .needMoreData(let required):
            throw Self.mediaError(
                for: .needMoreData(requiredBytes: required), context: "moov head"
            )
        case .malformed(let failure):
            throw Self.mediaError(for: .malformed(failure), context: "moov head")
        case .unsupported(let unsupported):
            throw Self.mediaError(for: .unsupported(unsupported), context: "moov head")
        }
        guard let moovBox = headBoxes.first(where: { $0.type == "moov" }) else {
            throw MediaEngineError.demuxFailed("fMP4 moov box missing (\(want.rawValue))")
        }
        var mediaStart = moovBox.range.upperBound
        var segments: [PathAFMP4.SidxEntry] = []
        if let sidx = headBoxes.first(where: {
            $0.type == "sidx" && $0.range.lowerBound >= mediaStart
        }) {
            let sidxData = head.subdata(in: (head.startIndex + sidx.range.lowerBound)..<(head.startIndex + sidx.range.upperBound))
            switch PathAFMP4.parseSidxResult(
                sidxData, sidxAbsoluteStart: sidx.range.lowerBound
            ) {
            case .success(let parsed): segments = parsed
            case .needMoreData(let required):
                throw Self.mediaError(
                    for: .needMoreData(requiredBytes: required), context: "sidx"
                )
            case .malformed(let failure):
                throw Self.mediaError(for: .malformed(failure), context: "sidx")
            case .unsupported(let unsupported):
                throw Self.mediaError(for: .unsupported(unsupported), context: "sidx")
            }
            if total > 0 {
                for entry in segments {
                    let endResult = entry.offset.addingReportingOverflow(entry.size)
                    guard entry.offset >= 0,
                          !endResult.overflow,
                          endResult.partialValue <= total else {
                        throw MediaEngineError.demuxFailed(
                            "fMP4 sidx reference exceeds resource"
                        )
                    }
                }
            }
            mediaStart = sidx.range.upperBound
        }
        let endByte: Int
        if total > 0 {
            endByte = total
        } else if let last = segments.last {
            let endResult = last.offset.addingReportingOverflow(last.size)
            guard !endResult.overflow else {
                throw MediaEngineError.demuxFailed("fMP4 sidx range overflow")
            }
            endByte = endResult.partialValue
        } else {
            endByte = 0
        }
        let audioTiming: AudioTimingState?
        if want == .audio,
           let configuration = PathACodecConfig.aacConfiguration(fromESDSOrASC: track.config) {
            audioTiming = AudioTimingState(
                configuration: configuration,
                declaredTimescale: track.timescale,
                containerSampleRate: track.sampleRate,
                resolution: nil
            )
            diagnostics.append(.log(
                "[PathA] AAC track config aot=\(configuration.audioObjectType) " +
                "coreAOT=\(configuration.coreAudioObjectType) " +
                "core=\(Int(configuration.coreSampleRate))Hz " +
                "ext=\(configuration.extensionSampleRate.map { String(Int($0)) } ?? "none")Hz " +
                "out=\(Int(configuration.outputSampleRate))Hz " +
                "sbr=\(configuration.sbrPresent ? 1 : 0) " +
                "ps=\(configuration.psPresent ? 1 : 0) " +
                "ch=\(configuration.channels) au=\(configuration.frameLength)"
            ))
        } else {
            audioTiming = nil
        }
        diagnostics.append(.log(
            "[PathA] fMP4 open \(want.rawValue) host=\(url.host ?? "?") " +
            "codec=\(track.codec) ts=\(track.timescale) " +
            (want == .audio ? "trackSR=\(Int(track.sampleRate.rounded())) " : "") +
            "segs=\(segments.count) mediaStart=\(mediaStart) len=\(endByte)"
        ))
        return TrackOpenResult(
            reader: TrackReader(
                source: source,
                track: track,
                mediaStart: mediaStart,
                endByte: endByte,
                segments: segments,
                cursor: mediaStart,
                eof: false,
                fragmentIndex: [],
                fragmentIndexCursor: mediaStart,
                fragmentIndexComplete: false,
                audioTiming: audioTiming,
                requiresExactFragmentTrackID: false,
                parallelPumpIdentity: initial.responseKind == .httpPartial
                    ? NetworkResourceIdentity(url: url)
                    : nil,
                isFileSource: url.isFileURL,
                storeBinding: PathAByteStoreBinding(
                    store: byteStore,
                    url: url,
                    contentLength: initial.info.contentLength
                )
            ),
            movieDuration: movie.durationSeconds,
            diagnostics: diagnostics
        )
    }

    // MARK: - pump

    func pump(contentBudget: TimeInterval) async throws -> [MediaPacket] {
        try await pump(videoBudget: contentBudget, audioBudget: contentBudget)
    }

    func pump(videoBudget: TimeInterval, audioBudget: TimeInterval) async throws -> [MediaPacket] {
        try await pump(videoBudget: videoBudget, audioBudget: audioBudget, sourceWaitBudget: nil)
    }

    func pump(
        videoBudget: TimeInterval, audioBudget: TimeInterval,
        sourceWaitBudget: MediaSourceWaitBudget?
    ) async throws -> [MediaPacket] {
        try Self.checkWaitBudget(sourceWaitBudget)
        if let latchedParseFailure {
            throw latchedParseFailure
        }
        guard videoBudget.isFinite, audioBudget.isFinite else {
            throw MediaEngineError.demuxFailed("fMP4 pump budget is non-finite")
        }
        let pumpVideo = videoBudget > 0.000_5
        let pumpAudio = audioBudget > 0.000_5
        prepareResidentDisplayForPump(video: pumpVideo, audio: pumpAudio)
        let stagedVideo = pumpVideo ? video : nil
        let stagedAudio = pumpAudio ? audio : nil
        guard stagedVideo != nil || stagedAudio != nil else { return [] }

        activeForwardReceipt = nil
        readerMutationGeneration &+= 1
        let generation = readerMutationGeneration
        let relay = packetRelay

        do {
            let result: RequiredTrackPumpResult
            if let stagedVideo,
               let stagedAudio,
               Self.allowsParallelPump(video: stagedVideo, audio: stagedAudio) {
                result = try await Self.pumpTracksConcurrently(
                    video: stagedVideo,
                    audio: stagedAudio,
                    videoBudget: videoBudget,
                    audioBudget: audioBudget,
                    owner: self,
                    generation: generation,
                    relay: relay,
                    waitBudget: sourceWaitBudget
                )
            } else {
                result = try await Self.pumpTracksSerially(
                    video: stagedVideo,
                    audio: stagedAudio,
                    videoBudget: videoBudget,
                    audioBudget: audioBudget,
                    owner: self,
                    generation: generation,
                    relay: relay,
                    waitBudget: sourceWaitBudget
                )
            }

            try checkPumpFence(generation, waitBudget: sourceWaitBudget)

            if let pumpedVideo = result.video { video = pumpedVideo.reader }
            if let pumpedAudio = result.audio { audio = pumpedAudio.reader }
            publish(
                (result.video?.diagnostics ?? [])
                    + (result.audio?.diagnostics ?? [])
            )
            await refreshMultiConnectionCursors()
            try checkPumpFence(generation, waitBudget: sourceWaitBudget)
            return (result.video?.packets ?? []) + (result.audio?.packets ?? [])
        } catch {
            if generation != readerMutationGeneration
                || Task.isCancelled
                || Self.isCancellation(error) {
                throw MediaEngineError.stopped
            }
            stagedVideo?.displayUsability.revoke()
            stagedAudio?.displayUsability.revoke()
            if let parserError = error as? PathAFMP4.ParseError {
                let mapped = Self.mediaError(for: parserError, context: "fragment")
                latchedParseFailure = mapped
                throw mapped
            }
            throw error
        }
    }

    private func checkPumpFence(_ generation: UInt64, waitBudget: MediaSourceWaitBudget?) throws {
        try Self.checkWaitBudget(waitBudget)
        guard generation == readerMutationGeneration else { throw MediaEngineError.stopped }
    }

    private static func allowsParallelPump(
        video: TrackReader,
        audio: TrackReader
    ) -> Bool {
        guard let videoIdentity = video.parallelPumpIdentity,
              let audioIdentity = audio.parallelPumpIdentity else {
            return false
        }
        return videoIdentity != audioIdentity
    }

    private static func sameMediaResource(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs == rhs { return true }
        guard let lhsIdentity = NetworkResourceIdentity(url: lhs),
              let rhsIdentity = NetworkResourceIdentity(url: rhs) else {
            return false
        }
        return lhsIdentity == rhsIdentity
    }

    private static func pumpTracksSerially(
        video: TrackReader?,
        audio: TrackReader?,
        videoBudget: TimeInterval,
        audioBudget: TimeInterval,
        owner: PathAFMP4Demuxer,
        generation: UInt64,
        relay: DemuxPacketRelay?,
        waitBudget: MediaSourceWaitBudget?
    ) async throws -> RequiredTrackPumpResult {
        let pumpedVideo: TrackPumpResult?
        if let video {
            pumpedVideo = try await pump(
                video, budget: videoBudget, owner: owner, generation: generation, relay: relay,
                waitBudget: waitBudget
            )
        } else {
            pumpedVideo = nil
        }
        let pumpedAudio: TrackPumpResult?
        if let audio {
            pumpedAudio = try await pump(
                audio, budget: audioBudget, owner: owner, generation: generation, relay: relay,
                waitBudget: waitBudget
            )
        } else {
            pumpedAudio = nil
        }
        return RequiredTrackPumpResult(video: pumpedVideo, audio: pumpedAudio)
    }

    private static func pumpTracksConcurrently(
        video: TrackReader,
        audio: TrackReader,
        videoBudget: TimeInterval,
        audioBudget: TimeInterval,
        owner: PathAFMP4Demuxer,
        generation: UInt64,
        relay: DemuxPacketRelay?,
        waitBudget: MediaSourceWaitBudget?
    ) async throws -> RequiredTrackPumpResult {
        try await withThrowingTaskGroup(of: TaggedTrackPumpResult.self) { group in
            group.addTask {
                .video(try await pump(
                    video, budget: videoBudget, owner: owner, generation: generation, relay: relay,
                    waitBudget: waitBudget
                ))
            }
            group.addTask {
                .audio(try await pump(
                    audio, budget: audioBudget, owner: owner, generation: generation, relay: relay,
                    waitBudget: waitBudget
                ))
            }

            var pumpedVideo: TrackPumpResult?
            var pumpedAudio: TrackPumpResult?
            do {
                for try await result in group {
                    switch result {
                    case .video(let pumped): pumpedVideo = pumped
                    case .audio(let pumped): pumpedAudio = pumped
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }
            guard let pumpedVideo, let pumpedAudio else {
                throw MediaEngineError.stopped
            }
            return RequiredTrackPumpResult(
                video: pumpedVideo,
                audio: pumpedAudio
            )
        }
    }

    private static func pump(
        _ reader: TrackReader,
        budget: TimeInterval,
        owner: PathAFMP4Demuxer,
        generation: UInt64,
        relay: DemuxPacketRelay?,
        waitBudget: MediaSourceWaitBudget? = nil,
        continuityReferenceEnd: Int? = nil
    ) async throws -> TrackPumpResult {
        var r = reader
        let readEnd = continuityReferenceEnd ?? r.endByte
        let kind = pathAKind(r.track.kind)
        let trackWaitBudget = waitBudget?.forTrack(kind)
        var packets = PacketEmitter(relay: relay, waitBudget: trackWaitBudget)
        var diagnostics: [DeferredPumpDiagnostic] = []
        var produced: TimeInterval = 0
        let ts = Double(r.track.timescale == 0 ? 1 : r.track.timescale)
        var pacing: PumpPacing? = PlayerLog.isCapturing ? PumpPacing() : nil

        while produced < budget || r.activeFragment?.assembler.isComplete == true {
            let displayBytes = r.displayTrack.map(MediaDisplayByteOwner.init)
            defer { displayBytes?.release() }
            try checkWaitBudget(trackWaitBudget)
            if r.eof { break }
            if let continuityReferenceEnd, r.activeFragment == nil,
               r.cursor >= continuityReferenceEnd { break }
            if r.activeFragment != nil {
                _ = try await consumeActiveFragment(
                    &r,
                    packets: &packets,
                    diagnostics: &diagnostics,
                    produced: &produced,
                    budget: budget,
                    kind: kind,
                    pacing: &pacing,
                    owner: owner,
                    generation: generation,
                    relay: relay,
                    waitBudget: trackWaitBudget
                )
                continue
            }
            if readEnd > 0,
               r.cursor > readEnd || readEnd - r.cursor < 8 {
                r.eof = continuityReferenceEnd == nil
                break
            }
            var probeCount = Self.fragmentProbeBytes
            if readEnd > 0 { probeCount = min(probeCount, readEnd - r.cursor) }
            guard probeCount >= 8 else { r.eof = true; break }
            packets.discardReadObservation()
            let probeWaitStart = pacing != nil ? ContinuousClock.now : nil
            let probe = try await r.source.read(
                offset: Int64(r.cursor), count: probeCount, waitBudget: trackWaitBudget, displayOwner: displayBytes
            )
            try checkWaitBudget(trackWaitBudget)
            if let probeWaitStart { pacing?.recordWait(since: probeWaitStart) }
            guard probe.count <= probeCount else {
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .box, field: "readSize", reason: "exceeds_request",
                    availableBytes: probe.count, offset: r.cursor
                ))
            }
            guard let rawHeader = Self.parseBoxHeader(probe, at: 0) else {
                if probe.isEmpty {
                    if readEnd > 0, r.cursor < readEnd { r.displayUsability.revoke() }
                    r.eof = true
                    break
                }
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .box, field: "header", reason: "truncated", offset: r.cursor
                ))
            }
            let header = try Self.resolveBoxHeader(
                rawHeader,
                at: r.cursor,
                containingEnd: readEnd > 0 ? readEnd : nil
            )

            if header.type == "moof" {
                var buffered = Data(probe)
                let moofSize = header.size
                let throughHeaderResult = moofSize.addingReportingOverflow(16)
                guard !throughHeaderResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "size", reason: "overflow"
                    ))
                }
                let throughMdatHeader = throughHeaderResult.partialValue
                if buffered.count < throughMdatHeader {
                    let spillWaitStart = pacing != nil ? ContinuousClock.now : nil
                    let readOffsetResult = r.cursor.addingReportingOverflow(buffered.count)
                    guard !readOffsetResult.overflow else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .fragment, boxType: "moof", field: "readOffset", reason: "overflow"
                        ))
                    }
                    let extra = try await r.source.read(
                        offset: Int64(readOffsetResult.partialValue),
                        count: throughMdatHeader - buffered.count,
                        waitBudget: trackWaitBudget, displayOwner: displayBytes
                    )
                    try checkWaitBudget(trackWaitBudget)
                    if let spillWaitStart { pacing?.recordWait(since: spillWaitStart) }
                    guard extra.count <= throughMdatHeader - buffered.count else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .fragment, boxType: "moof", field: "readSize",
                            reason: "exceeds_request", availableBytes: extra.count
                        ))
                    }
                    buffered.append(extra)
                }
                guard buffered.count >= moofSize else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "size", reason: "truncated"
                    ))
                }
                let mdatStartResult = r.cursor.addingReportingOverflow(moofSize)
                guard !mdatStartResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "end", reason: "overflow"
                    ))
                }
                let mdatStart = mdatStartResult.partialValue
                guard let rawMdatHeader = Self.parseBoxHeader(buffered, at: moofSize) else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "mdat", reason: "missing"
                    ))
                }
                let mdatHeader = try Self.resolveBoxHeader(
                    rawMdatHeader,
                    at: mdatStart,
                    containingEnd: readEnd > 0 ? readEnd : nil
                )
                guard mdatHeader.type == "mdat" else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "mdat", reason: "missing"
                    ))
                }
                guard mdatHeader.size >= 8 else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "mdat", field: "size", reason: "overflow_or_small"
                    ))
                }
                let fragmentTotalResult = moofSize.addingReportingOverflow(mdatHeader.size)
                guard !fragmentTotalResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "mdat", field: "size", reason: "overflow"
                    ))
                }
                let fragmentTotal = fragmentTotalResult.partialValue
                let fragmentEndResult = r.cursor.addingReportingOverflow(fragmentTotal)
                guard !fragmentEndResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "mdat", field: "end", reason: "overflow"
                    ))
                }
                let fragmentEnd = fragmentEndResult.partialValue
                if readEnd > 0, fragmentEnd > readEnd {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "mdat", field: "size", reason: "truncated"
                    ))
                }
                let mdatPayloadStartResult = mdatStart.addingReportingOverflow(mdatHeader.headerLength)
                guard !mdatPayloadStartResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "mdat", field: "payloadStart", reason: "overflow"
                    ))
                }
                let mdatPayloadStart = mdatPayloadStartResult.partialValue
                let consumedEnd = r.cursor + min(buffered.count, fragmentTotal)
                packets.metadataRange = Int64(r.cursor)..<Int64(mdatPayloadStart)
                packets.noteRead(consumedRange: Int64(r.cursor)..<Int64(consumedEnd))
                let parsed: [PathAFMP4.Sample]
                switch PathAFMP4.parseFragmentResult(
                    buffered,
                    segmentByteOffset: r.cursor,
                    moofRange: 0..<moofSize,
                    tracks: [r.track],
                    sampleDataRange: mdatPayloadStart..<fragmentEnd
                ) {
                case .success(let value): parsed = value
                case .needMoreData(let required):
                    throw PathAFMP4.ParseError.needMoreData(requiredBytes: required)
                case .malformed(let failure):
                    throw PathAFMP4.ParseError.malformed(failure)
                case .unsupported(let unsupported):
                    throw PathAFMP4.ParseError.unsupported(unsupported)
                }
                let kept = r.requiresExactFragmentTrackID
                    ? parsed.filter { $0.trackID == r.track.trackID }
                    : parsed
                let emittable = kept
                let timingResolution: PathAFMP4.AudioTimingResolution?
                if kind == .audio, var audioTiming = r.audioTiming, !emittable.isEmpty {
                    let durations = emittable.map(\.durationTicks)
                    let resolved = try audioTiming.observe(durations)
                    r.audioTiming = audioTiming
                    timingResolution = resolved
                    if resolved.timingMismatch, !audioTiming.timingMismatchLogged {
                        audioTiming.timingMismatchLogged = true
                        r.audioTiming = audioTiming
                        if diagnostics.count < maxDeferredPumpDiagnostics {
                            diagnostics.append(
                                .audioTimingMismatch(
                                    resolution: resolved,
                                    containerSampleRate: audioTiming.containerSampleRate
                                )
                            )
                        }
                    }
                } else {
                    timingResolution = nil
                }
                let timescale = timingResolution?.effectiveTimescale ?? ts
                var parsedResidency: MediaByteRangeStore.ResidentValidity?
                if let binding = r.storeBinding, !r.isFileSource {
                    let held = await binding.store.residentRun(
                        binding.key, from: Int64(r.cursor),
                        matchingPrefix: Data(buffered.prefix(mdatPayloadStart - r.cursor))
                    )
                    parsedResidency = held?.validity.narrowed(to: Int64(r.cursor)..<Int64(mdatPayloadStart))
                }
                let displaySamples = Self.displaySamples(
                    emittable, kind: r.track.kind, fragment: r.cursor, timescale: timescale
                )
                r.parsedDisplayFragment = parsedResidency.flatMap { residency in
                    guard r.displayUsability.isValid else { return nil }
                    return Self.parsedDisplayFragment(
                        samples: displaySamples, expectedSampleCount: emittable.count,
                        bytes: Int64(r.cursor)..<Int64(fragmentEnd),
                        declaredTimescale: r.track.timescale, residency: residency
                    )
                }

                r.displayTrack?.install(displaySamples, fragment: Int64(r.cursor))
                if let binding = r.storeBinding, let displayTrack = r.displayTrack {
                    let receipts = await binding.store.displayResidentSpans(
                        binding.key, ranges: displaySamples.map(\.bytes)
                    )
                    r.displayResidentBytes = receipts.compactMap {
                        displayTrack.own(bytes: $0.range, residency: $0)
                    }
                }

                if !r.isFileSource, var liveAssembler = PathAMdatStreamAssembler(
                    samples: emittable.map { ($0.offset, $0.size) },
                    streamStart: r.cursor
                ) {
                    liveAssembler.displayTrack = r.displayTrack
                    liveAssembler.displaySamples = Dictionary(uniqueKeysWithValues: displaySamples.map { ($0.ordinal, $0) })
                    var af = ActiveFragmentStream(
                        streamID: nil,
                        fragmentStart: r.cursor,
                        fragmentTotal: fragmentTotal,
                        assembler: liveAssembler,
                        samples: emittable,
                        effectiveTimescale: timescale
                    )
                    if r.armFragmentTrace {
                        af.trace = FragmentStreamTrace(start: ContinuousClock.now)
                        Self.traceLog(
                            &af, kind: kind,
                            "fragment-metadata-ready samples=\(emittable.count) " +
                            "frag@\(r.cursor) total=\(fragmentTotal)B",
                            elapsed: false
                        )
                    }
                    let initialFeedCount = min(buffered.count, fragmentTotal)
                    let initialFeed = Data(buffered.prefix(initialFeedCount))
                    let emitted = af.assembler.consume(initialFeed)
                    guard !af.assembler.isMalformed else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .fragment, boxType: "mdat", field: "assembler",
                            reason: "cursor_overflow"
                        ))
                    }
                    Self.appendStreamedPackets(
                        emitted, fragment: &af, reader: &r, kind: kind,
                        produced: &produced, packets: &packets
                    )
                    r.activeFragment = af
                    try await commitStreamedStateIfNeeded(
                        reader: r,
                        packets: &packets,
                        kind: kind,
                        owner: owner,
                        generation: generation,
                        relay: relay
                    )
                    continue
                }

                var segment: Data
                if buffered.count >= fragmentTotal {
                    segment = Data(buffered.prefix(fragmentTotal))
                } else {
                    segment = buffered
                    let tailWaitStart = pacing != nil ? ContinuousClock.now : nil
                    let readOffsetResult = r.cursor.addingReportingOverflow(buffered.count)
                    guard !readOffsetResult.overflow else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .fragment, boxType: "mdat", field: "readOffset", reason: "overflow"
                        ))
                    }
                    let tail = try await r.source.read(
                        offset: Int64(readOffsetResult.partialValue),
                        count: fragmentTotal - buffered.count,
                        waitBudget: trackWaitBudget, displayOwner: displayBytes
                    )
                    try checkWaitBudget(trackWaitBudget)
                    if let tailWaitStart { pacing?.recordWait(since: tailWaitStart) }
                    guard tail.count <= fragmentTotal - buffered.count else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .fragment, boxType: "mdat", field: "readSize",
                            reason: "exceeds_request", availableBytes: tail.count
                        ))
                    }
                    segment.append(tail)
                    packets.noteRead(
                        consumedRange: Int64(readOffsetResult.partialValue)..<Int64(r.cursor + segment.count)
                    )
                    guard segment.count == fragmentTotal else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .fragment, boxType: "mdat", field: "size", reason: "truncated"
                        ))
                    }
                }
                var synthesizedInFragment = 0
                let base = segment.startIndex
                for (ordinal, sample) in emittable.enumerated() {
                    let localStartResult = sample.offset.subtractingReportingOverflow(r.cursor)
                    guard !localStartResult.overflow else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .sample, field: "sampleOffset", reason: "overflow"
                        ))
                    }
                    let localStart = localStartResult.partialValue
                    let localEndResult = localStart.addingReportingOverflow(sample.size)
                    guard !localEndResult.overflow else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .sample, field: "sampleSpan", reason: "overflow"
                        ))
                    }
                    let localEnd = localEndResult.partialValue
                    guard localStart >= 0, localEnd > localStart,
                          localEnd <= segment.count else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .sample, boxType: "mdat", trackID: sample.trackID,
                            field: "sampleSpan", reason: "out_of_range"
                        ))
                    }
                    if sample.durationIsSynthesized { synthesizedInFragment += 1 }
                    packets.emit(Self.mediaPacket(
                        for: sample,
                        data: segment.subdata(in: (base + localStart)..<(base + localEnd)),
                        kind: kind,
                        trackTimescale: r.track.timescale,
                        effectiveTimescale: timescale,
                        displayCoverage: displaySamples.first { $0.ordinal == ordinal }.flatMap { r.displayTrack?.own($0.interval) }
                    ), payloadRange: Int64(sample.offset)..<Int64(sample.offset + sample.size))
                    produced += Double(sample.durationTicks) / timescale
                }
                if synthesizedInFragment > 0 {
                    if diagnostics.count < maxDeferredPumpDiagnostics {
                        diagnostics.append(
                            .synthesizedDuration(
                                count: synthesizedInFragment,
                                kind: kind,
                                cursor: r.cursor
                            )
                        )
                    }
                }
                let nextCursorResult = mdatStart.addingReportingOverflow(mdatHeader.size)
                guard !nextCursorResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "mdat", field: "end", reason: "overflow"
                    ))
                }
                r.cursor = nextCursorResult.partialValue
                if packets.deliversIncrementally {
                    let ready = packets.takeUncommitted()
                    if !ready.isEmpty {
                        guard await owner.commitStreamedProgress(
                            kind: kind, reader: r, packets: ready,
                            generation: generation, relay: relay, waitBudget: trackWaitBudget
                        ) else {
                            throw MediaEngineError.stopped
                        }
                    }
                }
            } else {
                packets.discardReadObservation()
                let nextCursorResult = r.cursor.addingReportingOverflow(header.size)
                guard !nextCursorResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, field: "boxEnd", reason: "overflow"
                    ))
                }
                if readEnd > 0, nextCursorResult.partialValue > readEnd {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .box, boxType: header.type, field: "size", reason: "truncated"
                    ))
                }
                r.cursor = nextCursorResult.partialValue
            }
        }
        if let pacing {
            let wallMs = Int(pacing.start.duration(to: ContinuousClock.now) / .milliseconds(1))
            if wallMs >= 250 || pacing.maxNetWaitMs >= 250 {
                PlayerLog.log(
                    "[PathA][gap] pump \(kind.rawValue) wall=\(wallMs)ms " +
                    "produced=\(String(format: "%.2f", produced))s pkts=\(packets.emittedCount) " +
                    "relayed=\(packets.relayedCount) " +
                    "netWaits=\(pacing.netWaits) maxNetWait=\(pacing.maxNetWaitMs)ms " +
                    "reopens=\(pacing.reopens)"
                )
            }
        }
        if packets.deliversIncrementally {
            let ready = packets.takeUncommitted()
            if !ready.isEmpty {
                PlayerLog.diagnostic(
                    "[PathA] ⚠️ \(kind.rawValue) pump returned with \(ready.count) " +
                    "uncommitted packets — an emit path is missing its commit"
                )
                guard await owner.commitStreamedProgress(
                    kind: kind, reader: r, packets: ready,
                    generation: generation, relay: relay, waitBudget: trackWaitBudget
                ) else {
                    throw MediaEngineError.stopped
                }
            }
        }
        return TrackPumpResult(
            reader: r,
            packets: packets.batched,
            diagnostics: diagnostics
        )
    }

    private struct PacketEmitter {
        let relay: DemuxPacketRelay?
        let waitBudget: MediaSourceWaitBudget?
        var primaryObservations: [MediaSourcePrimaryObservation] = []
        var metadataRange: Range<Int64>?
        var batched: [MediaPacket] = []
        var uncommitted: [MediaPacket] = []
        var emittedCount = 0
        var relayedCount = 0

        var deliversIncrementally: Bool { relay != nil }

        mutating func noteRead(consumedRange: Range<Int64>) {
            while let observation = waitBudget?.takePrimaryObservation() {
                guard let range = observation.range, range.overlaps(consumedRange) else { continue }
                primaryObservations.append(observation)
            }
        }

        mutating func discardReadObservation() {
            while waitBudget?.takePrimaryObservation() != nil {}
            primaryObservations.removeAll(keepingCapacity: true)
            metadataRange = nil
        }

        mutating func emit(_ value: MediaPacket, payloadRange: Range<Int64>) {
            var packet = value
            let dependencies = primaryObservations.filter { observation in
                guard let range = observation.range else { return false }
                return range.overlaps(payloadRange) || metadataRange.map { range.overlaps($0) } == true
            }
            packet.sourcePrimaryObservation = dependencies.min { $0.issuedAt < $1.issuedAt }
            let consumedIssues = Set(dependencies.map(\.issueID))
            primaryObservations.removeAll { consumedIssues.contains($0.issueID) }
            emittedCount += 1
            if relay == nil {
                batched.append(packet)
            } else {
                uncommitted.append(packet)
            }
        }

        mutating func takeUncommitted() -> [MediaPacket] {
            defer { uncommitted.removeAll(keepingCapacity: true) }
            relayedCount += uncommitted.count
            return uncommitted
        }
    }

    private static func commitStreamedStateIfNeeded(
        reader: TrackReader,
        packets: inout PacketEmitter,
        kind: MediaTrackKind,
        owner: PathAFMP4Demuxer,
        generation: UInt64,
        relay: DemuxPacketRelay?
    ) async throws {
        try checkWaitBudget(packets.waitBudget)
        guard await owner.isCurrentReaderMutation(generation) else {
            if let streamID = reader.activeFragment?.streamID {
                await reader.source.closeChunkStream(streamID)
            }
            throw MediaEngineError.stopped
        }
        try checkWaitBudget(packets.waitBudget)
        guard packets.deliversIncrementally else { return }
        let ready = packets.takeUncommitted()
        guard await owner.commitStreamedProgress(
            kind: kind,
            reader: reader,
            packets: ready,
            generation: generation,
            relay: relay,
            waitBudget: packets.waitBudget
        ) else {
            if let streamID = reader.activeFragment?.streamID {
                await reader.source.closeChunkStream(streamID)
            }
            throw MediaEngineError.stopped
        }
    }

    private enum FragmentConsumeOutcome {
        case fragmentComplete
        case budgetReached
    }

    private static func consumeActiveFragment(
        _ r: inout TrackReader,
        packets: inout PacketEmitter,
        diagnostics: inout [DeferredPumpDiagnostic],
        produced: inout TimeInterval,
        budget: TimeInterval,
        kind: MediaTrackKind,
        pacing: inout PumpPacing?,
        owner: PathAFMP4Demuxer,
        generation: UInt64,
        relay: DemuxPacketRelay?,
        waitBudget: MediaSourceWaitBudget?
    ) async throws -> FragmentConsumeOutcome {
        guard var af = r.activeFragment else { return .fragmentComplete }
        if let id = af.streamID {
            let position = await r.source.chunkStreamPosition(id)
            if position != Int64(af.assembler.resumeOffset) {
                await r.source.closeChunkStream(id)
                af.streamID = nil
                r.activeFragment = af
            }
        }
        var reopenBudget = FragmentReopenBudget(initialOffset: Int64(af.assembler.resumeOffset))
        while true {
            let displayBytes = r.displayTrack.map(MediaDisplayByteOwner.init)
            defer { displayBytes?.release() }
            try checkWaitBudget(waitBudget)
            let fragmentEndResult = af.fragmentStart.addingReportingOverflow(af.fragmentTotal)
            guard !fragmentEndResult.overflow else {
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .fragment, boxType: "mdat", field: "end", reason: "overflow"
                ))
            }
            let fragmentEnd = fragmentEndResult.partialValue
            guard af.assembler.resumeOffset <= fragmentEnd else {
                await finalizeActiveFragment(
                    &r, &af, diagnostics: &diagnostics, kind: kind, truncated: true
                )
                r.eof = true
                try await commitStreamedStateIfNeeded(
                    reader: r,
                    packets: &packets,
                    kind: kind,
                    owner: owner,
                    generation: generation,
                    relay: relay
                )
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .fragment, boxType: "mdat", field: "resumeOffset", reason: "overrun"
                ))
            }
            if af.assembler.isComplete, af.assembler.resumeOffset == fragmentEnd {
                await finalizeActiveFragment(
                    &r, &af, diagnostics: &diagnostics, kind: kind, truncated: false
                )
                try await commitStreamedStateIfNeeded(
                    reader: r,
                    packets: &packets,
                    kind: kind,
                    owner: owner,
                    generation: generation,
                    relay: relay
                )
                return .fragmentComplete
            }
            if af.streamID == nil {
                let resume = af.assembler.resumeOffset
                let remaining = fragmentEndResult.partialValue - resume
                guard remaining > 0 else {
                    let truncated = af.assembler.finishTruncated()
                    await finalizeActiveFragment(
                        &r, &af, diagnostics: &diagnostics, kind: kind, truncated: truncated
                    )
                    r.eof = true
                    try await commitStreamedStateIfNeeded(
                        reader: r,
                        packets: &packets,
                        kind: kind,
                        owner: owner,
                        generation: generation,
                        relay: relay
                    )
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "mdat", field: "sampleSpan", reason: "truncated"
                    ))
                }
                guard await owner.isCurrentReaderMutation(generation) else {
                    throw MediaEngineError.stopped
                }
                try checkWaitBudget(waitBudget)
                let streamID = try await r.source.openChunkStream(
                    offset: Int64(resume),
                    count: remaining,
                    waitBudget: waitBudget
                )
                guard await owner.isCurrentReaderMutation(generation) else {
                    await r.source.closeChunkStream(streamID)
                    throw MediaEngineError.stopped
                }
                try checkWaitBudget(waitBudget)
                af.streamID = streamID
                if af.trace != nil, !af.trace!.loggedStreamStart {
                    af.trace!.loggedStreamStart = true
                    traceLog(&af, kind: kind, "mdat-stream-start resume@\(resume) remaining=\(remaining)B")
                }
                r.activeFragment = af
            }
            let chunkWaitStart = pacing != nil ? ContinuousClock.now : nil
            let step: PathAHTTPMediaSource.ChunkStreamStep
            do {
                step = try await r.source.nextChunkStep(
                    af.streamID ?? 0, waitBudget: waitBudget, displayOwner: displayBytes
                )
                try checkWaitBudget(waitBudget)
                if let chunkWaitStart { pacing?.recordWait(since: chunkWaitStart) }
            } catch {
                if let chunkWaitStart { pacing?.recordWait(since: chunkWaitStart) }
                if let id = af.streamID {
                    await r.source.closeChunkStream(id)
                    af.streamID = nil
                }
                if error is CancellationError || Self.isCancellation(error)
                    || Task.isCancelled || waitBudget?.isCancelled == true {
                    r.activeFragment = af
                    throw error
                }
                guard reopenBudget.admitError(currentOffset: Int64(af.assembler.resumeOffset)) else {
                    r.activeFragment = af
                    throw error
                }
                pacing?.reopens += 1
                PlayerLog.log(
                    "[PathA] mdat-stream-reopen \(kind.rawValue) " +
                    "resume@\(af.assembler.resumeOffset) reason=\(error.localizedDescription)"
                )
                r.activeFragment = af
                continue
            }
            let chunk: Data
            switch step {
            case .chunk(let data):
                chunk = data
            case .backpressureSuspended(let resumeOffset):
                af.streamID = nil
                guard reopenBudget.admitBackpressure(resumeOffset: resumeOffset) else {
                    r.activeFragment = af
                    throw MediaEngineError.demuxFailed("fMP4 mdat backpressure reopen budget exhausted")
                }
                pacing?.reopens += 1
                PlayerLog.log(
                    "[PathA] mdat-stream-reopen \(kind.rawValue) " +
                    "resume@\(af.assembler.resumeOffset) reason=backpressure"
                )
                r.activeFragment = af
                continue
            case .endOfStream:
                _ = af.assembler.finishTruncated()
                await finalizeActiveFragment(
                    &r, &af, diagnostics: &diagnostics, kind: kind, truncated: true
                )
                r.eof = true
                try await commitStreamedStateIfNeeded(
                    reader: r,
                    packets: &packets,
                    kind: kind,
                    owner: owner,
                    generation: generation,
                    relay: relay
                )
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .fragment, boxType: "mdat", field: "size", reason: "truncated"
                ))
            }
            let remainingBeforeChunk = fragmentEnd - af.assembler.resumeOffset
            guard !chunk.isEmpty, chunk.count <= remainingBeforeChunk else {
                await finalizeActiveFragment(
                    &r, &af, diagnostics: &diagnostics, kind: kind, truncated: true
                )
                r.eof = true
                try await commitStreamedStateIfNeeded(
                    reader: r,
                    packets: &packets,
                    kind: kind,
                    owner: owner,
                    generation: generation,
                    relay: relay
                )
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .fragment, boxType: "mdat", field: "chunk", reason: "overrun_or_empty",
                    availableBytes: chunk.count
                ))
            }
            packets.noteRead(
                consumedRange: Int64(af.assembler.resumeOffset)..<Int64(af.assembler.resumeOffset + chunk.count)
            )
            if af.trace != nil, !af.trace!.loggedFirstByte {
                af.trace!.loggedFirstByte = true
                traceLog(&af, kind: kind, "first-mdat-byte chunk=\(chunk.count)B")
            }
            let emitted = af.assembler.consume(chunk)
            guard !af.assembler.isMalformed else {
                await finalizeActiveFragment(
                    &r, &af, diagnostics: &diagnostics, kind: kind, truncated: true
                )
                r.eof = true
                try await commitStreamedStateIfNeeded(
                    reader: r,
                    packets: &packets,
                    kind: kind,
                    owner: owner,
                    generation: generation,
                    relay: relay
                )
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .fragment, boxType: "mdat", field: "assembler",
                    reason: "cursor_overflow"
                ))
            }
            appendStreamedPackets(
                emitted, fragment: &af, reader: &r, kind: kind,
                produced: &produced, packets: &packets
            )
            r.activeFragment = af
            try await commitStreamedStateIfNeeded(
                reader: r,
                packets: &packets,
                kind: kind,
                owner: owner,
                generation: generation,
                relay: relay
            )
            if produced >= budget, !af.assembler.isComplete {
                return .budgetReached
            }
        }
    }

    private static func checkWaitBudget(_ waitBudget: MediaSourceWaitBudget?) throws {
        try Task.checkCancellation()
        if waitBudget?.isCancelled == true { throw CancellationError() }
    }

    private static func finalizeActiveFragment(
        _ r: inout TrackReader,
        _ af: inout ActiveFragmentStream,
        diagnostics: inout [DeferredPumpDiagnostic],
        kind: MediaTrackKind,
        truncated: Bool
    ) async {
        if truncated { r.displayUsability.revoke() }
        if let streamID = af.streamID {
            await r.source.closeChunkStream(streamID)
        }
        if af.synthesizedEmitted > 0 {
            if diagnostics.count < maxDeferredPumpDiagnostics {
                diagnostics.append(.synthesizedDuration(
                    count: af.synthesizedEmitted,
                    kind: kind,
                    cursor: af.fragmentStart
                ))
            }
        }
        if af.trace != nil {
            traceLog(&af, kind: kind, truncated ? "mdat-stream-truncated" : "mdat-stream-complete")
            r.armFragmentTrace = false
        }
        if truncated {
            PlayerLog.diagnostic(
                "[PathA] ⚠️ mdat-stream truncated mid-play \(kind.rawValue) " +
                "frag@\(af.fragmentStart) — reader EOF until a seek"
            )
        }
        if !truncated {
            let nextCursor = af.fragmentStart.addingReportingOverflow(af.fragmentTotal)
            if !nextCursor.overflow {
                r.cursor = nextCursor.partialValue
            }
        }
        r.activeFragment = nil
    }

    private static func appendStreamedPackets(
        _ emitted: [PathAMdatStreamAssembler.Emitted],
        fragment af: inout ActiveFragmentStream,
        reader r: inout TrackReader,
        kind: MediaTrackKind,
        produced: inout TimeInterval,
        packets: inout PacketEmitter
    ) {
        for entry in emitted {
            let sample = af.samples[entry.sampleIndex]
            if sample.durationIsSynthesized { af.synthesizedEmitted += 1 }
            if af.trace != nil, !af.trace!.loggedFirstSample {
                af.trace!.loggedFirstSample = true
                traceLog(&af, kind: kind, "first-sample-ready idx=\(entry.sampleIndex) bytes=\(entry.data.count)")
            }
            packets.emit(mediaPacket(
                for: sample,
                data: entry.data,
                kind: kind,
                trackTimescale: r.track.timescale,
                effectiveTimescale: af.effectiveTimescale,
                displayCoverage: entry.displayCoverage
            ), payloadRange: Int64(sample.offset)..<Int64(sample.offset + sample.size))
            if af.trace != nil, !af.trace!.loggedFirstPacket {
                af.trace!.loggedFirstPacket = true
                traceLog(&af, kind: kind, "first-packet-emitted")
            }
            produced += Double(sample.durationTicks) / af.effectiveTimescale
        }
    }

    private static func displaySamples(
        _ samples: [PathAFMP4.Sample], kind: PathAFMP4.TrackKind, fragment: Int, timescale: Double
    ) -> [MediaDisplaySample] {
        guard let scale = Int64(exactly: timescale), scale > 0 else { return [] }
        let declared = samples.enumerated().compactMap { ordinal, sample -> MediaDisplaySample? in
            let end = sample.ptsTicks.addingReportingOverflow(Int64(sample.durationTicks))
            let byteEnd = sample.offset.addingReportingOverflow(sample.size)
            guard !sample.durationIsSynthesized, sample.durationTicks > 0, sample.size > 0,
                  !end.overflow, !byteEnd.overflow,
                  let interval = MediaDisplayInterval(
                    MediaDisplayTime(sample.ptsTicks, scale: scale),
                    MediaDisplayTime(end.partialValue, scale: scale)
                  ) else { return nil }
            return MediaDisplaySample(fragment: Int64(fragment), ordinal: ordinal,
                                      bytes: Int64(sample.offset)..<Int64(byteEnd.partialValue), interval: interval)
        }
        guard kind == .video else { return declared }
        let presentationEnds = videoPresentationEnds(samples, validOrdinals: Set(declared.map(\.ordinal)))
        return declared.map { sample in
            guard let end = presentationEnds[sample.ordinal],
                  let interval = MediaDisplayInterval(
                    sample.interval.lower, MediaDisplayTime(end, scale: scale)
                  ) else { return sample }
            return MediaDisplaySample(fragment: sample.fragment, ordinal: sample.ordinal,
                                      bytes: sample.bytes, interval: interval)
        }
    }

    private static func videoPresentationEnds(
        _ samples: [PathAFMP4.Sample], validOrdinals: Set<Int>
    ) -> [Int: Int64] {
        var ends: [Int: Int64] = [:]
        let tracks = Dictionary(grouping: samples.indices, by: { samples[$0].trackID })
        for ordinals in tracks.values {
            let ordered = ordinals.sorted { samples[$0].ptsTicks < samples[$1].ptsTicks }
            let neighbors = zip(ordered, ordered.dropFirst())
            guard neighbors.allSatisfy({ samples[$0.0].ptsTicks < samples[$0.1].ptsTicks }) else { continue }
            let successors = Dictionary(uniqueKeysWithValues: neighbors)
            var run: [Int] = []
            var nextDTS: Int64?
            for ordinal in ordinals {
                let sample = samples[ordinal]
                let decodeEnd = sample.dtsTicks.addingReportingOverflow(Int64(sample.durationTicks))
                guard validOrdinals.contains(ordinal), !decodeEnd.overflow else {
                    appendVideoPresentationEnds(run, successors: successors, samples: samples, to: &ends)
                    run.removeAll(keepingCapacity: true)
                    nextDTS = nil
                    continue
                }
                if let nextDTS, sample.dtsTicks != nextDTS {
                    appendVideoPresentationEnds(run, successors: successors, samples: samples, to: &ends)
                    run.removeAll(keepingCapacity: true)
                }
                run.append(ordinal)
                nextDTS = decodeEnd.partialValue
            }
            appendVideoPresentationEnds(run, successors: successors, samples: samples, to: &ends)
        }
        return ends
    }

    private static func appendVideoPresentationEnds(
        _ ordinals: [Int], successors: [Int: Int], samples: [PathAFMP4.Sample], to ends: inout [Int: Int64]
    ) {
        let run = Set(ordinals)
        for ordinal in ordinals {
            guard let next = successors[ordinal], run.contains(next) else { continue }
            ends[ordinal] = samples[next].ptsTicks
        }
    }

    private static func mediaPacket(
        for sample: PathAFMP4.Sample,
        data: Data,
        kind: MediaTrackKind,
        trackTimescale: UInt32,
        effectiveTimescale: Double,
        displayCoverage: MediaDisplayLease? = nil
    ) -> MediaPacket {
        MediaPacket(
            track: kind,
            pts: Double(sample.ptsTicks) / effectiveTimescale,
            dts: Double(sample.dtsTicks) / effectiveTimescale,
            duration: Double(sample.durationTicks) / effectiveTimescale,
            data: data,
            isKeyframe: sample.isKeyframe,
            audioTiming: kind == .audio ? MediaAudioPacketTiming(
                ptsTicks: sample.ptsTicks,
                dtsTicks: sample.dtsTicks,
                durationTicks: sample.durationTicks,
                trackTimescale: trackTimescale,
                effectiveTimescale: effectiveTimescale
            ) : nil,
            emittedAt: ContinuousClock.now,
            displayCoverage: displayCoverage,
            containerSampleIndex: sample.sampleIndex,
            containerFragmentSequence: sample.fragmentSequence,
            containerSampleOffset: sample.offset
        )
    }

    private static func traceLog(
        _ af: inout ActiveFragmentStream,
        kind: MediaTrackKind,
        _ label: String,
        elapsed: Bool = true
    ) {
        guard let trace = af.trace else { return }
        let suffix = elapsed ? " +\(trace.elapsedMs())ms" : ""
        PlayerLog.log("[PathA] mdat-stream \(kind.rawValue) \(label)\(suffix)")
    }

    private func publish(_ diagnostics: [DeferredPumpDiagnostic]) {
        for diagnostic in diagnostics {
            switch diagnostic {
            case .synthesizedDuration(let count, let kind, let cursor):
                noteSynthesizedDurations(count, kind: kind, at: cursor)
            case .audioTimingMismatch(let resolution, let containerSampleRate):
                PlayerLog.diagnostic(
                    "[PathA] AAC timing mismatch keepsMP4TS=\(resolution.declaredTimescale) " +
                    "effectiveTS=\(String(format: "%.3f", resolution.effectiveTimescale)) " +
                    "codec=\(Int(resolution.codecSampleRate))Hz " +
                    "rawAU=\(String(format: "%.6f", resolution.observedDurationSeconds))s " +
                    "ascAU=\(String(format: "%.6f", resolution.expectedDurationSeconds))s " +
                    "trackSR=\(Int(containerSampleRate.rounded()))Hz"
                )
            }
        }
    }

    private func publishOpenDiagnostics(_ diagnostics: [DeferredOpenDiagnostic]) {
        for diagnostic in diagnostics {
            switch diagnostic {
            case .log(let message):
                PlayerLog.log(message)
            }
        }
    }

    private func noteSynthesizedDurations(_ count: Int, kind: MediaTrackKind, at cursor: Int) {
        let before = synthesizedDurationSamples[kind] ?? 0
        let afterResult = before.addingReportingOverflow(max(0, count))
        let after = afterResult.overflow ? Int.max : afterResult.partialValue
        synthesizedDurationSamples[kind] = after
        guard before == 0 || (before / 500) != (after / 500) else { return }
        PlayerLog.log(
            "[PathA] fMP4 \(kind.rawValue) fragment@\(cursor) carried no sample duration " +
            "(\(count) samples synthesized, total=\(after))"
        )
    }

    private(set) var synthesizedDurationSamples: [MediaTrackKind: Int] = [:]

    // MARK: - seek

    func prepareVideoContinuity(at mediaTime: TimeInterval) async throws -> Bool {
        try await positionVideoContinuity(.target(mediaTime))
    }

    func prepareEarlierVideoContinuity(
        before excludedAnchorPTS: TimeInterval
    ) async throws -> Bool {
        try await positionVideoContinuity(.earlierThan(excludedAnchorPTS))
    }

    func prepareForwardVideoContinuity(
        _ request: MediaVideoForwardRequest
    ) async throws -> MediaVideoForwardOutcome {
        guard let current = video, videoContinuityTopology == .splitTrack,
              !current.isFileSource, !current.segments.isEmpty,
              request.target.isFinite, request.target >= 0,
              request.playbackRate.isFinite, request.playbackRate > 0,
              request.wallAllowance > .zero, request.maximumCompressedBytes > 0,
              request.maximumContentSpan.isFinite, request.maximumContentSpan > 0
        else { return .notSelected }
        let generation = readerMutationGeneration
        let started = ContinuousClock.now
        let bytesBefore = await current.source.bytesRead
        let observation = await current.source.recentRetrievalEstimate(maximumAge: request.wallAllowance)
        try Task.checkCancellation()
        guard generation == readerMutationGeneration else { throw MediaEngineError.stopped }
        guard let estimate = observation else { return .notSelected }
        let wallSeconds = Double(request.wallAllowance / .seconds(1))
        let maximumLead = wallSeconds * request.playbackRate
        guard wallSeconds.isFinite, wallSeconds > 0, maximumLead.isFinite,
              maximumLead > 0 else { return .notSelected }
        let selected: ForwardReference?
        do {
            selected = try await selectForwardReference(
                current, request: request, estimate: estimate,
                generation: generation, started: started
            )
        } catch let parserError as PathAFMP4.ParseError {
            try Task.checkCancellation()
            guard generation == readerMutationGeneration else { throw MediaEngineError.stopped }
            let mapped = Self.mediaError(for: parserError, context: "forward video continuity")
            latchedParseFailure = mapped
            throw mapped
        }
        try Task.checkCancellation()
        guard generation == readerMutationGeneration else { throw MediaEngineError.stopped }
        guard let selected else { return .notSelected }
        let bytesAfter = await current.source.bytesRead
        try Task.checkCancellation()
        guard generation == readerMutationGeneration, bytesAfter >= bytesBefore else {
            throw MediaEngineError.stopped
        }
        let selectionBytes = Int(clamping: bytesAfter - bytesBefore)
        guard selectionBytes <= request.maximumCompressedBytes,
              selected.maximumCompressedByteCount <= request.maximumCompressedBytes - selectionBytes,
              estimate.observedAt.duration(to: .now) <= request.wallAllowance,
              started.duration(to: .now) < request.wallAllowance else { return .notSelected }
        return try await commitForwardPosition(
            current, selected: selected, request: request,
            maximumLead: maximumLead, fetchBytes: selectionBytes
        )
    }

    private struct ForwardReference {
        let entry: PathAFMP4.SidxEntry
        let end: Int
        let interval: MediaVideoContinuityContentInterval
        let anchorPTS: TimeInterval
        let maximumCompressedByteCount: Int
    }

    private func selectForwardReference(
        _ reader: TrackReader,
        request: MediaVideoForwardRequest,
        estimate: PathAHTTPMediaSource.RetrievalEstimate,
        generation: UInt64,
        started: ContinuousClock.Instant
    ) async throws -> ForwardReference? {
        guard let lower = reader.segments.firstIndex(where: {
            $0.presentationStartSeconds > request.target
        }) else { return nil }
        let upper = min(reader.segments.count, lower + Self.earlierContinuitySidxScanLimit)
        for index in lower..<upper {
            try Task.checkCancellation()
            guard generation == readerMutationGeneration else { throw MediaEngineError.stopped }
            guard started.duration(to: .now) < request.wallAllowance else { return nil }
            let entry = reader.segments[index]
            guard entry.size <= request.maximumCompressedBytes,
                  let end = Self.forwardReferenceEnd(entry, reader: reader),
                  Self.forwardForecastAdmits(entry, request: request, estimate: estimate),
                  let proof = try await Self.forwardReferenceProof(entry, end: end, reader: reader)
            else { continue }
            try Task.checkCancellation()
            guard generation == readerMutationGeneration else { throw MediaEngineError.stopped }
            guard proof.interval.end - proof.interval.start <= request.maximumContentSpan,
                  proof.contentSeconds <= request.maximumContentSpan,
                  proof.compressedByteCount <= request.maximumCompressedBytes else { continue }
            var proven = entry
            proven.presentationStartSeconds = proof.anchorPTS
            proven.durationSeconds = proof.interval.end - proof.interval.start
            guard Self.forwardForecastAdmits(proven, request: request, estimate: estimate) else { continue }
            return ForwardReference(
                entry: entry, end: end, interval: proof.interval, anchorPTS: proof.anchorPTS,
                maximumCompressedByteCount: max(entry.size, proof.compressedByteCount)
            )
        }
        return nil
    }

    private struct ForwardReferenceProof {
        let anchorPTS: TimeInterval
        let interval: MediaVideoContinuityContentInterval
        let startsWithSyncSample: Bool
        let compressedByteCount: Int
        let contentSeconds: TimeInterval
    }

    private struct ForwardProofExtent {
        var first: ForwardReferenceProof?
        var start = TimeInterval.infinity
        var end = -TimeInterval.infinity
        var compressedByteCount = 0
        var contentSeconds: TimeInterval = 0

        mutating func append(_ proof: ForwardReferenceProof?) -> Bool {
            guard let proof else { return true }
            let bytes = compressedByteCount.addingReportingOverflow(proof.compressedByteCount)
            let seconds = contentSeconds + proof.contentSeconds
            guard first != nil || proof.startsWithSyncSample,
                  !bytes.overflow, seconds.isFinite else { return false }
            compressedByteCount = bytes.partialValue
            contentSeconds = seconds
            first = first ?? proof
            start = min(start, proof.interval.start)
            end = max(end, proof.interval.end)
            return true
        }
    }

    private static func forwardReferenceProof(
        _ entry: PathAFMP4.SidxEntry, end: Int, reader: TrackReader
    ) async throws -> ForwardReferenceProof? {
        guard reader.track.timescale > 0 else { return nil }
        var cursor = entry.offset
        var headers = 0
        var metadataBytes = 0
        var extent = ForwardProofExtent()
        while cursor < end {
            try Task.checkCancellation()
            guard headers < 64, end - cursor >= 8,
                  let header = try await forwardBoxHeader(
                    reader.source, at: cursor, end: end, resourceEnd: reader.endByte
                  )
            else { return nil }
            headers += 1
            let boxEnd = cursor.addingReportingOverflow(header.size)
            guard !boxEnd.overflow, boxEnd.partialValue <= end else { return nil }
            if header.type != "moof" {
                guard header.type != "mdat" else { return nil }
                cursor = boxEnd.partialValue
                continue
            }
            let total = metadataBytes.addingReportingOverflow(header.size)
            guard !total.overflow, total.partialValue <= headMaxBytes,
                  headers < 64, end - boxEnd.partialValue >= 8,
                  let mdat = try await forwardBoxHeader(
                    reader.source, at: boxEnd.partialValue, end: end, resourceEnd: reader.endByte
                  ),
                  mdat.type == "mdat" else { return nil }
            headers += 1
            metadataBytes = total.partialValue
            let fragmentEnd = boxEnd.partialValue.addingReportingOverflow(mdat.size)
            let payloadStart = boxEnd.partialValue.addingReportingOverflow(mdat.headerLength)
            guard !fragmentEnd.overflow, !payloadStart.overflow,
                  fragmentEnd.partialValue <= end else { return nil }
            guard extent.append(try await forwardFragmentProof(
                reader, offset: cursor, size: header.size,
                payload: payloadStart.partialValue..<fragmentEnd.partialValue
            )) else { return nil }
            cursor = fragmentEnd.partialValue
        }
        guard let first = extent.first,
              let interval = MediaVideoContinuityContentInterval(start: extent.start, end: extent.end)
        else { return nil }
        return ForwardReferenceProof(
            anchorPTS: first.anchorPTS, interval: interval, startsWithSyncSample: true,
            compressedByteCount: extent.compressedByteCount, contentSeconds: extent.contentSeconds
        )
    }

    private static func forwardBoxHeader(
        _ source: PathAHTTPMediaSource, at offset: Int, end: Int, resourceEnd: Int
    ) async throws -> BoxHeader? {
        guard offset >= 0, end - offset >= 8 else { return nil }
        let count = min(16, end - offset)
        let data = try await source.read(offset: Int64(offset), count: count, recordReadPosition: false)
        guard data.count == count, let header = parseBoxHeader(data, at: 0) else {
            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                phase: .box, field: "header", reason: "truncated_or_invalid", offset: offset
            ))
        }
        return try resolveBoxHeader(header, at: offset, containingEnd: resourceEnd)
    }

    private static func forwardFragmentProof(
        _ reader: TrackReader, offset: Int, size: Int, payload: Range<Int>
    ) async throws -> ForwardReferenceProof? {
        let data = try await reader.source.read(offset: Int64(offset), count: size, recordReadPosition: false)
        guard data.count == size else {
            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                phase: .fragment, boxType: "moof", field: "size", reason: "truncated", offset: offset
            ))
        }
        let parsed: [PathAFMP4.Sample]
        switch PathAFMP4.parseFragmentResult(
            data, segmentByteOffset: offset, moofRange: 0..<data.count,
            tracks: [reader.track], sampleDataRange: payload
        ) {
        case .success(let value): parsed = value
        case .needMoreData(let required):
            throw PathAFMP4.ParseError.needMoreData(requiredBytes: required)
        case .malformed(let failure): throw PathAFMP4.ParseError.malformed(failure)
        case .unsupported(let reason): throw PathAFMP4.ParseError.unsupported(reason)
        }
        let samples = reader.requiresExactFragmentTrackID
            ? parsed.filter { $0.trackID == reader.track.trackID } : parsed
        guard let first = samples.first else { return nil }
        var start = TimeInterval.infinity
        var finish = -TimeInterval.infinity
        let scale = Double(reader.track.timescale)
        var compressedByteCount = 0
        var contentSeconds: TimeInterval = 0
        for sample in samples {
            let end = sample.ptsTicks.addingReportingOverflow(Int64(sample.durationTicks))
            let bytes = compressedByteCount.addingReportingOverflow(sample.size)
            let seconds = contentSeconds + Double(sample.durationTicks) / scale
            guard !end.overflow, !bytes.overflow, sample.size >= 0, seconds.isFinite else { return nil }
            compressedByteCount = bytes.partialValue
            contentSeconds = seconds
            start = min(start, Double(sample.ptsTicks) / scale)
            finish = max(finish, Double(end.partialValue) / scale)
        }
        guard let interval = MediaVideoContinuityContentInterval(start: start, end: finish)
        else { return nil }
        return ForwardReferenceProof(
            anchorPTS: Double(first.ptsTicks) / scale,
            interval: interval, startsWithSyncSample: first.isKeyframe,
            compressedByteCount: compressedByteCount, contentSeconds: contentSeconds
        )
    }

    private static func forwardReferenceEnd(_ entry: PathAFMP4.SidxEntry, reader: TrackReader) -> Int? {
        let end = entry.offset.addingReportingOverflow(entry.size)
        guard entry.referenceType == 0, entry.offset >= reader.mediaStart,
              entry.size > 0, !end.overflow, reader.endByte > 0,
              end.partialValue <= reader.endByte else { return nil }
        return end.partialValue
    }

    private static func forwardForecastAdmits(
        _ entry: PathAFMP4.SidxEntry,
        request: MediaVideoForwardRequest,
        estimate: PathAHTTPMediaSource.RetrievalEstimate
    ) -> Bool {
        let wallSeconds = Double(request.wallAllowance / .seconds(1))
        let forecast = estimate.latency + Double(entry.size) / estimate.bytesPerSecond
        let lead = entry.presentationStartSeconds - request.target
        return entry.presentationStartSeconds.isFinite && entry.durationSeconds.isFinite
            && entry.durationSeconds > 0 && (entry.presentationStartSeconds + entry.durationSeconds).isFinite
            && forecast.isFinite && forecast >= 0 && forecast <= wallSeconds
            && lead.isFinite && lead > 0 && lead <= wallSeconds * request.playbackRate
            && lead >= forecast * request.playbackRate
    }

    private func commitForwardPosition(
        _ current: TrackReader,
        selected: ForwardReference,
        request: MediaVideoForwardRequest,
        maximumLead: TimeInterval,
        fetchBytes: Int
    ) async throws -> MediaVideoForwardOutcome {
        activeForwardReceipt = nil
        readerMutationGeneration &+= 1
        let mutation = readerMutationGeneration
        current.displayUsability.revoke()
        current.displayTrack?.clearLayouts()
        futureDisplayLeases[.video] = nil
        if let streamID = current.activeFragment?.streamID {
            await current.source.closeChunkStream(streamID)
        }
        try Task.checkCancellation()
        guard mutation == readerMutationGeneration else { throw MediaEngineError.stopped }
        var staged = current
        staged.displayUsability = MediaResidentDisplayUsability()
        staged.parsedDisplayFragment = nil
        staged.activeFragment = nil
        staged.armFragmentTrace = true
        staged.eof = false
        staged.cursor = selected.entry.offset
        let receipt = MediaVideoForwardReceipt(
            id: UUID(), readerMutationGeneration: mutation, anchorPTS: selected.anchorPTS,
            referenceStart: selected.entry.offset, referenceEnd: selected.end,
            contentInterval: selected.interval, sampledTarget: request.target,
            maximumLead: maximumLead, playbackRate: request.playbackRate,
            selectionFetchBytes: fetchBytes
        )
        video = staged
        activeForwardReceipt = receipt
        return .positioned(receipt)
    }

    func pumpPositionedVideoContinuity(
        readGeneration: UInt64,
        contentBudget: TimeInterval
    ) async throws -> MediaVideoContinuityBatchOutcome {
        if let latchedParseFailure {
            throw latchedParseFailure
        }
        guard video != nil else { return .unsupported(.unavailable) }
        guard videoContinuityTopology == .splitTrack
                || videoContinuityTopology == .localFileIndex else {
            return .unsupported(.topology)
        }
        guard contentBudget.isFinite, contentBudget > 0 else {
            return .supported(MediaVideoContinuityBatch(
                readerMutationGeneration: readerMutationGeneration,
                readGeneration: readGeneration,
                packets: [],
                compressedByteCount: 0,
                contentInterval: nil,
                contentFrontier: nil,
                reachedEOF: video?.eof ?? true,
                madeProgress: false
            ))
        }

        prepareResidentDisplayForPump(video: true, audio: false)
        let mutationGeneration = readerMutationGeneration
        guard let currentVideo = video else {
            return .unsupported(.unavailable)
        }
        let source = currentVideo.source
        try Task.checkCancellation()
        let bytesBefore = await source.bytesRead
        try Task.checkCancellation()
        guard mutationGeneration == readerMutationGeneration else {
            throw MediaEngineError.stopped
        }

        let result: TrackPumpResult
        do {
            result = try await Self.pump(
                currentVideo,
                budget: contentBudget,
                owner: self,
                generation: mutationGeneration,
                relay: nil,
                continuityReferenceEnd: activeForwardReceipt?.referenceEnd
            )
        } catch {
            try Task.checkCancellation()
            guard mutationGeneration == readerMutationGeneration else { throw MediaEngineError.stopped }
            currentVideo.displayUsability.revoke()
            if let parserError = error as? PathAFMP4.ParseError {
                let mapped = Self.mediaError(for: parserError, context: "fragment")
                latchedParseFailure = mapped
                throw mapped
            }
            throw error
        }
        guard mutationGeneration == readerMutationGeneration,
              !Task.isCancelled else {
            throw MediaEngineError.stopped
        }
        let bytesAfter = await result.reader.source.bytesRead
        try Task.checkCancellation()
        guard mutationGeneration == readerMutationGeneration else {
            throw MediaEngineError.stopped
        }
        video = result.reader
        publish(result.diagnostics)

        let packets = result.packets
        let contentInterval = Self.continuityContentInterval(packets)
        let contentFrontier = contentInterval?.end
        let byteDelta: Int64
        if bytesAfter >= bytesBefore {
            byteDelta = bytesAfter - bytesBefore
        } else {
            byteDelta = Int64.max
        }
        let compressedByteCount = Int(clamping: byteDelta)
        let packetByteCount = packets.reduce(
            into: (total: 0, overflowed: false)
        ) { result, packet in
            guard !result.overflowed else { return }
            let (updated, overflowed) = result.total.addingReportingOverflow(
                max(0, packet.data.count)
            )
            result.total = updated
            result.overflowed = overflowed
        }
        let chargedPacketBytes = packetByteCount.overflowed
            ? Int.max
            : packetByteCount.total
        let madeProgress = compressedByteCount > 0
            || !packets.isEmpty
            || Self.readerMadeProgress(currentVideo, result.reader)
        let batch = MediaVideoContinuityBatch(
            readerMutationGeneration: mutationGeneration,
            readGeneration: readGeneration,
            packets: packets,
            compressedByteCount: max(compressedByteCount, chargedPacketBytes),
            contentInterval: contentInterval,
            contentFrontier: contentFrontier,
            reachedEOF: result.reader.eof,
            madeProgress: madeProgress,
            forwardReceipt: activeForwardReceipt.flatMap {
                $0.readerMutationGeneration == mutationGeneration ? $0 : nil
            },
            fetchedByteCount: compressedByteCount,
            forwardReferenceExhausted: activeForwardReceipt.map {
                result.reader.activeFragment == nil && result.reader.cursor >= $0.referenceEnd
            } ?? false
        )
        return .supported(batch)
    }

    private static func continuityContentInterval(
        _ packets: [MediaPacket]
    ) -> MediaVideoContinuityContentInterval? {
        let finite = packets.filter {
            $0.track == .video
                && $0.pts.isFinite
                && $0.duration.isFinite
                && $0.duration >= 0
        }
        guard let first = finite.map(\.pts).min() else {
            return nil
        }
        let ends = finite.compactMap { packet -> TimeInterval? in
            let end = packet.pts + packet.duration
            return end.isFinite ? end : nil
        }
        guard let end = ends.max() else { return nil }
        return MediaVideoContinuityContentInterval(start: first, end: end)
    }

    private static func readerMadeProgress(
        _ before: TrackReader,
        _ after: TrackReader
    ) -> Bool {
        guard before.cursor != after.cursor || before.eof != after.eof else {
            switch (before.activeFragment, after.activeFragment) {
            case (nil, nil):
                return false
            case (nil, _), (_, nil):
                return true
            case let (before?, after?):
                return before.streamID != after.streamID
                    || before.assembler.resumeOffset != after.assembler.resumeOffset
                    || before.assembler.isComplete != after.assembler.isComplete
                    || before.synthesizedEmitted != after.synthesizedEmitted
            }
        }
        return true
    }

    private enum VideoContinuityPosition {
        case target(TimeInterval)
        case earlierThan(TimeInterval)
    }

    private func positionVideoContinuity(
        _ position: VideoContinuityPosition
    ) async throws -> Bool {
        activeForwardReceipt = nil
        readerMutationGeneration &+= 1
        let generation = readerMutationGeneration
        guard let currentVideo = video else { return false }
        currentVideo.displayUsability.revoke()
        currentVideo.displayTrack?.clearLayouts()
        futureDisplayLeases[.video] = nil
        do {
            let stagedVideo: TrackReader?
            switch position {
            case .target(let mediaTime):
                stagedVideo = try await Self.seekReader(
                    currentVideo,
                    to: mediaTime,
                    kind: "video"
                )
            case .earlierThan(let excludedAnchorPTS):
                stagedVideo = try await Self.seekEarlierVideoReader(
                    currentVideo,
                    before: excludedAnchorPTS
                )
            }
            try Task.checkCancellation()
            guard generation == readerMutationGeneration else {
                throw MediaEngineError.stopped
            }
            guard let stagedVideo else { return false }
            video = stagedVideo
            return true
        } catch {
            if generation != readerMutationGeneration
                || Task.isCancelled
                || Self.isCancellation(error) {
                throw MediaEngineError.stopped
            }
            if let parserError = error as? PathAFMP4.ParseError {
                let mapped = Self.mediaError(for: parserError, context: "video continuity")
                latchedParseFailure = mapped
                throw mapped
            }
            throw error
        }
    }

    func seek(to mediaTime: TimeInterval) async throws {
        activeForwardReceipt = nil
        readerMutationGeneration &+= 1
        let generation = readerMutationGeneration
        prefetchSeekGeneration = generation
        retireDisplayUsability()
        await multiConnectionPrefetcher?.park()
        let currentVideo = video
        let currentAudio = audio
        guard currentVideo != nil || currentAudio != nil else {
            if prefetchSeekGeneration == generation { prefetchSeekGeneration = nil }
            return
        }
        do {
            let stagedVideo: TrackReader?
            if let currentVideo {
                stagedVideo = try await Self.seekReader(
                    currentVideo,
                    to: mediaTime,
                    kind: "video"
                )
            } else {
                stagedVideo = nil
            }
            let stagedAudio: TrackReader?
            if let currentAudio {
                stagedAudio = try await Self.seekReader(
                    currentAudio,
                    to: mediaTime,
                    kind: "audio"
                )
            } else {
                stagedAudio = nil
            }
            try Task.checkCancellation()
            guard generation == readerMutationGeneration else {
                throw MediaEngineError.stopped
            }
            video = stagedVideo
            audio = stagedAudio
            multiConnectionPosition = mediaTime
            prefetchSeekGeneration = nil
            await multiConnectionPrefetcher?.seek(cursors: prefetchCursors, position: mediaTime)
        } catch {
            if prefetchSeekGeneration == generation { prefetchSeekGeneration = nil }
            if generation != readerMutationGeneration
                || Task.isCancelled
                || Self.isCancellation(error) {
                throw MediaEngineError.stopped
            }
            if let parserError = error as? PathAFMP4.ParseError {
                let mapped = Self.mediaError(for: parserError, context: "seek")
                latchedParseFailure = mapped
                throw mapped
            }
            throw error
        }
    }

    private static func seekReader(
        _ reader: TrackReader,
        to mediaTime: TimeInterval,
        kind: String
    ) async throws -> TrackReader {
        var r = reader
        r.displayUsability = MediaResidentDisplayUsability()
        r.parsedDisplayFragment = nil
        await r.source.closeActiveChunkStream()
        r.activeFragment = nil
        r.armFragmentTrace = true
        r.eof = false
        if r.segments.isEmpty {
            r.cursor = r.mediaStart
            try await extendFragmentIndex(&r, through: mediaTime)
            guard let anchor = seekAnchor(in: r, to: mediaTime, kind: kind) else {
                PlayerLog.diagnostic(
                    "[PathA] ⚠️ UNINDEXED SEEK FAILED — no target fragment for " +
                    "\(kind) at \(String(format: "%.1f", mediaTime))s; " +
                    "indexed=\(r.fragmentIndex.count) eof=\(r.fragmentIndexComplete)"
                )
                throw MediaEngineError.demuxFailed(
                    "unindexed \(kind) seek has no target fragment at " +
                    "\(String(format: "%.1f", mediaTime))s"
                )
            }
            r.cursor = anchor.offset
            PlayerLog.log(
                "[PathA] unindexed seek \(kind) target=\(String(format: "%.3f", mediaTime)) " +
                "anchor=\(String(format: "%.3f", anchor.startPTS)) " +
                "index=\(r.fragmentIndex.count)"
            )
        } else {
            let selectedIndex = r.segments.lastIndex {
                $0.presentationStartSeconds <= mediaTime + 1e-6
            } ?? 0
            let selected = r.segments[selectedIndex]
            r.cursor = selected.offset
            PlayerLog.log(
                "[PathA] sidx seek \(kind) target=\(String(format: "%.3f", mediaTime)) " +
                "anchor=\(String(format: "%.3f", selected.presentationStartSeconds)) " +
                "segment=\(selectedIndex + 1)/\(r.segments.count) " +
                Self.sapCensus(of: r.segments, selected: selected)
            )
        }
        return r
    }

    private static func seekEarlierVideoReader(
        _ reader: TrackReader,
        before excludedAnchorPTS: TimeInterval
    ) async throws -> TrackReader? {
        var r = reader
        r.displayUsability = MediaResidentDisplayUsability()
        r.parsedDisplayFragment = nil
        await r.source.closeActiveChunkStream()
        r.activeFragment = nil
        r.armFragmentTrace = true
        r.eof = false

        guard excludedAnchorPTS.isFinite else { return nil }
        let excluded = max(0, excludedAnchorPTS)
        if r.segments.isEmpty {
            r.cursor = r.mediaStart
            try await extendFragmentIndex(&r, through: excluded)
            guard let rejectedAnchor = seekAnchor(
                in: r,
                to: excluded,
                kind: "video"
            ),
            let rejectedIndex = r.fragmentIndex.lastIndex(where: {
                $0.offset == rejectedAnchor.offset
            }),
            rejectedIndex > 0,
            let earlier = r.fragmentIndex[..<rejectedIndex].last(where: {
                $0.startsWithKeyframe
            }) else {
                PlayerLog.log(
                    "[PathA][continuation] no earlier unindexed video authority " +
                    "excluded=\(String(format: "%.3f", excluded)) " +
                    "index=\(r.fragmentIndex.count)"
                )
                return nil
            }
            r.cursor = earlier.offset
            PlayerLog.log(
                "[PathA][continuation] earlier unindexed video authority " +
                "excluded=\(String(format: "%.3f", excluded)) " +
                "anchor=\(String(format: "%.3f", earlier.startPTS)) " +
                "index=\(r.fragmentIndex.count)"
            )
        } else {
            let rejectedIndex = r.segments.lastIndex {
                $0.presentationStartSeconds <= excluded + 1e-6
            } ?? 0
            guard rejectedIndex > 0,
                  let earlierIndex = try await latestSyncRootedSidxIndex(
                    in: r,
                    atOrBefore: rejectedIndex - 1
                  ) else {
                PlayerLog.log(
                    "[PathA][continuation] no earlier sidx video authority " +
                    "excluded=\(String(format: "%.3f", excluded)) " +
                    "segment=\(rejectedIndex + 1)/\(r.segments.count)"
                )
                return nil
            }
            let earlier = r.segments[earlierIndex]
            r.cursor = earlier.offset
            PlayerLog.log(
                "[PathA][continuation] earlier sidx video authority " +
                "excluded=\(String(format: "%.3f", excluded)) " +
                "anchor=\(String(format: "%.3f", earlier.presentationStartSeconds)) " +
                "segment=\(earlierIndex + 1)/\(r.segments.count)"
            )
        }
        return r
    }

    private static func sapCensus(
        of segments: [PathAFMP4.SidxEntry],
        selected: PathAFMP4.SidxEntry
    ) -> String {
        var closed = 0
        var withSAP = 0
        for entry in segments {
            if entry.declaresClosedGOPStart { closed += 1 }
            if entry.startsWithSAP { withSAP += 1 }
        }
        return "sap=\(selected.declaresClosedGOPStart ? 1 : 0)/type\(selected.sapType) " +
            "declared=\(closed)closed/\(withSAP)withSAP/\(segments.count)"
    }

    private static func latestSyncRootedSidxIndex(
        in reader: TrackReader,
        atOrBefore upperIndex: Int
    ) async throws -> Int? {
        guard !reader.segments.isEmpty else { return nil }
        let upper = min(max(0, upperIndex), reader.segments.count - 1)
        let lower = max(0, upper - earlierContinuitySidxScanLimit + 1)
        for index in stride(from: upper, through: lower, by: -1) {
            try Task.checkCancellation()
            if try await sidxEntryStartsWithSyncSample(
                reader.segments[index],
                reader: reader
            ) {
                return index
            }
        }
        return nil
    }

    private static func sidxEntryStartsWithSyncSample(
        _ entry: PathAFMP4.SidxEntry,
        reader: TrackReader
    ) async throws -> Bool {
        try await sidxEntrySyncTiming(entry, reader: reader) != nil
    }

    private static func sidxEntrySyncTiming(
        _ entry: PathAFMP4.SidxEntry,
        reader: TrackReader,
        maximumHeaders: Int? = nil
    ) async throws -> PathAFMP4.FragmentTiming? {
        guard entry.offset >= 0, entry.size > 0 else { return nil }
        let referenceEndResult = entry.offset.addingReportingOverflow(entry.size)
        guard !referenceEndResult.overflow else { return nil }
        let referenceEnd = referenceEndResult.partialValue
        if reader.endByte > 0, referenceEnd > reader.endByte {
            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                phase: .sidx, field: "reference", reason: "exceeds_resource",
                offset: entry.offset
            ))
        }
        var cursor = entry.offset
        let end = referenceEnd
        guard end >= cursor else { return nil }
        var headers = 0
        while end - cursor >= 8 {
            if let maximumHeaders, headers >= maximumHeaders { return nil }
            headers += 1
            guard let header = try await readBoxHeader(
                reader.source,
                at: cursor,
                containingEnd: reader.endByte > 0 ? reader.endByte : nil
            ),
                  header.size >= header.headerLength else {
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .sidx, field: "fragmentHeader", reason: "malformed",
                    offset: cursor
                ))
            }
            let headerEndResult = cursor.addingReportingOverflow(header.size)
            guard !headerEndResult.overflow, headerEndResult.partialValue <= end else {
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .sidx, field: "fragmentBox", reason: "truncated",
                    offset: cursor
                ))
            }
            let headerEnd = headerEndResult.partialValue
            if header.type == "moof" {
                guard header.size <= headMaxBytes else { return nil }
                let moof = try await reader.source.read(
                    offset: Int64(cursor),
                    count: header.size
                )
                guard moof.count <= header.size else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "readSize",
                        reason: "exceeds_request", availableBytes: moof.count,
                        offset: cursor
                    ))
                }
                guard moof.count == header.size else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "size", reason: "truncated",
                        availableBytes: moof.count, offset: cursor
                    ))
                }
                switch PathAFMP4.fragmentTimingResult(
                    moof,
                    moofRange: 0..<moof.count,
                    track: reader.track,
                    segmentByteOffset: cursor
                ) {
                case .success(let timing):
                    return timing?.startsWithKeyframe == true ? timing : nil
                case .needMoreData(let required):
                    throw PathAFMP4.ParseError.needMoreData(requiredBytes: required)
                case .malformed(let failure):
                    throw PathAFMP4.ParseError.malformed(failure)
                case .unsupported(let unsupported):
                    throw PathAFMP4.ParseError.unsupported(unsupported)
                }
            }
            cursor = headerEnd
        }
        return nil
    }

    private static func extendFragmentIndex(
        _ reader: inout TrackReader,
        through mediaTime: TimeInterval
    ) async throws {
        guard !reader.fragmentIndexComplete else { return }
        let target = max(0, mediaTime.isFinite ? mediaTime : 0)
        if reader.fragmentIndex.contains(where: { $0.endPTS > target + 1e-6 }) {
            return
        }

        while !reader.fragmentIndexComplete {
            if reader.endByte > 0 {
                guard reader.fragmentIndexCursor >= 0,
                      reader.fragmentIndexCursor <= reader.endByte,
                      reader.endByte - reader.fragmentIndexCursor >= 8 else {
                    reader.fragmentIndexComplete = true
                    break
                }
            }

            let fragmentOffset = reader.fragmentIndexCursor
            guard let header = try await readBoxHeader(
                reader.source,
                at: fragmentOffset,
                containingEnd: reader.endByte > 0 ? reader.endByte : nil,
                recordReadPosition: false
            ), header.size >= header.headerLength else {
                reader.fragmentIndexComplete = true
                break
            }
            if reader.endByte > 0 {
                let headerEndResult = fragmentOffset.addingReportingOverflow(header.size)
                guard !headerEndResult.overflow,
                      headerEndResult.partialValue <= reader.endByte else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, field: "boxEnd", reason: "exceeds_resource",
                        offset: fragmentOffset
                    ))
                }
            }

            if header.type == "moof" {
                let moof = try await reader.source.read(
                    offset: Int64(fragmentOffset),
                    count: header.size,
                    recordReadPosition: false
                )
                guard moof.count <= header.size else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "readSize",
                        reason: "exceeds_request", availableBytes: moof.count,
                        offset: fragmentOffset
                    ))
                }
                guard moof.count == header.size else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "size", reason: "truncated",
                        availableBytes: moof.count, offset: fragmentOffset
                    ))
                }

                let mdatOffsetResult = fragmentOffset.addingReportingOverflow(header.size)
                guard !mdatOffsetResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "end", reason: "overflow",
                        offset: fragmentOffset
                    ))
                }
                let mdatOffset = mdatOffsetResult.partialValue
                guard let mdatHeader = try await readBoxHeader(
                    reader.source,
                    at: mdatOffset,
                    containingEnd: reader.endByte > 0 ? reader.endByte : nil,
                    recordReadPosition: false
                ) else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "mdat", reason: "missing",
                        offset: mdatOffset
                    ))
                }
                guard mdatHeader.type == "mdat", mdatHeader.size >= 8 else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "moof", field: "mdat", reason: "missing",
                        offset: mdatOffset
                    ))
                }

                let parsedSamples: [PathAFMP4.Sample]
                switch PathAFMP4.parseFragmentResult(
                    moof,
                    segmentByteOffset: fragmentOffset,
                    moofRange: 0..<moof.count,
                    tracks: [reader.track]
                ) {
                case .success(let value): parsedSamples = value
                case .needMoreData(let required):
                    throw PathAFMP4.ParseError.needMoreData(requiredBytes: required)
                case .malformed(let failure):
                    throw PathAFMP4.ParseError.malformed(failure)
                case .unsupported(let unsupported):
                    throw PathAFMP4.ParseError.unsupported(unsupported)
                }
                let samples = reader.requiresExactFragmentTrackID
                    ? parsedSamples.filter { $0.trackID == reader.track.trackID }
                    : parsedSamples
                let timingResolution: PathAFMP4.AudioTimingResolution?
                if var audioTiming = reader.audioTiming, !samples.isEmpty {
                    let resolved = try audioTiming.observe(samples.map(\.durationTicks))
                    reader.audioTiming = audioTiming
                    timingResolution = resolved
                } else {
                    timingResolution = nil
                }
                let timescale = timingResolution?.effectiveTimescale
                    ?? Double(max(1, reader.track.timescale))
                if !samples.isEmpty {
                    guard reader.fragmentIndex.count < maxFragmentIndexEntries else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .fragment, field: "indexCount", reason: "ceiling",
                            declaredCount: UInt64(reader.fragmentIndex.count + 1),
                            offset: fragmentOffset
                        ))
                    }
                    let firstDecodeSample = samples.min { lhs, rhs in
                        if lhs.dtsTicks != rhs.dtsTicks { return lhs.dtsTicks < rhs.dtsTicks }
                        return lhs.ptsTicks < rhs.ptsTicks
                    }
                    let startTicks = samples.map(\.ptsTicks).min() ?? 0
                    var endTicks = startTicks
                    for sample in samples {
                        let sampleEndResult = sample.ptsTicks.addingReportingOverflow(
                            Int64(sample.durationTicks)
                        )
                        guard !sampleEndResult.overflow else {
                            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                                phase: .timing, field: "sampleEnd", reason: "overflow",
                                offset: fragmentOffset
                            ))
                        }
                        endTicks = max(endTicks, sampleEndResult.partialValue)
                    }
                    let startPTS = Double(startTicks) / timescale
                    let endPTS = Double(endTicks) / timescale
                    guard startPTS.isFinite, endPTS.isFinite else {
                        throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                            phase: .timing, field: "range", reason: "nonfinite",
                            offset: fragmentOffset
                        ))
                    }
                    reader.fragmentIndex.append(FragmentIndexEntry(
                        offset: fragmentOffset,
                        startPTS: startPTS,
                        endPTS: endPTS,
                        startsWithKeyframe: firstDecodeSample?.isKeyframe == true
                    ))
                }
                let nextCursorResult = mdatOffset.addingReportingOverflow(mdatHeader.size)
                guard !nextCursorResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, boxType: "mdat", field: "end", reason: "overflow",
                        offset: mdatOffset
                    ))
                }
                reader.fragmentIndexCursor = nextCursorResult.partialValue
            } else {
                let nextCursorResult = fragmentOffset.addingReportingOverflow(header.size)
                guard !nextCursorResult.overflow else {
                    throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                        phase: .fragment, field: "boxEnd", reason: "overflow",
                        offset: fragmentOffset
                    ))
                }
                reader.fragmentIndexCursor = nextCursorResult.partialValue
            }

            if reader.fragmentIndex.contains(where: { $0.endPTS > target + 1e-6 }) {
                return
            }
        }
    }

    private static func seekAnchor(
        in reader: TrackReader,
        to mediaTime: TimeInterval,
        kind: String
    ) -> FragmentIndexEntry? {
        let target = max(0, mediaTime.isFinite ? mediaTime : 0)
        guard !reader.fragmentIndex.isEmpty else { return nil }

        let containing = reader.fragmentIndex.last {
            $0.startPTS <= target + 1e-6 && $0.endPTS > target + 1e-6
        }
        let candidate: FragmentIndexEntry?
        if let containing {
            candidate = containing
        } else if target < (reader.fragmentIndex.first?.startPTS ?? 0) {
            candidate = reader.fragmentIndex.first
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        guard kind == "video" else { return candidate }

        guard let idx = reader.fragmentIndex.lastIndex(where: { $0.offset == candidate.offset }) else {
            return candidate
        }
        return reader.fragmentIndex[...idx].last(where: { $0.startsWithKeyframe }) ?? candidate
    }

    // MARK: - Cached content ahead

    nonisolated var measuresCachedContentAhead: Bool { byteStore != nil }

    nonisolated var displayEvidenceQuery: (any MediaDisplayEvidenceQuerying)? {
        displayAvailability.hasTracks ? displayAvailability : nil
    }

    private func prepareResidentDisplayForPump(video prepareVideo: Bool, audio prepareAudio: Bool) {
        if prepareVideo, video?.displayUsability.isValid == false {
            video?.parsedDisplayFragment = nil
            video?.displayUsability = MediaResidentDisplayUsability()
        }
        if prepareAudio, audio?.displayUsability.isValid == false {
            audio?.parsedDisplayFragment = nil
            audio?.displayUsability = MediaResidentDisplayUsability()
        }
    }

    func retireResidentDisplay(video retireVideo: Bool, audio retireAudio: Bool) async {
        if retireVideo {
            video?.displayUsability.revoke()
            video?.displayUsability = MediaResidentDisplayUsability()
            video?.parsedDisplayFragment = nil
        }
        if retireAudio {
            audio?.displayUsability.revoke()
            audio?.displayUsability = MediaResidentDisplayUsability()
            audio?.parsedDisplayFragment = nil
        }
    }

    func cachedContentAhead() async -> MediaCachedContentAhead {
        let generation = readerMutationGeneration
        let progress = readerProgressRevision
        let video = self.video
        let audio = self.audio
        let videoAhead = await Self.cachedSecondsAhead(video)
        let audioAhead = await Self.cachedSecondsAhead(audio)
        let videoDisplay = await Self.residentDisplayFragment(video)
        let audioDisplay = await Self.residentDisplayFragment(audio)
        guard generation == readerMutationGeneration, progress == readerProgressRevision else { return .empty }
        residentDisplayChanges?.requestRefresh()
        return MediaCachedContentAhead(
            video: videoAhead, audio: audioAhead, videoDisplay: videoDisplay, audioDisplay: audioDisplay
        )
    }

    private func startResidentDisplayObservation(generation: UInt64) async {
        guard let byteStore, displayAvailability.hasTracks else { return }
        let keys = Set([video?.storeBinding?.key, audio?.storeBinding?.key].compactMap { $0 })
        let changes = await byteStore.observeResidentChanges(for: keys)
        guard generation == openGeneration, !Task.isCancelled else {
            changes.finish()
            return
        }
        residentDisplayChanges = changes
        let stream = changes.stream
        residentDisplayRefreshTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                while await self?.refreshFutureDisplayEvidence(generation: generation) == true {
                    await Task.yield()
                    if Task.isCancelled { return }
                }
            }
        }
    }

    private func stopResidentDisplayObservation() {
        residentDisplayRefreshTask?.cancel()
        residentDisplayRefreshTask = nil
        residentDisplayChanges?.finish()
        residentDisplayChanges = nil
    }

    private func refreshFutureDisplayEvidence(generation open: UInt64) async -> Bool {
        guard open == openGeneration, !Task.isCancelled else { return false }
        let generation = readerMutationGeneration
        let progress = readerProgressRevision
        let video = self.video
        let audio = self.audio
        let videoFuture = await inspectResidentDisplayFragments(
            video, limit: 4, existing: futureDisplayLeases[.video] ?? [:],
            generation: generation, progress: progress
        )
        let audioFuture = await inspectResidentDisplayFragments(
            audio, limit: 4, existing: futureDisplayLeases[.audio] ?? [:],
            generation: generation, progress: progress
        )
        guard open == openGeneration, !Task.isCancelled else { return false }
        guard generation == readerMutationGeneration, progress == readerProgressRevision else { return true }
        futureDisplayLeases[.video] = videoFuture.roster.isEmpty ? nil : videoFuture.roster
        futureDisplayLeases[.audio] = audioFuture.roster.isEmpty ? nil : audioFuture.roster
        return videoFuture.reachedLimit || audioFuture.reachedLimit
    }

    private func inspectResidentDisplayFragments(
        _ reader: TrackReader?, limit: Int, existing: [Int64: ResidentDisplayOwnership],
        generation: UInt64, progress: UInt64
    ) async -> (roster: [Int64: ResidentDisplayOwnership], reachedLimit: Bool) {
        guard let source = residentDisplaySource(reader) else { return ([:], false) }
        let snapshot = source.snapshot
        let track = source.track
        let binding = source.binding
        guard residentEvidenceIsCurrent(generation: generation, progress: progress, snapshot: snapshot)
        else { return ([:], false) }
        let containingEnd = snapshot.endByte > 0 ? snapshot.endByte : nil
        var cursor = snapshot.activeFragment.map { $0.fragmentStart + $0.fragmentTotal } ?? snapshot.cursor
        guard cursor >= 0 else { return ([:], false) }
        let retentionFloor = snapshot.activeFragment?.fragmentStart ?? snapshot.cursor
        track.removeLayouts(below: Int64(retentionFloor))
        var roster = existing.filter { $0.key >= Int64(cursor) && $0.value.leases.allSatisfy(\.isCurrent) }
        var parsedCount = 0
        while parsedCount < limit {
            if let held = roster[Int64(cursor)] {
                cursor = held.nextOffset
                continue
            }
            switch await residentBoxStep(
                binding: binding, cursor: cursor, containingEnd: containingEnd
            ) {
            case .stop:
                return (roster, false)
            case .advance(let next):
                cursor = next
            case .fragment(let moof, let payload):
                cursor = payload.upperBound
                parsedCount += 1
                guard let evidence = await residentDisplaySamples(
                    binding: binding, moof: moof, payload: payload, snapshot: snapshot
                ), residentEvidenceIsCurrent(
                    generation: generation, progress: progress, snapshot: snapshot
                ) else { return (roster, false) }
                track.install(
                    evidence.samples, fragment: Int64(moof.lowerBound),
                    metadataResidency: evidence.metadata
                )
                let range = Int64(payload.lowerBound)..<Int64(payload.upperBound)
                if let lease = track.own(
                    bytes: range, residency: evidence.payload, metadataResidency: evidence.metadata
                ) {
                    roster[Int64(moof.lowerBound)] = ResidentDisplayOwnership(
                        nextOffset: payload.upperBound, leases: [lease]
                    )
                } else {
                    return (roster, false)
                }
            }
        }
        return (roster, true)
    }

    private static func parsedDisplayFragment(
        samples: [MediaDisplaySample], expectedSampleCount: Int, bytes: Range<Int64>,
        declaredTimescale: UInt32, residency: MediaByteRangeStore.ResidentValidity
    ) -> ParsedDisplayFragment? {
        guard residency.isValid, bytes.lowerBound >= 0, !bytes.isEmpty, declaredTimescale > 0,
              !samples.isEmpty, samples.count == expectedSampleCount else { return nil }
        let sorted = samples.map(\.interval).sorted { $0.lower < $1.lower }
        guard let first = sorted.first else { return nil }
        var end = first.upper
        for interval in sorted.dropFirst() {
            guard interval.lower <= end else { return nil }
            end = max(end, interval.upper)
        }
        let lower = first.lower.seconds
        let upper = end.seconds
        guard lower.isFinite, upper.isFinite, upper > lower else { return nil }
        return ParsedDisplayFragment(
            bytes: bytes, metadataResidency: residency, lower: lower, upper: upper
        )
    }

    private static func residentDisplayFragment(_ reader: TrackReader?) async -> MediaResidentDisplayFragment? {
        guard let reader, !reader.isFileSource, reader.displayUsability.isValid,
              let binding = reader.storeBinding, let parsed = reader.parsedDisplayFragment,
              parsed.metadataResidency.isValid,
              let held = await binding.store.residentRun(binding.key, from: parsed.bytes.lowerBound),
              parsed.metadataResidency.isValid, reader.displayUsability.isValid,
              held.validity.sharesIncarnation(with: parsed.metadataResidency),
              let payloadResidency = held.validity.narrowed(to: parsed.bytes) else { return nil }
        return MediaResidentDisplayFragment(
            lower: parsed.lower, upper: parsed.upper, residency: payloadResidency, usability: reader.displayUsability
        )
    }

    private static func cachedSecondsAhead(_ reader: TrackReader?) async -> MediaCachedTrackContentAhead {
        guard let reader, !reader.eof, let binding = reader.storeBinding,
              !reader.isFileSource else { return .empty }
        let start = Int64(reader.activeFragment?.assembler.resumeOffset ?? reader.cursor)
        guard let held = await binding.store.residentRun(binding.key, from: start) else { return .empty }
        guard let measurement = PathACachedFragmentRunway.measurement(
            from: start,
            heldBytes: held.byteCount,
            fragments: cachedRunwayFragments(of: reader, startingAt: start, heldBytes: held.byteCount)
        ), let validity = held.validity.narrowed(to: measurement.bytes) else { return .empty }
        return MediaCachedTrackContentAhead(seconds: measurement.seconds, validity: validity)
    }

    private static func cachedRunwayFragments(
        of reader: TrackReader,
        startingAt start: Int64,
        heldBytes: Int64
    ) -> [PathACachedFragmentRunway.Fragment] {
        let heldEnd = MediaByteRange.checkedEndExclusive(offset: start, length: heldBytes) ?? start
        let inWindow = { (offset: Int) in Int64(offset) >= start && Int64(offset) < heldEnd }
        if !reader.segments.isEmpty {
            return reader.segments.filter { inWindow($0.offset) }.map {
                .init(offset: Int64($0.offset), size: Int64($0.size), duration: $0.durationSeconds)
            }
        }
        let index = reader.fragmentIndex
        return index.indices.filter { inWindow(index[$0].offset) }.map { position in
            let entry = index[position]
            let end = position + 1 < index.count ? index[position + 1].offset : reader.fragmentIndexCursor
            return .init(
                offset: Int64(entry.offset),
                size: Int64(end - entry.offset),
                duration: entry.endPTS - entry.startPTS
            )
        }
    }

    func close() async {
        openGeneration &+= 1
        stopResidentDisplayObservation()
        activeForwardReceipt = nil
        readerMutationGeneration &+= 1
        retireDisplayUsability()
        retireDisplayTracks()
        await retireOpenPrefetchAndStoreProtection(closeStreams: true, resetReaders: true)
    }

    func retireLiveStreams() async {
        await multiConnectionPrefetcher?.park()
        await closeActiveStreams()
    }

    func interruptActiveIO() async -> MediaDemuxIOInterruptResult {
        var interrupted = false
        if let reader = video {
            interrupted = await reader.source.interruptActiveIO() == .interrupted || interrupted
        }
        if let reader = audio {
            interrupted = await reader.source.interruptActiveIO() == .interrupted || interrupted
        }
        return interrupted ? .interrupted : .noActiveOperation
    }

    private func closeActiveStreams() async {
        if let reader = video {
            await reader.source.closeActiveChunkStream()
        }
        if let reader = audio {
            await reader.source.closeActiveChunkStream()
        }
    }

    // MARK: - helpers

    private struct BoxHeader {
        let size: Int
        let type: String
        let headerLength: Int
        let extendsToContainingEnd: Bool
    }

    private static func readBoxHeader(
        _ source: PathAHTTPMediaSource,
        at offset: Int,
        containingEnd: Int? = nil,
        recordReadPosition: Bool = true
    ) async throws -> BoxHeader? {
        guard offset >= 0 else { return nil }
        let bytes = try await source.read(
            offset: Int64(offset), count: 16, recordReadPosition: recordReadPosition
        )
        guard bytes.count <= 16 else {
            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                phase: .box, field: "readSize", reason: "exceeds_request",
                availableBytes: bytes.count, offset: offset
            ))
        }
        guard let header = parseBoxHeader(bytes, at: 0) else {
            guard bytes.isEmpty else {
                throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                    phase: .box, field: "header", reason: "truncated_or_invalid",
                    availableBytes: bytes.count, offset: offset
                ))
            }
            return nil
        }
        return try resolveBoxHeader(header, at: offset, containingEnd: containingEnd)
    }

    private static func resolveBoxHeader(
        _ header: BoxHeader,
        at offset: Int,
        containingEnd: Int?
    ) throws -> BoxHeader {
        guard header.extendsToContainingEnd else { return header }
        guard let containingEnd else {
            throw PathAFMP4.ParseError.unsupported(PathAFMP4.ParseUnsupported(
                phase: .box, boxType: header.type, field: "size",
                reason: "size_zero_open_ended"
            ))
        }
        guard offset >= 0, containingEnd >= offset else {
            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                phase: .box, boxType: header.type, field: "size", reason: "range",
                offset: offset
            ))
        }
        let size = containingEnd - offset
        guard size >= header.headerLength else {
            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                phase: .box, boxType: header.type, field: "size", reason: "truncated",
                availableBytes: size, offset: offset
            ))
        }
        guard size <= PathAFMP4.maxBoxSize else {
            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                phase: .box, boxType: header.type, field: "size", reason: "ceiling",
                offset: offset
            ))
        }
        return BoxHeader(
            size: size,
            type: header.type,
            headerLength: header.headerLength,
            extendsToContainingEnd: false
        )
    }

    private static func parseBoxHeader(_ data: Data, at offset: Int) -> BoxHeader? {
        guard offset >= 0, offset <= data.count,
              data.count - offset >= 8 else { return nil }
        let b = [UInt8](data.dropFirst(offset).prefix(16))
        let size32 = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        guard let type = String(bytes: b[4..<8], encoding: .ascii) else { return nil }
        if size32 == 1 {
            guard b.count >= 16 else { return nil }
            var large: UInt64 = 0
            for i in 8..<16 { large = large << 8 | UInt64(b[i]) }
            guard large >= 16,
                  large <= UInt64(Int.max),
                  large <= UInt64(PathAFMP4.maxBoxSize) else { return nil }
            return BoxHeader(
                size: Int(large), type: type, headerLength: 16,
                extendsToContainingEnd: false
            )
        }
        if size32 == 0 {
            return BoxHeader(
                size: 0, type: type, headerLength: 8,
                extendsToContainingEnd: true
            )
        }
        guard size32 >= 8 else { return nil }
        guard size32 <= UInt32(PathAFMP4.maxBoxSize) else { return nil }
        return BoxHeader(
            size: Int(size32), type: type, headerLength: 8,
            extendsToContainingEnd: false
        )
    }

    private func resetOpenState() {
        video = nil
        audio = nil
        _duration = 0
        _movieDuration = 0
        synthesizedDurationSamples = [:]
        latchedParseFailure = nil
    }

    private static func mediaError(
        for error: PathAFMP4.ParseError,
        context: String
    ) -> MediaEngineError {
        switch error {
        case .needMoreData(let requiredBytes):
            return .fMP4InputRejected(
                "fMP4 \(context) needs more data (bytes=\(max(0, requiredBytes)))"
            )
        case .malformed(let failure):
            return .fMP4InputRejected("fMP4 \(context) malformed: \(failure.summary)")
        case .unsupported(let unsupported):
            return .fMP4InputRejected("fMP4 \(context) unsupported: \(unsupported.summary)")
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private static func pathAKind(_ k: PathAFMP4.TrackKind) -> MediaTrackKind {
        k == .video ? .video : .audio
    }
}

private extension PathAFMP4Demuxer {
    private struct PrefetchInput {
        let kind: MediaTrackKind
        let reader: TrackReader?
        let primary: URL?
        let alternates: [URL]
    }

    var prefetchCursors: [Int64] {
        prefetchTrackKinds.map { kind in
            let reader = kind == .video ? video : audio
            return Int64(reader?.activeFragment?.assembler.resumeOffset ?? reader?.cursor ?? 0)
        }
    }

    private func openMultiConnectionPrefetcher(_ request: MediaOpenRequest, generation: UInt64) async {
        multiConnectionAdmission = request.alternateVideoURLs.isEmpty && request.alternateAudioURLs.isEmpty
            ? .notConfigured : .unavailable
        guard MultiConnectionPrefetcher.isEnabled(), let byteStore, let policy = request.multiConnectionPolicy,
              let ahead = request.readAheadSeconds, ahead.isFinite, ahead > 0 else { return }
        var tracks: [MultiConnectionPrefetcher.Track] = []
        var kinds: [MediaTrackKind] = []
        let inputs = [
            PrefetchInput(kind: .video, reader: video, primary: request.videoURL,
                          alternates: request.alternateVideoURLs),
            PrefetchInput(kind: .audio, reader: audio, primary: request.audioURL,
                          alternates: request.alternateAudioURLs)
        ]
        for input in inputs {
            guard let reader = input.reader, let primary = input.primary,
                  !reader.isFileSource, let binding = reader.storeBinding,
                  !reader.segments.isEmpty else { continue }
            let helpers = MultiConnectionPlanner.helperURLs(input.alternates, primary: primary)
            guard !helpers.isEmpty else { continue }
            let tier1Hosts = MultiConnectionPlanner.tier1Hosts(
                for: helpers, primary: primary, verifiedAPIHosts: policy.verifiedAPIHosts
            )
            let fragments = reader.segments.compactMap { segment -> MultiConnectionPlanner.Fragment? in
                guard let end = MediaByteRange.checkedEndExclusive(
                    offset: Int64(segment.offset), length: Int64(segment.size)
                ), end <= binding.key.contentLength else { return nil }
                return .init(
                    range: Int64(segment.offset)..<end, startSeconds: segment.presentationStartSeconds,
                    durationSeconds: segment.durationSeconds
                )
            }
            tracks.append(.init(
                key: binding.key, helpers: helpers, tier1Hosts: tier1Hosts, fragments: fragments,
                cursor: Int64(reader.activeFragment?.assembler.resumeOffset ?? reader.cursor),
                primaryHost: primary.host
            ))
            kinds.append(input.kind)
        }
        guard !tracks.isEmpty, generation == openGeneration else { return }
        multiConnectionPosition = request.startPosition
        multiConnectionRate = request.preferredRate
        let prefetcher = MultiConnectionPrefetcher(
            store: byteStore, tracks: tracks, ahead: ahead, headers: request.headers,
            position: request.startPosition, rate: request.preferredRate, quiet: multiConnectionQuiet,
            quietGate: request.multiConnectionQuietGate, policy: policy,
            networkBytes: request.networkByteCounter
        )
        multiConnectionPrefetcher = prefetcher
        prefetchTrackKinds = kinds
        await installTailAssistHints(
            prefetcher: prefetcher, tracks: tracks, kinds: kinds, generation: generation
        )
        guard generation == openGeneration, multiConnectionPrefetcher === prefetcher else { return }
        await prefetcher.start()
    }

    private func installTailAssistHints(
        prefetcher: MultiConnectionPrefetcher,
        tracks: [MultiConnectionPrefetcher.Track],
        kinds: [MediaTrackKind],
        generation: UInt64
    ) async {
        var bindings: [(PathAHTTPMediaSource, PathAHTTPMediaSource.TailAssistHint)] = []
        for (trackIndex, kind) in kinds.enumerated() where trackIndex < tracks.count {
            guard let reader = kind == .video ? video : audio else { continue }
            let track = tracks[trackIndex]
            let totalDuration = track.fragments.reduce(0.0) { $0 + $1.durationSeconds }
            let byteRate = totalDuration.isFinite && totalDuration > 0
                ? Double(track.key.contentLength) / totalDuration : 0
            let hint = PathAHTTPMediaSource.TailAssistHint(
                trackByteRate: byteRate,
                isAvailable: { [weak prefetcher] in
                    prefetcher?.isTailAssistAvailable(for: trackIndex) ?? false
                },
                notifyTailAvailable: { [weak self] in
                    Task { await self?.notifyPrimaryTailSplit(generation: generation) }
                },
                requestUrgentAssist: { [weak prefetcher] range, excludePrimaryHost in
                    await prefetcher?.assistUrgentRange(
                        trackIndex: trackIndex, range: range, excludePrimaryHost: excludePrimaryHost
                    ) ?? false
                }
            )
            bindings.append((reader.source, hint))
        }
        for (source, hint) in bindings {
            guard generation == openGeneration, multiConnectionPrefetcher === prefetcher else { return }
            await source.setTailAssistHint(hint)
        }
    }

    private func registerActiveStorePaths(generation: UInt64, readerGeneration: UInt64) async throws {
        guard let byteStore else { return }
        let paths = Set([video?.storeBinding?.key.path, audio?.storeBinding?.key.path].compactMap { $0 })
        guard !paths.isEmpty else { return }
        let token = await byteStore.registerActivePaths(paths)
        guard generation == openGeneration, readerGeneration == readerMutationGeneration, !Task.isCancelled else {
            await byteStore.unregisterActivePaths(token)
            throw MediaEngineError.stopped
        }
        activeStorePathsToken = token
    }

    private func retireOpenPrefetchAndStoreProtection(closeStreams: Bool, resetReaders: Bool) async {
        let prefetcher = multiConnectionPrefetcher
        let videoSource = video?.source
        let audioSource = audio?.source
        let storeToken = activeStorePathsToken
        multiConnectionPrefetcher = nil
        prefetchTrackKinds = []
        prefetchSeekGeneration = nil
        activeStorePathsToken = nil
        if resetReaders { resetOpenState() }
        await prefetcher?.cancel()
        await videoSource?.setTailAssistHint(nil)
        await audioSource?.setTailAssistHint(nil)
        if closeStreams {
            await videoSource?.closeActiveChunkStream()
            await audioSource?.closeActiveChunkStream()
        }
        if let storeToken { await byteStore?.unregisterActivePaths(storeToken) }
    }

    private func notifyPrimaryTailSplit(generation: UInt64) async {
        guard generation == openGeneration else { return }
        await refreshMultiConnectionCursors()
    }

    private func refreshMultiConnectionCursors() async {
        guard prefetchSeekGeneration == nil else { return }
        await multiConnectionPrefetcher?.update(
            cursors: prefetchCursors, position: multiConnectionPosition, rate: multiConnectionRate
        )
    }
}

extension PathAFMP4Demuxer {
    func multiConnectionTelemetry() async -> MultiConnectionTelemetry {
        guard let prefetcher = multiConnectionPrefetcher else {
            return MultiConnectionTelemetry(state: multiConnectionAdmission)
        }
        let fence = openGeneration
        let result = await prefetcher.telemetry()
        guard openGeneration == fence, multiConnectionPrefetcher === prefetcher else { return .unsupported }
        return result
    }

    func setMultiConnectionQuiet(_ quiet: Bool) async {
        multiConnectionQuiet = quiet
        await multiConnectionPrefetcher?.setQuiet(quiet)
    }

    func updateMultiConnectionPlayback(position: TimeInterval, rate: Float) async {
        multiConnectionPosition = position
        multiConnectionRate = rate
        await refreshMultiConnectionCursors()
    }

    func cancelMultiConnectionPrefetching() async {
        let videoSource = video?.source
        let audioSource = audio?.source
        let prefetcher = multiConnectionPrefetcher
        await videoSource?.setTailAssistHint(nil)
        await audioSource?.setTailAssistHint(nil)
        await prefetcher?.cancel()
    }
}

private extension PathAFMP4Demuxer {
    private struct ResidentDisplaySource {
        let snapshot: TrackReader
        let track: MediaDisplayTrack
        let binding: PathAByteStoreBinding
    }

    private struct ResidentDisplayEvidence {
        let samples: [MediaDisplaySample]
        let payload: MediaByteRangeStore.ResidentValidity
        let metadata: MediaByteRangeStore.ResidentValidity
    }

    private enum ResidentBoxStep {
        case advance(Int)
        case fragment(moof: Range<Int>, payload: Range<Int>)
        case stop
    }

    private func residentDisplaySource(_ reader: TrackReader?) -> ResidentDisplaySource? {
        guard let snapshot = reader, !snapshot.isFileSource, snapshot.displayUsability.isValid,
              let track = snapshot.displayTrack, let binding = snapshot.storeBinding,
              snapshot.track.timescale > 0 else { return nil }
        return ResidentDisplaySource(snapshot: snapshot, track: track, binding: binding)
    }

    private func residentEvidenceIsCurrent(
        generation: UInt64, progress: UInt64, snapshot: TrackReader
    ) -> Bool {
        generation == readerMutationGeneration
            && progress == readerProgressRevision
            && !Task.isCancelled
            && snapshot.displayUsability.isValid
    }

    private static func readResidentBoxHeader(
        binding: PathAByteStoreBinding, at offset: Int, containingEnd: Int?
    ) async -> BoxHeader? {
        guard offset >= 0,
              let (bytes, _) = await binding.store.displayPrefix(
                  binding.key, offset: Int64(offset), count: 16
              ),
              bytes.count >= 8,
              let header = parseBoxHeader(bytes, at: 0) else { return nil }
        return try? resolveBoxHeader(header, at: offset, containingEnd: containingEnd)
    }

    private func residentPayloadRange(
        binding: PathAByteStoreBinding, after moofEnd: Int, containingEnd: Int?
    ) async -> Range<Int>? {
        guard let mdat = await Self.readResidentBoxHeader(
            binding: binding, at: moofEnd, containingEnd: containingEnd
        ), mdat.type == "mdat", mdat.size >= mdat.headerLength else { return nil }
        let payloadStart = moofEnd.addingReportingOverflow(mdat.headerLength)
        let fragmentEnd = moofEnd.addingReportingOverflow(mdat.size)
        guard !payloadStart.overflow, !fragmentEnd.overflow else { return nil }
        if let containingEnd, fragmentEnd.partialValue > containingEnd { return nil }
        return payloadStart.partialValue..<fragmentEnd.partialValue
    }

    private func residentBoxStep(
        binding: PathAByteStoreBinding, cursor: Int, containingEnd: Int?
    ) async -> ResidentBoxStep {
        guard let header = await Self.readResidentBoxHeader(
            binding: binding, at: cursor, containingEnd: containingEnd
        ), header.size > 0 else { return .stop }
        if header.type != "moof" {
            let next = cursor.addingReportingOverflow(header.size)
            return next.overflow ? .stop : .advance(next.partialValue)
        }
        guard header.size <= Self.headMaxBytes else { return .stop }
        let end = cursor.addingReportingOverflow(header.size)
        guard !end.overflow else { return .stop }
        let moofEnd = end.partialValue
        guard let payload = await residentPayloadRange(
            binding: binding, after: moofEnd, containingEnd: containingEnd
        ) else { return .stop }
        return .fragment(moof: cursor..<moofEnd, payload: payload)
    }

    private func residentPayloadReceipt(
        binding: PathAByteStoreBinding, range: Range<Int64>
    ) async -> MediaByteRangeStore.ResidentValidity? {
        guard let held = await binding.store.residentRun(binding.key, from: range.lowerBound),
              held.byteCount >= Int64(range.count),
              let receipt = held.validity.narrowed(to: range) else { return nil }
        return receipt
    }

    private func residentDisplaySamples(
        binding: PathAByteStoreBinding, moof: Range<Int>, payload: Range<Int>,
        snapshot: TrackReader
    ) async -> ResidentDisplayEvidence? {
        let metadataCount = payload.lowerBound - moof.lowerBound
        guard metadataCount > moof.count, metadataCount <= Self.headMaxBytes,
              let (moofData, metadata) = await binding.store.displayPrefix(
                  binding.key, offset: Int64(moof.lowerBound), count: metadataCount
              ), moofData.count == metadataCount,
              let header = Self.parseBoxHeader(moofData, at: moof.count), header.type == "mdat",
              let resolved = try? Self.resolveBoxHeader(
                  header, at: moof.upperBound,
                  containingEnd: snapshot.endByte > 0 ? snapshot.endByte : nil
              ), resolved.headerLength == metadataCount - moof.count,
              resolved.size == payload.upperBound - moof.upperBound else { return nil }
        guard case .success(let parsed) = PathAFMP4.parseFragmentResult(
            moofData,
            segmentByteOffset: moof.lowerBound,
            moofRange: 0..<moof.count,
            tracks: [snapshot.track],
            sampleDataRange: payload
        ) else { return nil }
        let kept = snapshot.requiresExactFragmentTrackID
            ? parsed.filter { $0.trackID == snapshot.track.trackID }
            : parsed
        guard !kept.isEmpty else { return nil }
        let timescale: Double
        if var audioTiming = snapshot.audioTiming {
            guard let resolution = try? audioTiming.observe(kept.map(\.durationTicks)) else { return nil }
            timescale = resolution.effectiveTimescale
        } else {
            timescale = Double(snapshot.track.timescale)
        }
        let samples = Self.displaySamples(
            kept, kind: snapshot.track.kind, fragment: moof.lowerBound, timescale: timescale
        )
        guard samples.count == kept.count else { return nil }
        let range = Int64(payload.lowerBound)..<Int64(payload.upperBound)
        guard let receipt = await residentPayloadReceipt(binding: binding, range: range),
              metadata.isValid, receipt.isValid, metadata.sharesIncarnation(with: receipt) else {
            return nil
        }
        return ResidentDisplayEvidence(samples: samples, payload: receipt, metadata: metadata)
    }
}
