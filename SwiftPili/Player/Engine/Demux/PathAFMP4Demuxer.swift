import Foundation

/// Path A D2 — in-house fragmented-MP4 demuxer for BiliBili dual-URL DASH VOD.
///
/// A thin async shell over the verified pieces: `PathAHTTPMediaSource` (D1) does
/// the byte I/O, `PathAFMP4` (D2 parser) does all bitstream math. This actor
/// only sequences them — open the init segment, walk `moof`+`mdat` fragments,
/// and hand the session compressed `MediaPacket`s. Video and audio are
/// independent readers (separate signed URLs), each with its own byte cursor.
///
/// Fragment discovery is a **sequential `moof` walk** (read box header → if
/// `moof`, pull `moof`+`mdat`, packetize, advance) so it does not depend on a
/// `sidx` being present. `sidx`, when present, is parsed for duration + the seek
/// index (D4). Codec config (avcC/hvcC/av01C/esds) is captured at open and
/// surfaced via `formatConfig(for:)` for the D3 VideoToolbox/audio open.
///
/// F1/C4: this produces packets only; it never advances `mediaTime` — the
/// session owns the clock. Device open+pump DoD (D2a.5) is still open; the
/// byte-critical parsing/slicing is unit-verified off-device.
actor PathAFMP4Demuxer: MediaDemuxing {
    nonisolated let displayAvailability = MediaDisplayAvailability()

    /// Cache-only inspected future fragments, keyed by fragment byte offset.
    /// Each value holds the payload byte leases that qualify those layouts;
    /// dropping the roster retires the evidence. Bounded by the inspection
    /// limit per poll and pruned as the reader passes each fragment.
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
        /// Exact parsed metadata prefix; the receipt retains its immutable
        /// resource incarnation separately from any later payload receipt.
        let metadataResidency: MediaByteRangeStore.ResidentValidity
        let lower: TimeInterval
        let upper: TimeInterval
    }

    private struct TrackReader: Sendable {
        let source: PathAHTTPMediaSource
        let track: PathAFMP4.TrackInfo
        let mediaStart: Int          // byte offset of the first fragment (after moov[+sidx])
        let endByte: Int             // resource length (0 = unknown → walk until a short read)
        var segments: [PathAFMP4.SidxEntry]   // sidx seek index (may be empty)
        var cursor: Int              // next box to read
        var eof: Bool
        /// Lazy fragment index used only when the resource has no sidx. The
        /// scan cursor is independent of playback cursor so seeking does not
        /// destroy the accumulated index.
        var fragmentIndex: [FragmentIndexEntry]
        var fragmentIndexCursor: Int
        var fragmentIndexComplete: Bool
        var audioTiming: AudioTimingState?
        /// Shared/muxed resources require the media fragment to match the
        /// track declared by this reader. Distinct split resources retain the
        /// historical tolerance for origins whose fragment track ID differs
        /// from the init metadata.
        var requiresExactFragmentTrackID: Bool
        /// Present only when the initial request for this network resource
        /// actually returned HTTP 206. `Accept-Ranges` alone is insufficient.
        let parallelPumpIdentity: NetworkResourceIdentity?
        /// Local files stay on the fully-buffered fragment path — local reads
        /// were never the latency the streaming path exists to remove.
        let isFileSource: Bool
        /// The fragment currently being streamed, carried across pump calls.
        /// Non-nil means: layout parsed, samples partially emitted, and (when
        /// `streamID` is set) a live chunk stream open on `source`.
        var activeFragment: ActiveFragmentStream? = nil
        /// Arms the once-per-open/seek `[PathA] mdat-stream …` stage marks for
        /// the NEXT fragment this reader begins.
        var armFragmentTrace = true
        /// The same store key the source bound at `initialHead` (identical
        /// URL and proved length), used only to ask how much of what lies
        /// ahead is already held. Nil without a store or a key.
        var storeBinding: PathAByteStoreBinding?
        var displayUsability = MediaResidentDisplayUsability()
        var parsedDisplayFragment: ParsedDisplayFragment?
        var displayTrack: MediaDisplayTrack?
        var displayResidentBytes: [MediaDisplayLease] = []
    }

    /// Streaming-fragment state: the layout is fully known from the buffered
    /// `moof`; the assembler turns arriving payload bytes into complete samples.
    /// Value-typed like the reader itself — a stale pump's copy dies with the
    /// write-back fence, and the source actor's single stream slot is the only
    /// shared resource (retired at every fence).
    private struct ActiveFragmentStream: Sendable {
        var streamID: UInt64?
        let fragmentStart: Int
        let fragmentTotal: Int
        var assembler: PathAMdatStreamAssembler
        /// Emittable layout entries (zero-size dropped — packetize parity);
        /// `Emitted.sampleIndex` addresses this array.
        let samples: [PathAFMP4.Sample]
        let effectiveTimescale: Double
        var synthesizedEmitted = 0
        var trace: FragmentStreamTrace?
    }

    /// Once-per-open/seek stage timing for the streaming pipeline. The device
    /// metric is `fragment-metadata-ready → first-packet-emitted`: it must not
    /// wait for the full mdat transfer.
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

    /// Per-pump-call consumer-side pacing (diagnostics only). `maxNetWaitMs` is
    /// the longest this pump sat awaiting the NETWORK — chunk delivery or a
    /// probe/spill/tail read — the pump's own view of input starvation, which
    /// naturally excludes parked time. Stream OPEN is deliberately not timed:
    /// `openChunkStream` returns before any network byte moves — its only
    /// suspension is a hop into the byte store — so its await measures
    /// scheduler hops, not the network (connection/TTFB lands in the first
    /// `nextChunk`).
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
    /// Freshness fence for every committed reader write, including relay emits
    /// within one pump generation. This is not a durable reader identity.
    private var readerProgressRevision: UInt64 = 0
    private var _duration: TimeInterval = 0
    private var _movieDuration: TimeInterval = 0
    private var openGeneration: UInt64 = 0
    /// Fences reader value snapshots across actor reentrancy. Operations that
    /// replace or reposition a reader invalidate this before their first await.
    private var readerMutationGeneration: UInt64 = 0
    private var activeForwardReceipt: MediaVideoForwardReceipt?
    /// A complete malformed fragment is terminal for this reader generation.
    /// Latching the mapped error prevents the same bad cursor from being
    /// retried as if it were a transient network failure.
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

    /// Retire the current source's display tracks outright. Called only when the
    /// readers themselves are being replaced (open/close) — never on seek, where
    /// the same reader and its track identity continue.
    private func retireDisplayTracks() {
        video?.displayTrack?.retire()
        audio?.displayTrack?.retire()
    }

    /// F4. Installed by the session; nil = deliver by batch return as before.
    private var packetRelay: DemuxPacketRelay?

    /// `async` to match `retireLiveStreams` and every other actor member that
    /// witnesses an async protocol requirement — the file's own precedent, and
    /// it leaves no question about how the witness is dispatched.
    func setPacketRelay(_ relay: DemuxPacketRelay?) async {
        packetRelay = relay
    }

    /// Advance a track's committed reader and publish the resulting packets in
    /// one actor-isolated step so published packets always match committed
    /// reader consumption. Returns false when a seek/open has superseded this
    /// pump (`readerMutationGeneration`).
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
        switch kind {
        case .video: video = reader
        case .audio: audio = reader
        }
        relay?.publish(packets, track: kind)
        return true
    }

    /// Snapshot-only generation check for batch pumps as well as relay pumps.
    /// Keeping this on the demux actor lets a static pump fence itself at an
    /// await without exposing the reader or making a speculative write-back.
    private func isCurrentReaderMutation(_ generation: UInt64) -> Bool {
        generation == readerMutationGeneration
    }
    private let injectedSession: URLSession?
    /// Byte store every network track source of an open reads through; nil
    /// (the default) reads exactly as before the store existed. Production
    /// opts in through `PathAAdaptiveDemuxer`, the VOD progressive path.
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
    /// Pump's per-box probe window: sized to swallow a box header, a whole
    /// typical moof (video ~2–8 KB, audio ~1–2 KB), and the mdat header
    /// behind it in ONE round trip — the wasted transfer on a non-moof skip
    /// box is bounded by this. Bytes past the mdat end (tiny fragments) are
    /// discarded, not cached; the next probe re-reads them.
    private static let fragmentProbeBytes = 16 * 1024
    /// Rung-2 sidx backtracking reads only fragment headers and remains
    /// bounded. A source whose prior 32 references expose no proven sync root
    /// fails local continuity instead of walking an unbounded remote index.
    private static let earlierContinuitySidxScanLimit = 32
    /// A no-sidx walk is cached separately from the playback cursor. Keep that
    /// cache bounded even when a malformed/open-ended source never advances
    /// its presentation time enough to satisfy the requested target.
    private static let maxFragmentIndexEntries = PathAFMP4.maxSidxEntries
    /// Deferred per-pump diagnostics are evidence only; never let one
    /// pathological stream build an unbounded diagnostic array before the
    /// packet/reader transaction returns.
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

    /// Codec config payload for the decoder open (D3): avcC/hvcC/av01C (video)
    /// or esds/dfLa (audio). Empty if the sample entry carried none.
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

            // The initial seek belongs to the staged open. A failed target
            // lookup must not expose otherwise-open track state.
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
                // Resolve the audio track before mutating the staged reader:
                // reading `storeBinding` inside the assignment to
                // `stagedAudio?.displayTrack` is an overlapping access.
                let audioDisplayTrack = stagedAudio?.storeBinding != nil
                    ? displayAvailability.makeTrack(.audio) : nil
                stagedAudio?.displayTrack = audioDisplayTrack
                stagedDisplayTracks = [stagedVideo.displayTrack, audioDisplayTrack].compactMap { $0 }
                await stagedVideo.source.setDisplayTrack(stagedVideo.displayTrack)
                if let stagedAudio { await stagedAudio.source.setDisplayTrack(stagedAudio.displayTrack) }
            }
            try checkOpenFence(generation, readerGeneration: readerGeneration)
            // Commit the complete split input in one actor-isolated transition.
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
            // Positioning children have joined. Cleanup belongs only to this
            // attempt, even if a successor opens while these actor hops await.
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
        // Only two independent no-SIDX index walks overlap. Indexed/mixed
        // inputs retain the existing video-then-audio positioning path.
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

    /// Shared ephemeral URLSession across fMP4 loads so TCP+TLS connections are
    /// reused across opens while cancellation stays per-request.
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

        // A muxed/same-resource topology stays serial. Only independent split
        // resources may overlap their initial network/parser work.
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

        // Fetch a head that holds the whole moov. Bili's is small (<~256 KB); if
        // the parse fails (truncated moov), extend once to the cap and retry —
        // more robust than trusting a clamped box range to reveal truncation.
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

        // Media (fragments) begin after moov, and after sidx if present.
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
        // Skip pumping any track with a ~0 budget so its reader and live chunk
        // stream stay untouched and a full audio queue does not block video supply.
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

            // Batch-return readers, counters and diagnostics form one
            // transaction. Streamed fragments use the explicit relay's
            // per-fragment commit boundary; a required-track error still
            // leaves any unreturned reader snapshot uncommitted. Cross-track
            // relay publication is an existing architecture trade-off kept
            // unchanged for the valid low-latency path.
            if let pumpedVideo = result.video { video = pumpedVideo.reader }
            if let pumpedAudio = result.audio { audio = pumpedAudio.reader }
            publish(
                (result.video?.diagnostics ?? [])
                    + (result.audio?.diagnostics ?? [])
            )
            await refreshMultiConnectionCursors()
            try checkPumpFence(generation, waitBudget: sourceWaitBudget)
            // Stable publication order is independent of task completion order.
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
            // Both tasks publish through the relay as they go, so audio no
            // longer waits on video's completion to become visible — the group
            // barrier now only gates the readers' final write-back, not the
            // packets (F4; the capture had ingestA silent for the same ~7.97s
            // as ingestV even though audio is a separate resource).
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

        // A probe/chunk can complete an entire fragment while also crossing
        // the content budget. Run the completion branch once more so the
        // fragment cursor is committed before returning; complete samples
        // were already delivered at their chunk edges.
        while produced < budget || r.activeFragment?.assembler.isComplete == true {
            let displayBytes = r.displayTrack.map(MediaDisplayByteOwner.init)
            defer { displayBytes?.release() }
            try checkWaitBudget(trackWaitBudget)
            // An EOF'd reader stays EOF'd until a seek revives it. Without
            // this gate, a truncated fragment (which now EMITS its completed
            // samples before eof-ing, unlike the old all-or-nothing path) was
            // re-walked and RE-EMITTED on every subsequent pump while the
            // other track kept the session pumping (review P1).
            if r.eof { break }
            if let continuityReferenceEnd, r.activeFragment == nil,
               r.cursor >= continuityReferenceEnd { break }
            // A fragment already streaming continues FIRST — its layout is
            // parsed, its stream (if any) is live, and every sample whose bytes
            // have arrived has already been committed through the relay.
            // Completion only advances the reader past the declared fragment.
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
            // ONE probe GET replaces the old 16-byte header GET: for a moof it
            // usually returns the entire moof plus the mdat header behind it,
            // so a fragment costs 2 round trips (probe + mdat tail) instead of
            // the old 4 (header, moof, header, mdat — the two 16-byte header
            // GETs also re-downloaded inside the body GETs). A non-moof box
            // (styp/sidx/free) consumes only its header from the probe and
            // wastes at most the window — rare, and bounded.
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
                // Assemble moof + trailing mdat into one contiguous buffer
                // whose absolute base is the moof start (default-base-is-moof).
                // Rebase to a fresh Data first: source reads may return slices.
                var buffered = Data(probe)
                let moofSize = header.size
                // Make sure the bytes through the mdat header are in hand
                // (a moof larger than the probe window spills — one extra GET).
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
                // Clip probe evidence to this fragment. Per-sample emission
                // below decides whether the issue supplied that AU's payload
                // or the moof/mdat metadata needed to describe it.
                let consumedEnd = r.cursor + min(buffered.count, fragmentTotal)
                packets.metadataRange = Int64(r.cursor)..<Int64(mdatPayloadStart)
                packets.noteRead(consumedRange: Int64(r.cursor)..<Int64(consumedEnd))
                // METADATA PHASE — the layout needs only the buffered moof:
                // every sample's byte span, timing, and sync flag exists here,
                // before a single payload byte. This is what lets the decoder
                // see packets while the mdat is still arriving.
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
                // `parseFragmentResult` has already validated every sample in
                // the declared mdat range. Do not filter malformed rows here:
                // a fragment is all-or-nothing at this boundary.
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
                // Bind the bytes actually parsed (including a possible primed
                // head) to one irreversible store incarnation, before retaining
                // timing. Payload is neither compared nor retained here.
                // Usability was installed by the owner before staging this
                // reader. Retirement can revoke this same token across awaits;
                // static pump work must never mint its own replacement.
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

                // CONSUMPTION PHASE — streaming when the spans are strictly
                // ordered (every split-resource fragment; the assembler
                // refuses degenerate interleave) and the source is remote.
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
                    // Feed the probe window first: samples wholly inside it
                    // emit with zero further network (tiny-fragment case).
                    // The probe may include bytes from the following box;
                    // never feed those past the declared fragment end.
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

                // FULLY-BUFFERED FALLBACK — local files, and layouts the
                // assembler refuses. The pre-streaming path: fetch the whole
                // fragment, slice each span, refuse a truncated fragment.
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
                    // Visible, not silent: a fragment that carries no sample
                    // durations would otherwise collapse DTS and hand the session
                    // zero-length packets (presentation hole / shape-B stall).
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
                // The buffered path has no partial state to commit — the whole
                // fragment landed at once — but it must still leave through the
                // SAME channel, or a pump that alternates paths would split one
                // track across two orderings.
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
                // styp / sidx / free / etc. — skip.
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
        // Backstop, and it must never be a no-op by accident: every emit path
        // above commits its own packets, so `uncommitted` is expected to be
        // empty here. If a future path emits without committing, these packets
        // would otherwise be neither published nor returned — SILENTLY DROPPED,
        // which is a decode gap rather than a delay. Flush them.
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
            // Empty when a relay took delivery — the packets are already with
            // the session and must not be handed over a second time.
            packets: packets.batched,
            diagnostics: diagnostics
        )
    }

    /// Where a pumped track's packets go.
    ///
    /// With a relay installed EVERY packet leaves through it, in order, as soon
    /// as the bytes that complete it arrive; without one they accumulate for the
    /// batch return exactly as before. Never both for the same track — one queue
    /// fed by two ordered channels is a decode-order inversion waiting to happen,
    /// and the streamed and fully-buffered paths below can alternate fragment to
    /// fragment within a single pump.
    private struct PacketEmitter {
        let relay: DemuxPacketRelay?
        let waitBudget: MediaSourceWaitBudget?
        var primaryObservations: [MediaSourcePrimaryObservation] = []
        var metadataRange: Range<Int64>?
        /// Packets held for the batch return (relay absent).
        var batched: [MediaPacket] = []
        /// Emitted but not yet committed+published. Kept per emit round so a
        /// commit publishes exactly the packets the reader advance paid for.
        var uncommitted: [MediaPacket] = []
        /// Total emitted this pump — the number `[gap] pump pkts=` reports, and
        /// the one the relay would otherwise hide.
        var emittedCount = 0
        /// How many left through the relay before the pump returned.
        var relayedCount = 0

        var deliversIncrementally: Bool { relay != nil }

        mutating func noteRead(consumedRange: Range<Int64>) {
            // A single exact read may have crossed several primary holes.
            // Keep the finite delivered set for the current fragment. An
            // issue for a later AU must survive emission of earlier held AUs.
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
            // All pieces used by this AU settle together. Unrelated later-AU
            // issues remain pending; none can be borrowed by a held packet.
            let consumedIssues = Set(dependencies.map(\.issueID))
            primaryObservations.removeAll { consumedIssues.contains($0.issueID) }
            emittedCount += 1
            if relay == nil {
                batched.append(packet)
            } else {
                uncommitted.append(packet)
            }
        }

        /// Hand the pending packets to the caller for an atomic commit+publish,
        /// clearing them. Empty when there is nothing to commit.
        mutating func takeUncommitted() -> [MediaPacket] {
            defer { uncommitted.removeAll(keepingCapacity: true) }
            relayedCount += uncommitted.count
            return uncommitted
        }
    }

    /// Commit the reader snapshot at every streaming delivery edge. With a
    /// relay this publishes all complete samples emitted by the preceding
    /// chunk and records the assembler's exact resume offset; with no relay,
    /// batch mode retains its existing pump-level transaction.
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
            // The reader may be a batch snapshot (and therefore have no
            // committed relay edge), but a stale active stream still must not
            // continue reading after a seek/open fence.
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
            // A seek/open may have replaced this reader while the commit
            // crossed the actor boundary.  Retire only the stream owned by
            // this snapshot: an unconditional closeActiveChunkStream here
            // could tear down the successor's stream after reentrancy.
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

    /// Consume the live fragment: pull chunks and publish every sample the
    /// arriving bytes complete, never a partial sample. A clean stream end
    /// before the declared fragment ends is truncation — already delivered
    /// complete samples remain delivered, and the parser failure is propagated.
    /// One transparent
    /// stream reopen per pump call — at the assembler's exact resume offset —
    /// preserves the buffered path's per-pump retry cadence for transient
    /// failures. Consumer cancellation leaves the stream intact for the next
    /// pump (the slot survives an abandoned wait by design).
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
        // Continuity check before trusting an inherited stream: a previous
        // pump may have consumed chunks and then been DISCARDED before its
        // write-back (pause cancels the supply loop with no demux fence; a
        // sibling-track error cancels the task group) — the slot advanced,
        // the committed assembler did not, and the id alone cannot tell. The
        // byte position can: on any mismatch, retire the slot and reopen at
        // the committed resume offset (review P1 — the one consistency
        // mechanism for every discard shape, including wrapper-level ones).
        if let id = af.streamID {
            let position = await r.source.chunkStreamPosition(id)
            if position != Int64(af.assembler.resumeOffset) {
                await r.source.closeChunkStream(id)
                af.streamID = nil
                r.activeFragment = af
            }
        }
        var reopenedOnce = false
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
                    // The fragment's byte range is exhausted with spans left —
                    // unreachable for a validated layout; fail the complete
                    // fragment rather than allowing any partial sample.
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
                // The source actor can be re-entered by a seek/open while the
                // stream slot is being created.  Close this exact stale slot
                // instead of leaving an orphan response behind the fence.
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
            let chunk: Data?
            do {
                chunk = try await r.source.nextChunk(
                    af.streamID ?? 0, waitBudget: waitBudget, displayOwner: displayBytes
                )
                try checkWaitBudget(waitBudget)
                if let chunkWaitStart { pacing?.recordWait(since: chunkWaitStart) }
            } catch is CancellationError {
                if let chunkWaitStart { pacing?.recordWait(since: chunkWaitStart) }
                if Task.isCancelled || waitBudget?.isCancelled == true {
                    r.activeFragment = af
                    throw CancellationError()
                }
                // The slot was retired under us (a fence closed it) while this
                // pump's reader still holds the fragment — e.g. a seek whose
                // own staging later failed, leaving the pre-seek reader live.
                // Reopen at the exact resume offset instead of wedging the
                // reader on a dead stream id, within the same per-pump budget.
                guard !reopenedOnce else {
                    r.activeFragment = af
                    throw CancellationError()
                }
                reopenedOnce = true
                pacing?.reopens += 1
                PlayerLog.log(
                    "[PathA] mdat-stream-reopen \(kind.rawValue) " +
                    "resume@\(af.assembler.resumeOffset) reason=slot-retired"
                )
                af.streamID = nil
                r.activeFragment = af
                continue
            } catch {
                if let chunkWaitStart { pacing?.recordWait(since: chunkWaitStart) }
                // A cancelled pump must not touch the network again — no
                // reopen after a teardown fence already ran (review P2). Its
                // own stream is retired id-scoped, which can never take down
                // a successor's replacement slot.
                if Task.isCancelled || waitBudget?.isCancelled == true {
                    if let id = af.streamID { await r.source.closeChunkStream(id) }
                    r.activeFragment = af
                    throw CancellationError()
                }
                guard !reopenedOnce else {
                    if let id = af.streamID { await r.source.closeChunkStream(id) }
                    r.activeFragment = af
                    throw error
                }
                reopenedOnce = true
                pacing?.reopens += 1
                PlayerLog.log(
                    "[PathA] mdat-stream-reopen \(kind.rawValue) " +
                    "resume@\(af.assembler.resumeOffset) reason=\(error.localizedDescription)"
                )
                if let id = af.streamID { await r.source.closeChunkStream(id) }
                af.streamID = nil
                r.activeFragment = af
                continue
            }
            guard let chunk else {
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
            // Commit the assembler cursor together with every complete sample
            // (or a gap-only advance). A later tail truncation is terminal, but
            // it cannot revoke samples already delivered through the relay.
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

    /// Close the fragment: retire the stream, publish the per-fragment
    /// diagnostics, advance the cursor (a truncated fragment leaves it — the
    /// reader EOFs, matching the buffered path's refusal to advance past a
    /// short read), and disarm the once-per-open/seek trace. Complete samples
    /// were committed as their spans arrived, so truncation does not roll them
    /// back.
    private static func finalizeActiveFragment(
        _ r: inout TrackReader,
        _ af: inout ActiveFragmentStream,
        diagnostics: inout [DeferredPumpDiagnostic],
        kind: MediaTrackKind,
        truncated: Bool
    ) async {
        if truncated { r.displayUsability.revoke() }
        if let streamID = af.streamID {
            // This finalizer can resume after a seek/reopen has installed a
            // replacement stream on the same source actor.  An id-scoped
            // close prevents stale work from retiring that successor.
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
            // UNCONDITIONAL (not trace-gated): a mid-play truncation EOFs this
            // reader until a seek — a silently wedged track looked like an
            // unexplained one-sided starve (video frozen, audio running).
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

    /// Decode deltas advance DTS, not reordered presentation boundaries. Use
    /// the complete source layout, so an unheld AU still leaves its own hole.
    /// Unknown timing and decode discontinuities separate runs; no next PTS is
    /// inferred across those boundaries or across fragments.
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
            // Use the immediate successor in the COMPLETE track layout. A PTS
            // from another decode run or an unknown AU cannot be skipped even
            // when B-frame reordering puts it inside this run's PTS span.
            guard let next = successors[ordinal], run.contains(next) else { continue }
            ends[ordinal] = samples[next].ptsTicks
        }
        // A run/fragment tail without a qualified source successor keeps its
        // own declared PTS+duration; no cross-fragment boundary is inferred.
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

    /// Count + report samples whose duration the parser had to synthesize.
    /// Logged on the first occurrence per track and then every 500 samples, so a
    /// pathological stream is loud once instead of spamming a soak log.
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

    /// Diagnostics: how many samples needed a synthesized duration (per track).
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

    /// Selection and moof inspection precede the only reader mutation. An
    /// unknown forecast or unavailable bounded sync root leaves its cursor and
    /// active fragment untouched; ordinary preparation remains the fallback.
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
            // sidx and track timing can use different scales and composition
            // offsets. The actual first emitted sync AU is the anchor; do not
            // require an arbitrary agreement with sidx presentation time.
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

    /// Inspect only bounded metadata, not the media payload. A reference may
    /// contain several moof/mdat pairs; first-root and total PTS extent differ.
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
                // An unpaired payload is not a proven decoder-input sequence.
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
        let data = try await source.read(offset: Int64(offset), count: count)
        guard data.count == count, let header = parseBoxHeader(data, at: 0) else {
            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                phase: .box, field: "header", reason: "truncated_or_invalid", offset: offset
            ))
        }
        // BMFF size-zero is relative to the resource, never the sidx window.
        return try resolveBoxHeader(header, at: offset, containingEnd: resourceEnd)
    }

    private static func forwardFragmentProof(
        _ reader: TrackReader, offset: Int, size: Int, payload: Range<Int>
    ) async throws -> ForwardReferenceProof? {
        let data = try await reader.source.read(offset: Int64(offset), count: size)
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
        // Reservation precedes close's actor hop. Only video is repositioned.
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

    /// Consume one batch from the reader installed by
    /// `prepareEarlierVideoContinuity` without routing its packets through the
    /// ordinary session relay. The reader-mutation generation intentionally
    /// stays fixed for the whole direct transaction; a seek/open/close bumps
    /// it and makes the active pump abandon its staged value.
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

        // Passing nil is deliberate. The ordinary relay remains installed for
        // normal supply, but this one direct batch is returned to its caller;
        // no packet can be both returned here and published to that relay.
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
            // A source counter is monotonic. Treat an impossible regression as
            // saturated progress rather than allowing a negative budget charge.
            byteDelta = Int64.max
        }
        let compressedByteCount = Int(clamping: byteDelta)
        // A primed/cache-served range is intentionally not counted again by
        // `PathAHTTPMediaSource.bytesRead`. The direct transaction still owns
        // the compressed packets it hands to decoder 2, so charge at least the
        // returned access-unit bytes; otherwise a cache hit would create
        // uncharged direct input and could bypass the 16 MiB ceiling.
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
        // This is deliberately not seek(to:): audio owns the advancing master
        // timeline and its reader/cursor must remain untouched. Quiescing the
        // session supply loop before this call makes this one video-reader
        // mutation transactional with the foreground preparation.
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
        // A seek owns a new reader mutation even when no committed reader is
        // currently visible. This fences an in-flight staged open before any
        // seek-side await or early return.
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
        // Fence: a repositioned reader must never resume a stale fragment.
        // Retire the live stream UNCONDITIONALLY — a slot can exist without a
        // committed activeFragment (a pump opened it and was discarded before
        // write-back; review P2) — drop the partial state, and arm the stage
        // trace for the first post-seek fragment.
        await r.source.closeActiveChunkStream()
        r.activeFragment = nil
        r.armFragmentTrace = true
        r.eof = false
        if r.segments.isEmpty {
            // No sidx → lazily build a fragment walk index before seeking.
            // The output floor remains active so decoded pre-roll is still filtered.
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
            // SIDX references are not necessarily rooted at media time zero.
            // Use each reference's presentation start (which includes
            // earliest_presentation_time) instead of accumulating durations
            // from zero. Ignoring EPT selects the first segment *after* the
            // requested target on Bili's fMP4 resources, leaving the session's
            // output floor with no target-side audio and forcing a large silent
            // repair in AudioTimelineBuffer.
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

    /// Select the random-access authority immediately before the one that
    /// would own `excludedAnchorPTS`. This is intentionally not implemented as
    /// `seekReader(to: excludedAnchorPTS - epsilon)`: segment durations vary,
    /// and subtracting a guessed epsilon can resolve to the same fragment.
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

    /// W5a instrumentation for the forward anchor (W5b), not a selection input.
    ///
    /// Two counts, because one cannot answer the question. `closed` is the
    /// usable-anchor count; `withSAP` is how many references declare a SAP of
    /// ANY type. A resource that never populates the field and a resource whose
    /// every fragment is an open GOP (`SAP_type` 3) both report `closed=0`, and
    /// they call for opposite conclusions: the first means the declaration is
    /// absent and the forward scan must keep paying for
    /// `sidxEntryStartsWithSyncSample`'s header inspection, the second means the
    /// declaration is present and says these fragments are not clean starts.
    ///
    /// Called from inside `PlayerLog.log`'s `@autoclosure`, so neither count is
    /// computed when nothing is capturing.
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

    /// Sidx gives byte/time references but is not, by itself, project-level
    /// random-access proof. Inspect the bounded preceding fragment headers and
    /// accept only an entry whose first decode-order sample carries explicit
    /// sync dependency flags. Payload bytes are not downloaded here.
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
                // Metadata inspection must stay bounded even if a malformed
                // sidx/header advertises an enormous box.
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

    /// Walk fragment headers until the index contains a target-side fragment.
    /// The scan is cached separately from the playback cursor.
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
                containingEnd: reader.endByte > 0 ? reader.endByte : nil
            ), header.size >= header.headerLength else {
                // An empty read is natural EOF for an unknown-length resource;
                // a non-empty invalid header already throws ParseError from
                // readBoxHeader.  Finish the index walk so seekAnchor can
                // report the ordinary no-target result.
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
                    count: header.size
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
                    containingEnd: reader.endByte > 0 ? reader.endByte : nil
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
            // A request before the first decoded PTS starts from the first
            // available fragment; the session's output floor still drops any
            // decoded pre-roll that precedes the requested time.
            candidate = reader.fragmentIndex.first
        } else {
            // Do not silently rewind to the last fragment after EOF. That
            // reports a successful seek whose target-side queues are empty.
            candidate = nil
        }
        guard let candidate else { return nil }
        guard kind == "video" else { return candidate }

        guard let idx = reader.fragmentIndex.lastIndex(where: { $0.offset == candidate.offset }) else {
            return candidate
        }
        return reader.fragmentIndex[...idx].last(where: { $0.startsWithKeyframe }) ?? candidate
    }

    // MARK: - Cached content ahead (media cache P1)

    /// Whole fragments past the committed reader, with revocable residency.
    /// Both the operation generation and committed-progress fence must survive
    /// the store awaits; Session's queue epoch alone cannot prove reader freshness.
    nonisolated var measuresCachedContentAhead: Bool { byteStore != nil }

    /// The display-evidence book, published only for a store-backed network
    /// source — the same eligibility the cache-only producer requires. Live
    /// HLS, local files and other demuxers answer nil and keep their fallback.
    nonisolated var displayEvidenceQuery: (any MediaDisplayEvidenceQuerying)? {
        displayAvailability.hasTracks ? displayAvailability : nil
    }

    /// Install new usability only on the owner, before either ordinary or
    /// direct-continuity pumping takes reader copies or crosses an await.
    /// Clearing the old descriptor makes renewal depend on a new parse.
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
        // The single observation consumer owns future evidence. A fill must
        // not race it and replace newer leases with an older async roster.
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
                    // Yield between bounded passes and stale-reader retries,
                    // including catch-up after the last cache write.
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
        // A pump can supersede this snapshot and then cancel without a reader
        // commit or another cache write. Retry instead of consuming its wake.
        guard generation == readerMutationGeneration, progress == readerProgressRevision else { return true }
        futureDisplayLeases[.video] = videoFuture.roster.isEmpty ? nil : videoFuture.roster
        futureDisplayLeases[.audio] = audioFuture.roster.isEmpty ? nil : audioFuture.roster
        return videoFuture.reachedLimit || audioFuture.reachedLimit
    }

    /// Parse future fragments out of the bytes the store ALREADY holds.
    ///
    /// This is metadata evidence only: no network read, no real reader cursor or
    /// index mutation, and no payload copied beyond one moof. A fragment is
    /// published only when its whole `mdat` payload is covered by one live store
    /// receipt and every sample has known timing. Multiple presentation components
    /// remain separate in the display book; they do not reject the whole fragment.
    /// Unknown timing, unsupported layout or short residency ends the walk;
    /// nothing is approximated from sidx.
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
        // Scan AFTER the active fragment, but retain its byte/time map while
        // the assembler/copies/resident suffix can still need that map.
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

    /// The scalar supplement requires a single connected component of the
    /// exact same intervals installed in the display book. Overlap is valid;
    /// a true gap or any unknown sample timing rejects only this scalar view.
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
        // The first byte not yet consumed: inside a streaming fragment that is
        // the assembler's resume offset (the fragment itself then counts 0s,
        // see `PathACachedFragmentRunway`), otherwise the next box.
        let start = Int64(reader.activeFragment?.assembler.resumeOffset ?? reader.cursor)
        guard let held = await binding.store.residentRun(binding.key, from: start) else { return .empty }
        guard let measurement = PathACachedFragmentRunway.measurement(
            from: start,
            heldBytes: held.byteCount,
            fragments: cachedRunwayFragments(of: reader, startingAt: start, heldBytes: held.byteCount)
        ), let validity = held.validity.narrowed(to: measurement.bytes) else { return .empty }
        return MediaCachedTrackContentAhead(seconds: measurement.seconds, validity: validity)
    }

    /// The reader's known fragments that begin inside the held window,
    /// ascending: the sidx references, or the lazy walk index when there is no
    /// sidx. A walked fragment ends where the next indexed one begins (skipped
    /// boxes included, so they must be held too); the last one ends at the walk
    /// cursor. Bounding by the window keeps the copy to what can count.
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

    /// Park support (MediaDemuxing): retire the live chunk streams, keep every
    /// reader/cursor/activeFragment value intact. The next pump's continuity
    /// check sees the retired slot and reopens at the committed assembler
    /// offset — the identical path a discarded pump takes.
    func retireLiveStreams() async {
        await multiConnectionPrefetcher?.park()
        await closeActiveStreams()
    }

    /// Interrupt the demux-owned ranged read without replacing either reader.
    /// Discovery and id-scoped close are one source-actor operation. Splitting
    /// them across two awaits would let a successor stream replace the observed
    /// id between actor hops, leaving the real blocking operation alive while
    /// the demux reports no acknowledgement. A plain `retireLiveStreams()` call
    /// is intentionally not used as an acknowledgement: it is a park operation
    /// whose default protocol implementation is a no-op.
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

    /// Retire both readers' live chunk streams — every teardown/replace fence
    /// (open, close) runs this before dropping or rebuilding reader state, so
    /// a stale in-flight pump resolves as cancellation instead of consuming a
    /// dead stream, and no URLSession task outlives its fragment.
    private func closeActiveStreams() async {
        // Unconditional per source: a slot can be live without a committed
        // activeFragment (a pump opened it and was discarded before its
        // write-back). A suspended orphan task would otherwise be retained by
        // the shared session forever (review P2).
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
        /// `size == 0` is valid ISO-BMFF only relative to the enclosing
        /// resource.  The streaming reader must resolve it at a known
        /// containing end; an open-ended HTTP resource cannot safely guess.
        let extendsToContainingEnd: Bool
    }

    /// Read a box header (size + fourcc, with 64-bit largesize) at `offset`.
    private static func readBoxHeader(
        _ source: PathAHTTPMediaSource,
        at offset: Int,
        containingEnd: Int? = nil
    ) async throws -> BoxHeader? {
        guard offset >= 0 else { return nil }
        let bytes = try await source.read(offset: Int64(offset), count: 16)
        guard bytes.count <= 16 else {
            throw PathAFMP4.ParseError.malformed(PathAFMP4.ParseFailure(
                phase: .box, field: "readSize", reason: "exceeds_request",
                availableBytes: bytes.count, offset: offset
            ))
        }
        guard let header = parseBoxHeader(bytes, at: 0) else {
            // An empty read at an unknown resource end is natural EOF for the
            // no-sidx index walk.  Any non-empty short/invalid header is a
            // malformed declared box and must reach the demux latch instead
            // of being mistaken for an exhausted index.
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

    /// Parse a box header from already-fetched bytes. Slice-safe: indexes
    /// relative to `offset` within `data` regardless of the Data's base index.
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
                cursor: Int64(reader.activeFragment?.assembler.resumeOffset ?? reader.cursor)
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

    /// Synchronously captures and detaches all active open/prefetch/store-protection
    /// fields before crossing any await so a concurrent successor open is never clobbered.
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

/// Cache-only resident-fragment inspection helpers. Split from the walk so each
/// declaration stays inside the project's complexity and body-length limits;
/// `private` here is file-scoped, so they see the actor's private nested types.
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
        // Resolve the same audio timebase the real packet path would use,
        // through a value copy only: cache inspection never mutates reader
        // timing or logs a new observation.
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
