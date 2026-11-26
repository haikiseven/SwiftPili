import Foundation

enum PathAFMP4 {

    enum ParseResult<Value> {
        case success(Value)
        case needMoreData(requiredBytes: Int)
        case malformed(ParseFailure)
        case unsupported(ParseUnsupported)
    }

    enum ParsePhase: String, Equatable, Sendable {
        case box
        case movie
        case track
        case tfhd
        case tfdt
        case trun
        case fragment
        case sample
        case timing
        case packetize
        case sidx
    }

    struct ParseFailure: Error, Equatable, Sendable, LocalizedError {
        let phase: ParsePhase
        let boxType: String?
        let trackID: UInt32?
        let field: String
        let reason: String
        let declaredCount: UInt64?
        let availableBytes: Int?
        let offset: Int?

        init(
            phase: ParsePhase,
            boxType: String? = nil,
            trackID: UInt32? = nil,
            field: String,
            reason: String,
            declaredCount: UInt64? = nil,
            availableBytes: Int? = nil,
            offset: Int? = nil
        ) {
            self.phase = phase
            self.boxType = boxType.map { Self.sanitize($0, maxLength: 8) }
            self.trackID = trackID
            self.field = Self.sanitize(field, maxLength: 32)
            self.reason = Self.sanitize(reason, maxLength: 64)
            self.declaredCount = declaredCount
            self.availableBytes = availableBytes
            self.offset = offset
        }

        var summary: String {
            var parts = ["phase=\(phase.rawValue)", "field=\(field)", "reason=\(reason)"]
            if let boxType { parts.append("box=\(boxType)") }
            if let trackID { parts.append("track=\(trackID)") }
            if let declaredCount { parts.append("declared=\(declaredCount)") }
            if let availableBytes { parts.append("available=\(availableBytes)") }
            if let offset { parts.append("offset=\(offset)") }
            return parts.joined(separator: " ")
        }

        var errorDescription: String? { summary }

        fileprivate static func sanitizeForUnsupported(_ value: String) -> String {
            sanitize(value, maxLength: 64)
        }

        private static func sanitize(_ value: String, maxLength: Int) -> String {
            let safe = value.filter {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
            }
            return String((safe.isEmpty ? "invalid" : safe).prefix(maxLength))
        }
    }

    struct ParseUnsupported: Error, Equatable, Sendable, LocalizedError {
        let phase: ParsePhase
        let boxType: String?
        let field: String
        let reason: String
        let version: UInt32?

        init(
            phase: ParsePhase,
            boxType: String? = nil,
            field: String,
            reason: String,
            version: UInt32? = nil
        ) {
            self.phase = phase
            self.boxType = boxType.map { ParseFailure.sanitizeForUnsupported($0) }
            self.field = ParseFailure.sanitizeForUnsupported(field)
            self.reason = ParseFailure.sanitizeForUnsupported(reason)
            self.version = version
        }

        var summary: String {
            var parts = ["phase=\(phase.rawValue)", "field=\(field)", "reason=\(reason)"]
            if let boxType { parts.append("box=\(boxType)") }
            if let version { parts.append("version=\(version)") }
            return parts.joined(separator: " ")
        }

        var errorDescription: String? { summary }
    }

    enum ParseError: Error, Sendable, LocalizedError {
        case needMoreData(requiredBytes: Int)
        case malformed(ParseFailure)
        case unsupported(ParseUnsupported)

        var errorDescription: String? {
            switch self {
            case .needMoreData(let requiredBytes):
                return "fMP4 parser needs more data bytes=\(requiredBytes)"
            case .malformed(let failure):
                return "fMP4 malformed \(failure.summary)"
            case .unsupported(let unsupported):
                return "fMP4 unsupported \(unsupported.summary)"
            }
        }

        static func from<Value>(_ result: ParseResult<Value>) -> Self {
            switch result {
            case .success:
                preconditionFailure("ParseError.from called for success")
            case .needMoreData(let requiredBytes):
                return .needMoreData(requiredBytes: requiredBytes)
            case .malformed(let failure):
                return .malformed(failure)
            case .unsupported(let unsupported):
                return .unsupported(unsupported)
            }
        }
    }

    static let maxSamplesPerTrun = 4_096
    static let maxSamplesPerMoof = 16_384
    static let maxSamplesPerPacketize = 65_536
    static let maxSampleBytesPerMoof = 64 * 1024 * 1024
    static let maxPacketizedBytes = 128 * 1024 * 1024
    static let maxBoxesPerRange = 65_536
    static let maxConfigNestingDepth = 32
    static let maxSidxEntries = 16_384
    static let maxBoxSize = 128 * 1024 * 1024

    enum TrackKind: String, Equatable, Sendable { case video, audio }

    struct TrackInfo: Equatable, Sendable {
        var trackID: UInt32
        var kind: TrackKind
        var timescale: UInt32
        var codec: String
        var config: Data
        var width: Int = 0
        var height: Int = 0
        var sampleRate: Double = 0
        var channelCount: Int = 0
        var defaultSampleDuration: UInt32 = 0
        var defaultSampleDurationWasDeclared: Bool = false
        var defaultSampleSize: UInt32 = 0
        var defaultSampleFlags: UInt32? = nil
        var extensionAtoms: [String: Data] = [:]

        var videoTrackConfiguration: MediaVideoTrackConfiguration? {
            guard kind == .video else { return nil }
            return MediaVideoTrackConfiguration(
                codec: codec, config: config,
                codedDimensions: MediaVideoCodedDimensions(width: width, height: height),
                extensionAtoms: extensionAtoms
            )
        }
    }

    struct MovieInfo: Equatable, Sendable {
        var tracks: [TrackInfo]
        var durationSeconds: Double
    }

    struct Sample: Equatable, Sendable {
        var trackID: UInt32
        var offset: Int
        var size: Int
        var dtsTicks: Int64
        var ptsTicks: Int64
        var durationTicks: UInt32
        var isKeyframe: Bool
        var sampleIndex: Int = 0
        var fragmentSequence: UInt32? = nil
        var durationIsSynthesized: Bool = false
    }

    struct FragmentTiming: Equatable, Sendable {
        var startPTSTicks: Int64
        var endPTSTicks: Int64
        var startsWithKeyframe: Bool
    }

    struct AudioTimingResolution: Equatable, Sendable {
        var declaredTimescale: UInt32
        var effectiveTimescale: Double
        var codecSampleRate: Double
        var framesPerAccessUnit: Int
        var observedDurationTicks: UInt32
        var expectedDurationSeconds: Double
        var durationMatchesCodec: Bool
        var containerSampleRate: Double

        var timingMismatch: Bool {
            !durationMatchesCodec
        }

        var observedDurationSeconds: Double {
            Double(observedDurationTicks) / Double(max(1, declaredTimescale))
        }
    }

    static func resolveAudioTiming(
        declaredTimescale: UInt32,
        codecSampleRate: Double,
        framesPerAccessUnit: Int,
        sampleDurations: [UInt32],
        containerSampleRate: Double = 0
    ) -> AudioTimingResolution? {
        guard declaredTimescale > 0,
              codecSampleRate.isFinite,
              codecSampleRate > 0,
              framesPerAccessUnit > 0,
              !sampleDurations.isEmpty,
              sampleDurations.allSatisfy({ $0 > 0 })
        else { return nil }

        let expectedSeconds = Double(framesPerAccessUnit) / codecSampleRate
        let declaredScale = Double(declaredTimescale)
        let tickTolerance = 1.0
        let sortedDurations = sampleDurations.sorted()
        let medianDuration = sortedDurations[sortedDurations.count / 2]
        let declaredMatches = abs(
            Double(medianDuration) / declaredScale - expectedSeconds
        ) <= tickTolerance / declaredScale
        return AudioTimingResolution(
            declaredTimescale: declaredTimescale,
            effectiveTimescale: declaredScale,
            codecSampleRate: codecSampleRate,
            framesPerAccessUnit: framesPerAccessUnit,
            observedDurationTicks: medianDuration,
            expectedDurationSeconds: expectedSeconds,
            durationMatchesCodec: declaredMatches,
            containerSampleRate: containerSampleRate
        )
    }

    // MARK: - Movie (init) parse

    static func parseMovieResult(_ data: Data) -> ParseResult<MovieInfo> {
        switch findMovieBoxResult(data) {
        case .success(let moov): return parseMovieBoxResult(data, moov: moov)
        case .needMoreData(let required): return .needMoreData(requiredBytes: required)
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
    }

    private static func findMovieBoxResult(_ data: Data) -> ParseResult<Box> {
        let range = 0..<data.count
        guard validRange(range, in: data) else {
            return .malformed(ParseFailure(
                phase: .movie, field: "range", reason: "invalid"
            ))
        }
        var position = range.lowerBound
        var boxCount = 0
        while position < range.upperBound {
            guard boxCount < maxBoxesPerRange else {
                return .malformed(ParseFailure(
                    phase: .movie, field: "boxCount", reason: "ceiling",
                    declaredCount: UInt64(boxCount + 1), offset: position
                ))
            }
            switch parseBoxAtResult(data, position: position, enclosingEnd: range.upperBound) {
            case .success(let box):
                if box.type == "moov" { return .success(box) }
                position = box.range.upperBound
                boxCount += 1
            case .needMoreData(let required):
                let next = data.count.addingReportingOverflow(1)
                return .needMoreData(requiredBytes: required > 0 ? required : (next.overflow ? Int.max : 1))
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }
        }
        let next = data.count.addingReportingOverflow(1)
        return .needMoreData(requiredBytes: next.overflow ? Int.max : max(1, next.partialValue))
    }

    static func movieHeaderBoxesResult(_ data: Data) -> ParseResult<[Box]> {
        let range = 0..<data.count
        guard validRange(range, in: data) else {
            return .malformed(ParseFailure(
                phase: .movie, field: "range", reason: "invalid"
            ))
        }
        var boxes: [Box] = []
        var position = range.lowerBound
        var foundMovie = false
        var boxCount = 0
        while position < range.upperBound {
            switch parseBoxAtResult(data, position: position, enclosingEnd: range.upperBound) {
            case .success(let box):
                guard boxCount < maxBoxesPerRange else {
                    return .malformed(ParseFailure(
                        phase: .movie, field: "boxCount", reason: "ceiling",
                        declaredCount: UInt64(boxCount + 1), offset: position
                    ))
                }
                boxes.append(box)
                position = box.range.upperBound
                boxCount += 1
                if box.type == "moov" { foundMovie = true }
            case .needMoreData:
                if foundMovie { return .success(boxes) }
                return .needMoreData(requiredBytes: 1)
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }
        }
        return foundMovie
            ? .success(boxes)
            : .needMoreData(requiredBytes: max(1, 8 - data.count))
    }

    private static func parseMovieBoxResult(
        _ data: Data,
        moov: Box
    ) -> ParseResult<MovieInfo> {
        var movieTimescale: UInt32 = 0
        var movieDurationTicks: UInt64 = 0
        var trexByTrack: [UInt32: (dur: UInt32, size: UInt32, flags: UInt32)] = [:]
        var declaredTrexTracks = Set<UInt32>()

        let moovChildren: [Box]
        switch parseBoxesResult(data, range: moov.payload) {
        case .success(let boxes): moovChildren = boxes
        case .needMoreData: return .malformed(truncatedFailure(phase: .movie, boxType: "moov", range: moov.payload))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }

        if let mvhd = moovChildren.first(where: { $0.type == "mvhd" }) {
            switch parseMvhdResult(data, range: mvhd.payload) {
            case .success(let value):
                movieTimescale = value.timescale
                movieDurationTicks = value.duration
            case .needMoreData: return .malformed(truncatedFailure(phase: .movie, boxType: "mvhd", range: mvhd.payload))
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }
        }

        if let mvex = moovChildren.first(where: { $0.type == "mvex" }) {
            let trexBoxes: [Box]
            switch parseBoxesResult(data, range: mvex.payload) {
            case .success(let boxes): trexBoxes = boxes.filter { $0.type == "trex" }
            case .needMoreData: return .malformed(truncatedFailure(phase: .movie, boxType: "mvex", range: mvex.payload))
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }
            for trex in trexBoxes {
                switch parseTrexResult(data, range: trex.payload) {
                case .success(let parsed):
                    guard parsed.trackID > 0 else {
                        return .malformed(ParseFailure(
                            phase: .movie, boxType: "trex", field: "trackID",
                            reason: "zero", offset: trex.range.lowerBound
                        ))
                    }
                    guard declaredTrexTracks.insert(parsed.trackID).inserted else {
                        return .malformed(ParseFailure(
                            phase: .movie, boxType: "trex", trackID: parsed.trackID,
                            field: "trackID", reason: "duplicate", offset: trex.range.lowerBound
                        ))
                    }
                    trexByTrack[parsed.trackID] = (
                        parsed.duration, parsed.size, parsed.flags
                    )
                case .needMoreData: return .malformed(truncatedFailure(phase: .movie, boxType: "trex", range: trex.payload))
                case .malformed(let failure): return .malformed(failure)
                case .unsupported(let unsupported): return .unsupported(unsupported)
                }
            }
        }

        var tracks: [TrackInfo] = []
        var trackIDs = Set<UInt32>()
        for trak in moovChildren where trak.type == "trak" {
            switch parseTrakResult(data, box: trak) {
            case .success(var track):
                guard trackIDs.insert(track.trackID).inserted else {
                    return .malformed(ParseFailure(
                        phase: .movie, boxType: "trak", trackID: track.trackID,
                        field: "trackID", reason: "duplicate", offset: trak.range.lowerBound
                    ))
                }
                if let defaults = trexByTrack[track.trackID] {
                    track.defaultSampleDuration = defaults.dur
                    track.defaultSampleDurationWasDeclared = true
                    track.defaultSampleSize = defaults.size
                    track.defaultSampleFlags = defaults.flags
                }
                tracks.append(track)
            case .needMoreData: return .malformed(truncatedFailure(phase: .track, boxType: "trak", range: trak.payload))
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }
        }

        guard !tracks.isEmpty else {
            return .malformed(ParseFailure(
                phase: .movie, boxType: "moov", field: "tracks", reason: "missing",
                offset: moov.range.lowerBound
            ))
        }
        let durationSeconds: Double
        if movieTimescale == 0 {
            durationSeconds = 0
        } else {
            durationSeconds = Double(movieDurationTicks) / Double(movieTimescale)
            guard durationSeconds.isFinite else {
                return .malformed(ParseFailure(
                    phase: .movie, boxType: "mvhd", field: "duration", reason: "nonfinite"
                ))
            }
        }
        return .success(MovieInfo(tracks: tracks, durationSeconds: durationSeconds))
    }

    private static func parseMvhdResult(
        _ data: Data,
        range: Range<Int>
    ) -> ParseResult<(timescale: UInt32, duration: UInt64)> {
        var c = Cursor(data, range)
        guard let vf = c.u32() else {
            return .malformed(truncatedFailure(phase: .movie, boxType: "mvhd", range: range))
        }
        let version = vf >> 24
        let duration: UInt64
        guard version == 0 || version == 1 else {
            return .unsupported(ParseUnsupported(
                phase: .movie, boxType: "mvhd", field: "version",
                reason: "unsupported", version: version
            ))
        }
        if version == 1 {
            guard c.skip(16), let timescale = c.u32(), let value = c.u64() else {
                return .malformed(truncatedFailure(phase: .movie, boxType: "mvhd", range: range))
            }
            guard timescale > 0 else {
                return .malformed(ParseFailure(
                    phase: .movie, boxType: "mvhd", field: "timescale", reason: "zero"
                ))
            }
            duration = value
            return .success((timescale, duration))
        }
        guard c.skip(8), let timescale = c.u32(), let value = c.u32() else {
            return .malformed(truncatedFailure(phase: .movie, boxType: "mvhd", range: range))
        }
        guard timescale > 0 else {
            return .malformed(ParseFailure(
                phase: .movie, boxType: "mvhd", field: "timescale", reason: "zero"
            ))
        }
        duration = UInt64(value)
        return .success((timescale, duration))
    }

    private static func parseTrexResult(
        _ data: Data,
        range: Range<Int>
    ) -> ParseResult<(trackID: UInt32, duration: UInt32, size: UInt32, flags: UInt32)> {
        var c = Cursor(data, range)
        guard let vf = c.u32() else {
            return .malformed(truncatedFailure(phase: .movie, boxType: "trex", range: range))
        }
        let version = vf >> 24
        guard version == 0 else {
            return .unsupported(ParseUnsupported(
                phase: .movie, boxType: "trex", field: "version",
                reason: "unsupported", version: version
            ))
        }
        guard let trackID = c.u32(), c.skip(4), let duration = c.u32(),
              let size = c.u32(), let flags = c.u32() else {
            return .malformed(truncatedFailure(phase: .movie, boxType: "trex", range: range))
        }
        guard c.remaining == 0 else {
            return .malformed(ParseFailure(
                phase: .movie, boxType: "trex", field: "payload", reason: "trailing",
                availableBytes: c.remaining
            ))
        }
        return .success((trackID, duration, size, flags))
    }

    private static func parseTrakResult(
        _ data: Data,
        box: Box
    ) -> ParseResult<TrackInfo> {
        let children: [Box]
        switch parseBoxesResult(data, range: box.payload) {
        case .success(let value): children = value
        case .needMoreData: return .malformed(truncatedFailure(phase: .track, boxType: "trak", range: box.payload))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
        guard let tkhd = children.first(where: { $0.type == "tkhd" }),
              let mdia = children.first(where: { $0.type == "mdia" }) else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "trak", field: "children", reason: "missing",
                offset: box.range.lowerBound
            ))
        }
        let trackID: UInt32
        switch parseTkhdResult(data, range: tkhd.payload) {
        case .success(let value): trackID = value
        case .needMoreData: return .malformed(truncatedFailure(phase: .track, boxType: "tkhd", range: tkhd.payload))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
        guard trackID > 0 else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "tkhd", field: "trackID", reason: "zero",
                offset: tkhd.range.lowerBound
            ))
        }

        let mdiaChildren: [Box]
        switch parseBoxesResult(data, range: mdia.payload) {
        case .success(let value): mdiaChildren = value
        case .needMoreData: return .malformed(truncatedFailure(phase: .track, boxType: "mdia", range: mdia.payload))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
        guard let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }),
              let minf = mdiaChildren.first(where: { $0.type == "minf" }) else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "mdia", trackID: trackID,
                field: "children", reason: "missing"
            ))
        }
        let timescale: UInt32
        switch parseMdhdResult(data, range: mdhd.payload) {
        case .success(let value): timescale = value
        case .needMoreData: return .malformed(truncatedFailure(phase: .track, boxType: "mdhd", range: mdhd.payload))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
        guard timescale > 0 else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "mdhd", trackID: trackID,
                field: "timescale", reason: "zero"
            ))
        }

        let kind: TrackKind?
        if let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }) {
            switch parseHdlrResult(data, range: hdlr.payload) {
            case .success(let value): kind = value
            case .needMoreData: return .malformed(truncatedFailure(phase: .track, boxType: "hdlr", range: hdlr.payload))
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }
        } else {
            kind = nil
        }

        let minfChildren: [Box]
        switch parseBoxesResult(data, range: minf.payload) {
        case .success(let value): minfChildren = value
        case .needMoreData: return .malformed(truncatedFailure(phase: .track, boxType: "minf", range: minf.payload))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
        guard let stbl = minfChildren.first(where: { $0.type == "stbl" }) else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "minf", trackID: trackID,
                field: "stbl", reason: "missing"
            ))
        }
        let stblChildren: [Box]
        switch parseBoxesResult(data, range: stbl.payload) {
        case .success(let value): stblChildren = value
        case .needMoreData: return .malformed(truncatedFailure(phase: .track, boxType: "stbl", range: stbl.payload))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
        guard let stsd = stblChildren.first(where: { $0.type == "stsd" }) else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "stbl", trackID: trackID,
                field: "stsd", reason: "missing"
            ))
        }
        switch parseStsdResult(data, range: stsd.payload, trackID: trackID, timescale: timescale) {
        case .success(var track):
            if let kind { track.kind = kind }
            guard !track.config.isEmpty else {
                return .malformed(ParseFailure(
                    phase: .track, trackID: trackID,
                    field: "configuration", reason: "missing"
                ))
            }
            return .success(track)
        case .needMoreData: return .malformed(truncatedFailure(phase: .track, boxType: "stsd", range: stsd.payload))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
    }

    private static func parseTkhdResult(
        _ data: Data,
        range: Range<Int>
    ) -> ParseResult<UInt32> {
        var c = Cursor(data, range)
        guard let vf = c.u32() else {
            return .malformed(truncatedFailure(phase: .track, boxType: "tkhd", range: range))
        }
        let version = vf >> 24
        guard version == 0 || version == 1 else {
            return .unsupported(ParseUnsupported(
                phase: .track, boxType: "tkhd", field: "version",
                reason: "unsupported", version: version
            ))
        }
        guard c.skip(version == 1 ? 16 : 8), let trackID = c.u32(), trackID > 0 else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "tkhd", field: "trackID", reason: "missing_or_zero"
            ))
        }
        return .success(trackID)
    }

    private static func parseMdhdResult(
        _ data: Data,
        range: Range<Int>
    ) -> ParseResult<UInt32> {
        var c = Cursor(data, range)
        guard let vf = c.u32() else {
            return .malformed(truncatedFailure(phase: .track, boxType: "mdhd", range: range))
        }
        let version = vf >> 24
        guard version == 0 || version == 1 else {
            return .unsupported(ParseUnsupported(
                phase: .track, boxType: "mdhd", field: "version",
                reason: "unsupported", version: version
            ))
        }
        guard c.skip(version == 1 ? 16 : 8), let timescale = c.u32(), timescale > 0 else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "mdhd", field: "timescale", reason: "missing_or_zero"
            ))
        }
        return .success(timescale)
    }

    private static func parseHdlrResult(
        _ data: Data,
        range: Range<Int>
    ) -> ParseResult<TrackKind?> {
        var c = Cursor(data, range)
        guard c.skip(4), c.skip(4), let handler = c.fourCC() else {
            return .malformed(truncatedFailure(phase: .track, boxType: "hdlr", range: range))
        }
        switch handler {
        case "vide": return .success(.video)
        case "soun": return .success(.audio)
        default: return .success(nil)
        }
    }

    private static let videoCodecFourCCs: Set<String> = [
        "avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "av01", "vp09"
    ]
    private static let configFourCCs: Set<String> = [
        "avcC", "hvcC", "av1C", "vpcC", "esds", "dec3", "dfLa", "dOps"
    ]
    private static let videoExtensionAtomFourCCs: Set<String> = [
        "avcC", "hvcC", "av1C", "vpcC", "dvcC", "dvvC", "dvwC", "colr", "pasp"
    ]
    private static let containerFourCCs: Set<String> = [
        "sinf", "schi", "wave", "wavl", "enca", "encv",
        "avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe",
        "av01", "vp09", "mp4a"
    ]

    private static func parseStsdResult(
        _ data: Data,
        range: Range<Int>,
        trackID: UInt32,
        timescale: UInt32
    ) -> ParseResult<TrackInfo> {
        var c = Cursor(data, range)
        guard c.skip(4), let entryCount = c.u32(), entryCount > 0 else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "stsd", trackID: trackID,
                field: "entryCount", reason: "missing_or_zero"
            ))
        }
        guard entryCount <= 16 else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "stsd", trackID: trackID,
                field: "entryCount", reason: "ceiling", declaredCount: UInt64(entryCount)
            ))
        }
        let entryStart = c.position
        guard let entrySize = c.u32(), let format = c.fourCC() else {
            return .malformed(truncatedFailure(phase: .track, boxType: "stsd", range: range))
        }
        guard entrySize >= 8,
              let entryEnd = checkedEnd(start: entryStart, size: UInt64(entrySize)),
              entryEnd <= range.upperBound else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "stsd", trackID: trackID,
                field: "entrySize", reason: "out_of_range", offset: entryStart
            ))
        }
        var nextEntryPosition = entryEnd
        for _ in 1..<entryCount {
            let additionalStart = nextEntryPosition
            guard range.upperBound >= additionalStart,
                  range.upperBound - additionalStart >= 8 else {
                return .malformed(ParseFailure(
                    phase: .track, boxType: "stsd", trackID: trackID,
                    field: "entry", reason: "truncated", offset: additionalStart
                ))
            }
            var additional = Cursor(data, additionalStart..<range.upperBound)
            guard let additionalSize = additional.u32(),
                  additional.fourCC() != nil,
                  additionalSize >= 8,
                  let additionalEnd = checkedEnd(
                      start: additionalStart, size: UInt64(additionalSize)
                  ), additionalEnd <= range.upperBound else {
                return .malformed(ParseFailure(
                    phase: .track, boxType: "stsd", trackID: trackID,
                    field: "entrySize", reason: "out_of_range", offset: additionalStart
                ))
            }
            nextEntryPosition = additionalEnd
        }
        guard nextEntryPosition == range.upperBound else {
            return .malformed(ParseFailure(
                phase: .track, boxType: "stsd", trackID: trackID,
                field: "payload", reason: "trailing", availableBytes: range.upperBound - nextEntryPosition
            ))
        }

        let isVideo = videoCodecFourCCs.contains(format)
        var track = TrackInfo(
            trackID: trackID, kind: isVideo ? .video : .audio,
            timescale: timescale, codec: format, config: Data()
        )
        let entryPayloadStart = c.position
        var childStart = entryPayloadStart
        if isVideo {
            var vc = Cursor(data, entryPayloadStart..<entryEnd)
            guard vc.skip(6 + 2 + 2 + 2 + 12), let width = vc.u16(), let height = vc.u16(),
                  vc.skip(4 + 4 + 4 + 2 + 32 + 2 + 2) else {
                return .malformed(truncatedFailure(phase: .track, boxType: format, range: entryPayloadStart..<entryEnd))
            }
            track.width = Int(width)
            track.height = Int(height)
            childStart = vc.position
        } else {
            var ac = Cursor(data, entryPayloadStart..<entryEnd)
            guard ac.skip(6 + 2), ac.skip(8), let channels = ac.u16(),
                  ac.skip(2 + 2 + 2), let sampleRate1616 = ac.u32() else {
                return .malformed(truncatedFailure(phase: .track, boxType: format, range: entryPayloadStart..<entryEnd))
            }
            track.channelCount = Int(channels)
            track.sampleRate = Double(sampleRate1616 >> 16)
            childStart = ac.position
        }

        switch findConfigResult(data, range: childStart..<entryEnd, depth: 0) {
        case .success(let config):
            if let config { track.config = config }
        case .needMoreData:
            return .malformed(truncatedFailure(phase: .track, boxType: format, range: childStart..<entryEnd))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
        if isVideo {
            track.extensionAtoms = collectVideoExtensionAtoms(data, range: childStart..<entryEnd, depth: 0)
        }
        return .success(track)
    }

    private static func collectVideoExtensionAtoms(
        _ data: Data,
        range: Range<Int>,
        depth: Int
    ) -> [String: Data] {
        guard depth <= maxConfigNestingDepth,
              case .success(let boxes) = parseBoxesResult(data, range: range) else {
            return [:]
        }
        var atoms: [String: Data] = [:]
        for box in boxes {
            if videoExtensionAtomFourCCs.contains(box.type), atoms[box.type] == nil {
                atoms[box.type] = data.subdata(in: box.payload)
            }
            if containerFourCCs.contains(box.type) {
                let nested = collectVideoExtensionAtoms(data, range: box.payload, depth: depth + 1)
                for (key, value) in nested where atoms[key] == nil {
                    atoms[key] = value
                }
            }
        }
        return atoms
    }

    private static func findConfigResult(
        _ data: Data,
        range: Range<Int>,
        depth: Int
    ) -> ParseResult<Data?> {
        guard depth <= maxConfigNestingDepth else {
            return .malformed(ParseFailure(
                phase: .track, field: "configuration", reason: "nesting_ceiling"
            ))
        }
        switch parseBoxesResult(data, range: range) {
        case .needMoreData(let required): return .needMoreData(requiredBytes: required)
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        case .success(let boxes):
            for box in boxes {
                if configFourCCs.contains(box.type) {
                    return .success(data.subdata(in: box.payload))
                }
                guard containerFourCCs.contains(box.type) else { continue }
                switch findConfigResult(data, range: box.payload, depth: depth + 1) {
                case .success(let config) where config != nil: return .success(config)
                case .success: break
                case .needMoreData(let required): return .needMoreData(requiredBytes: required)
                case .malformed(let failure): return .malformed(failure)
                case .unsupported(let unsupported): return .unsupported(unsupported)
                }
            }
            return .success(nil)
        }
    }

    // MARK: - Fragment (moof) parse

    static func parseFragmentResult(
        _ data: Data,
        segmentByteOffset: Int,
        moofRange: Range<Int>,
        tracks: [TrackInfo],
        sampleDataRange: Range<Int>? = nil
    ) -> ParseResult<[Sample]> {
        guard validRange(moofRange, in: data), segmentByteOffset >= 0 else {
            return .malformed(ParseFailure(
                phase: .fragment, field: "range", reason: "invalid",
                offset: max(0, segmentByteOffset)
            ))
        }
        if let sampleDataRange {
            let localLower = sampleDataRange.lowerBound.subtractingReportingOverflow(segmentByteOffset)
            let localUpper = sampleDataRange.upperBound.subtractingReportingOverflow(segmentByteOffset)
            guard !localLower.overflow, !localUpper.overflow,
                  localLower.partialValue >= 0,
                  localLower.partialValue <= localUpper.partialValue else {
                return .malformed(ParseFailure(
                    phase: .fragment, field: "sampleDataRange", reason: "invalid"
                ))
            }
        }
        let boxes: [Box]
        switch parseBoxesResult(data, range: moofRange) {
        case .success(let value): boxes = value
        case .needMoreData: return .malformed(truncatedFailure(phase: .fragment, boxType: "moof", range: moofRange))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
        guard let moof = boxes.first(where: { $0.type == "moof" }) else {
            return .malformed(ParseFailure(
                phase: .fragment, field: "moof", reason: "missing",
                offset: moofRange.lowerBound
            ))
        }
        let moofStart: Int64
        guard let moofStartValue = checkedAdd(
            Int64(segmentByteOffset), Int64(moof.range.lowerBound)
        ) else {
            return .malformed(ParseFailure(
                phase: .fragment, boxType: "moof", field: "start", reason: "overflow"
            ))
        }
        moofStart = moofStartValue
        guard moofStart >= 0, moofStart <= Int64(Int.max) else {
            return .malformed(ParseFailure(
                phase: .fragment, boxType: "moof", field: "start", reason: "out_of_range"
            ))
        }

        let singleTrack: TrackInfo?
        var byTrack: [UInt32: TrackInfo] = [:]
        if tracks.count == 1 {
            let track = tracks[0]
            guard track.trackID > 0 else {
                return .malformed(ParseFailure(
                    phase: .fragment, trackID: track.trackID,
                    field: "trackID", reason: "zero"
                ))
            }
            guard track.timescale > 0 else {
                return .malformed(ParseFailure(
                    phase: .fragment, trackID: track.trackID,
                    field: "timescale", reason: "zero"
                ))
            }
            singleTrack = track
        } else {
            singleTrack = nil
            byTrack.reserveCapacity(tracks.count)
            for track in tracks {
                guard track.trackID > 0 else {
                    return .malformed(ParseFailure(
                        phase: .fragment, trackID: track.trackID,
                        field: "trackID", reason: "zero"
                    ))
                }
                guard track.timescale > 0 else {
                    return .malformed(ParseFailure(
                        phase: .fragment, trackID: track.trackID,
                        field: "timescale", reason: "zero"
                    ))
                }
                guard byTrack.updateValue(track, forKey: track.trackID) == nil else {
                    return .malformed(ParseFailure(
                        phase: .fragment, trackID: track.trackID,
                        field: "trackID", reason: "duplicate"
                    ))
                }
            }
        }

        let moofChildren: [Box]
        switch parseBoxesResult(data, range: moof.payload) {
        case .success(let value): moofChildren = value
        case .needMoreData: return .malformed(truncatedFailure(phase: .fragment, boxType: "moof", range: moof.payload))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }

        let fragmentSequence = parseFragmentSequence(data, children: moofChildren)
        var samples: [Sample] = []
        samples.reserveCapacity(min(maxSamplesPerMoof, 128))
        var firstTrafID: UInt32?
        var seenTrafIDs: Set<UInt32>?
        var totalSampleBytes = 0

        for traf in moofChildren where traf.type == "traf" {
            let trafChildren: [Box]
            switch parseBoxesResult(data, range: traf.payload) {
            case .success(let value): trafChildren = value
            case .needMoreData: return .malformed(truncatedFailure(phase: .fragment, boxType: "traf", range: traf.payload))
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }
            guard let tfhdBox = trafChildren.first(where: { $0.type == "tfhd" }) else {
                return .malformed(ParseFailure(
                    phase: .fragment, boxType: "traf", field: "tfhd", reason: "missing",
                    offset: traf.range.lowerBound
                ))
            }
            let tfhd: TFHDInfo
            switch parseTfhdResult(data, range: tfhdBox.payload) {
            case .success(let value): tfhd = value
            case .needMoreData: return .malformed(truncatedFailure(phase: .tfhd, boxType: "tfhd", range: tfhdBox.payload))
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }
            if let existing = firstTrafID {
                if seenTrafIDs == nil {
                    seenTrafIDs = [existing]
                }
                guard seenTrafIDs!.insert(tfhd.trackID).inserted else {
                    return .malformed(ParseFailure(
                        phase: .fragment, boxType: "traf", trackID: tfhd.trackID,
                        field: "trackID", reason: "duplicate", offset: traf.range.lowerBound
                    ))
                }
            } else {
                firstTrafID = tfhd.trackID
            }
            if let explicit = tfhd.baseOffset,
               explicit > UInt64(Int64.max) {
                return .malformed(ParseFailure(
                    phase: .tfhd, boxType: "tfhd", trackID: tfhd.trackID,
                    field: "base_data_offset", reason: "overflow"
                ))
            }

            let track: TrackInfo?
            if let singleTrack {
                track = singleTrack.trackID == tfhd.trackID ? singleTrack : nil
            } else {
                track = byTrack[tfhd.trackID]
            }
            let defaultDuration = tfhd.sampleDuration ?? track?.defaultSampleDuration ?? 0
            let defaultDurationExplicit = tfhd.sampleDurationWasDeclared
                || track?.defaultSampleDurationWasDeclared == true
            let defaultSize = tfhd.sampleSize ?? track?.defaultSampleSize ?? 0
            let defaultFlags = tfhd.sampleFlags ?? track?.defaultSampleFlags

            let baseDecodeTime: Int64
            if let tfdtBox = trafChildren.first(where: { $0.type == "tfdt" }) {
                switch parseTfdtResult(data, range: tfdtBox.payload) {
                case .success(let value): baseDecodeTime = value
                case .needMoreData: return .malformed(truncatedFailure(phase: .tfdt, boxType: "tfdt", range: tfdtBox.payload))
                case .malformed(let failure): return .malformed(failure)
                case .unsupported(let unsupported): return .unsupported(unsupported)
                }
            } else {
                baseDecodeTime = 0
            }
            var runningDTS = baseDecodeTime
            var carriedDuration = defaultDuration
            var previousRunEnd: Int64?
            var trackSampleIndex = 0
            var trafSampleCount = 0
            for trunBox in trafChildren where trunBox.type == "trun" {
                let run: TrunInfo
                switch parseTrunResult(data, range: trunBox.payload) {
                case .success(let value): run = value
                case .needMoreData: return .malformed(truncatedFailure(phase: .trun, boxType: "trun", range: trunBox.payload))
                case .malformed(let failure): return .malformed(failure)
                case .unsupported(let unsupported): return .unsupported(unsupported)
                }
                let aggregateSampleCount = samples.count.addingReportingOverflow(
                    run.samples.count
                )
                guard !aggregateSampleCount.overflow,
                      aggregateSampleCount.partialValue <= maxSamplesPerMoof else {
                    return .malformed(ParseFailure(
                        phase: .fragment, boxType: "moof", trackID: tfhd.trackID,
                        field: "sampleCount", reason: "ceiling",
                        declaredCount: UInt64(
                            max(0, aggregateSampleCount.partialValue)
                        )
                    ))
                }
                let sampleCountResult = trafSampleCount.addingReportingOverflow(run.samples.count)
                guard !sampleCountResult.overflow,
                      sampleCountResult.partialValue <= maxSamplesPerMoof else {
                    return .malformed(ParseFailure(
                        phase: .fragment, boxType: "traf", trackID: tfhd.trackID,
                        field: "sampleCount", reason: "ceiling",
                        declaredCount: UInt64(max(0, sampleCountResult.partialValue))
                    ))
                }
                trafSampleCount = sampleCountResult.partialValue
                let base: Int64
                if tfhd.defaultBaseIsMoof {
                    base = moofStart
                } else if let explicit = tfhd.baseOffset {
                    guard explicit <= UInt64(Int64.max) else {
                        return .malformed(ParseFailure(
                            phase: .tfhd, boxType: "tfhd", trackID: tfhd.trackID,
                            field: "base_data_offset", reason: "overflow"
                        ))
                    }
                    base = Int64(explicit)
                } else {
                    base = moofStart
                }

                let runStart: Int64
                if let relative = run.dataOffset {
                    guard let resolved = checkedAdd(base, Int64(relative)) else {
                        return .malformed(ParseFailure(
                            phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                            field: "data_offset", reason: "overflow"
                        ))
                    }
                    runStart = resolved
                } else {
                    runStart = previousRunEnd ?? base
                }
                guard runStart >= 0, runStart <= Int64(Int.max) else {
                    return .malformed(ParseFailure(
                        phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                        field: "data_offset", reason: "underflow_or_overflow"
                    ))
                }
                if let previousRunEnd, runStart < previousRunEnd {
                    return .malformed(ParseFailure(
                        phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                        field: "data_offset", reason: "overlap"
                    ))
                }

                var sampleOffset = runStart
                for (index, item) in run.samples.enumerated() {
                    let duration: UInt32
                    let durationIsSynthesized: Bool
                    if let declared = item.duration {
                        guard declared > 0 else {
                            return .malformed(ParseFailure(
                                phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                                field: "sample_duration", reason: "zero",
                                offset: trunBox.range.lowerBound
                            ))
                        }
                        duration = declared
                        durationIsSynthesized = false
                    } else if defaultDuration > 0 {
                        duration = defaultDuration
                        durationIsSynthesized = false
                    } else if defaultDurationExplicit {
                        return .malformed(ParseFailure(
                            phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                            field: "sample_duration", reason: "zero_default"
                        ))
                    } else {
                        let nominal = nominalDurationTicks(for: track ?? tracks.first)
                        guard nominal > 0 else {
                            return .malformed(ParseFailure(
                                phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                                field: "sample_duration", reason: "missing"
                            ))
                        }
                        duration = carriedDuration > 0 ? carriedDuration : nominal
                        durationIsSynthesized = true
                    }
                    carriedDuration = duration

                    let sizeValue = item.size ?? defaultSize
                    guard sizeValue > 0 else {
                        return .malformed(ParseFailure(
                            phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                            field: "sample_size", reason: "zero"
                        ))
                    }
                    guard let sampleEnd = checkedAdd(sampleOffset, Int64(sizeValue)),
                          sampleEnd > sampleOffset,
                          sampleEnd <= Int64(Int.max) else {
                        return .malformed(ParseFailure(
                            phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                            field: "sample_span", reason: "overflow_or_underflow",
                            offset: Int(clamping: sampleOffset)
                        ))
                    }
                    if let sampleDataRange {
                        let lower = Int64(sampleDataRange.lowerBound)
                        let upper = Int64(sampleDataRange.upperBound)
                        guard sampleOffset >= lower, sampleEnd <= upper else {
                            return .malformed(ParseFailure(
                                phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                                field: "sample_span", reason: "out_of_range",
                                availableBytes: sampleDataRange.count,
                                offset: Int(clamping: sampleOffset)
                            ))
                        }
                    }
                    let (newTotal, bytesOverflowed) = totalSampleBytes.addingReportingOverflow(Int(sizeValue))
                    guard !bytesOverflowed, newTotal <= maxSampleBytesPerMoof else {
                        return .malformed(ParseFailure(
                            phase: .fragment, boxType: "moof", trackID: tfhd.trackID,
                            field: "sampleBytes", reason: "ceiling",
                            declaredCount: UInt64(newTotal)
                        ))
                    }
                    totalSampleBytes = newTotal

                    guard let nextDTS = checkedAdd(runningDTS, Int64(duration)) else {
                        return .malformed(ParseFailure(
                            phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                            field: "dts", reason: "overflow"
                        ))
                    }
                    let cto = item.compositionOffset ?? 0
                    guard let pts = checkedAdd(runningDTS, cto) else {
                        return .malformed(ParseFailure(
                            phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                            field: "pts", reason: "overflow"
                        ))
                    }
                    guard checkedAdd(pts, Int64(duration)) != nil else {
                        return .malformed(ParseFailure(
                            phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                            field: "ptsEnd", reason: "overflow"
                        ))
                    }
                    let flags = item.flags
                        ?? (index == 0 ? (run.firstSampleFlags ?? defaultFlags) : defaultFlags)
                    let isSync = flags.map { ($0 & 0x0001_0000) == 0 } ?? false
                    samples.append(Sample(
                        trackID: tfhd.trackID,
                        offset: Int(sampleOffset),
                        size: Int(sizeValue),
                        dtsTicks: runningDTS,
                        ptsTicks: pts,
                        durationTicks: duration,
                        isKeyframe: isSync,
                        sampleIndex: trackSampleIndex,
                        fragmentSequence: fragmentSequence,
                        durationIsSynthesized: durationIsSynthesized
                    ))
                    let nextSampleIndex = trackSampleIndex.addingReportingOverflow(1)
                    guard !nextSampleIndex.overflow else {
                        return .malformed(ParseFailure(
                            phase: .sample, boxType: "trun", trackID: tfhd.trackID,
                            field: "sampleIndex", reason: "overflow"
                        ))
                    }
                    trackSampleIndex = nextSampleIndex.partialValue
                    sampleOffset = sampleEnd
                    runningDTS = nextDTS
                }
                previousRunEnd = sampleOffset
            }
            if tfhd.durationIsEmpty, trafSampleCount > 0 {
                return .malformed(ParseFailure(
                    phase: .fragment, boxType: "tfhd", trackID: tfhd.trackID,
                    field: "duration_is_empty", reason: "has_samples"
                ))
            }
        }

        return .success(samples)
    }

    static func fragmentTimingResult(
        _ data: Data,
        moofRange: Range<Int>,
        track: TrackInfo,
        segmentByteOffset: Int = 0
    ) -> ParseResult<FragmentTiming?> {
        switch parseFragmentResult(
            data,
            segmentByteOffset: segmentByteOffset,
            moofRange: moofRange,
            tracks: [track]
        ) {
        case .needMoreData:
            return .malformed(truncatedFailure(phase: .timing, boxType: "moof", range: moofRange))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        case .success(let parsed):
            var firstDecodeSample: Sample?
            var start = Int64.max
            var end = Int64.min
            var matchedAny = false
            for sample in parsed where sample.trackID == track.trackID {
                matchedAny = true
                if let currentFirst = firstDecodeSample {
                    if sample.dtsTicks < currentFirst.dtsTicks
                        || (sample.dtsTicks == currentFirst.dtsTicks && sample.ptsTicks < currentFirst.ptsTicks) {
                        firstDecodeSample = sample
                    }
                } else {
                    firstDecodeSample = sample
                }
                if sample.ptsTicks < start { start = sample.ptsTicks }
                guard let sampleEnd = checkedAdd(
                    sample.ptsTicks, Int64(sample.durationTicks)
                ) else {
                    return .malformed(ParseFailure(
                        phase: .timing, boxType: "moof", trackID: track.trackID,
                        field: "ptsEnd", reason: "overflow"
                    ))
                }
                if sampleEnd > end { end = sampleEnd }
            }
            guard matchedAny else { return .success(nil) }
            return .success(FragmentTiming(
                startPTSTicks: start,
                endPTSTicks: max(start, end),
                startsWithKeyframe: firstDecodeSample?.isKeyframe == true
            ))
        }
    }

    static func nominalDurationTicks(for track: TrackInfo?) -> UInt32 {
        guard let track, track.timescale > 0 else { return 0 }
        switch track.kind {
        case .video:
            return max(1, track.timescale / 30)
        case .audio:
            if track.sampleRate > 0 {
                let ticks = 1024.0 * Double(track.timescale) / track.sampleRate
                guard ticks.isFinite, ticks >= 1,
                      ticks.rounded(.toNearestOrAwayFromZero) <= Double(UInt32.max) else {
                    return 0
                }
                return max(1, UInt32(ticks.rounded()))
            }
            return max(1, track.timescale / 50)
        }
    }

    private struct TFHDInfo {
        let trackID: UInt32
        let baseOffset: UInt64?
        let defaultBaseIsMoof: Bool
        let sampleDuration: UInt32?
        let sampleDurationWasDeclared: Bool
        let sampleSize: UInt32?
        let sampleFlags: UInt32?
        let durationIsEmpty: Bool
    }

    private static func parseTfhdResult(
        _ data: Data,
        range: Range<Int>
    ) -> ParseResult<TFHDInfo> {
        var c = Cursor(data, range)
        guard let vf = c.u32(), let trackID = c.u32() else {
            return .malformed(truncatedFailure(phase: .tfhd, boxType: "tfhd", range: range))
        }
        let version = vf >> 24
        guard version == 0 else {
            return .unsupported(ParseUnsupported(
                phase: .tfhd, boxType: "tfhd", field: "version",
                reason: "unsupported", version: version
            ))
        }
        guard trackID > 0 else {
            return .malformed(ParseFailure(
                phase: .tfhd, boxType: "tfhd", field: "trackID", reason: "zero"
            ))
        }
        let flags = vf & 0x00FF_FFFF
        let knownFlags: UInt32 = 0x0000_0001 | 0x0000_0002 | 0x0000_0008
            | 0x0000_0010 | 0x0000_0020 | 0x0001_0000 | 0x0002_0000
        guard flags & ~knownFlags == 0 else {
            return .malformed(ParseFailure(
                phase: .tfhd, boxType: "tfhd", trackID: trackID,
                field: "flags", reason: "unsupported"
            ))
        }
        let hasBaseOffset = flags & 0x0000_0001 != 0
        let hasDescription = flags & 0x0000_0002 != 0
        let hasDuration = flags & 0x0000_0008 != 0
        let hasSize = flags & 0x0000_0010 != 0
        let hasSampleFlags = flags & 0x0000_0020 != 0
        let hasDefaultBaseIsMoof = flags & 0x0002_0000 != 0
        guard !(hasBaseOffset && hasDefaultBaseIsMoof) else {
            return .malformed(ParseFailure(
                phase: .tfhd, boxType: "tfhd", trackID: trackID,
                field: "flags", reason: "contradictory"
            ))
        }
        let baseOffset: UInt64?
        if hasBaseOffset {
            guard let value = c.u64() else {
                return .malformed(truncatedFailure(phase: .tfhd, boxType: "tfhd", range: range))
            }
            baseOffset = value
        } else {
            baseOffset = nil
        }
        if hasDescription, !c.skip(4) {
            return .malformed(truncatedFailure(phase: .tfhd, boxType: "tfhd", range: range))
        }
        let sampleDuration: UInt32?
        if hasDuration {
            guard let value = c.u32() else {
                return .malformed(truncatedFailure(phase: .tfhd, boxType: "tfhd", range: range))
            }
            sampleDuration = value
        } else {
            sampleDuration = nil
        }
        let sampleSize: UInt32?
        if hasSize {
            guard let value = c.u32() else {
                return .malformed(truncatedFailure(phase: .tfhd, boxType: "tfhd", range: range))
            }
            sampleSize = value
        } else {
            sampleSize = nil
        }
        let sampleFlags: UInt32?
        if hasSampleFlags {
            guard let value = c.u32() else {
                return .malformed(truncatedFailure(phase: .tfhd, boxType: "tfhd", range: range))
            }
            sampleFlags = value
        } else {
            sampleFlags = nil
        }
        guard c.remaining == 0 else {
            return .malformed(ParseFailure(
                phase: .tfhd, boxType: "tfhd", trackID: trackID,
                field: "payload", reason: "trailing", availableBytes: c.remaining
            ))
        }
        return .success(TFHDInfo(
            trackID: trackID,
            baseOffset: baseOffset,
            defaultBaseIsMoof: hasDefaultBaseIsMoof,
            sampleDuration: sampleDuration,
            sampleDurationWasDeclared: hasDuration,
            sampleSize: sampleSize,
            sampleFlags: sampleFlags,
            durationIsEmpty: flags & 0x0001_0000 != 0
        ))
    }

    private static func parseTfdtResult(
        _ data: Data,
        range: Range<Int>
    ) -> ParseResult<Int64> {
        var c = Cursor(data, range)
        guard let vf = c.u32() else {
            return .malformed(truncatedFailure(phase: .tfdt, boxType: "tfdt", range: range))
        }
        let version = vf >> 24
        switch version {
        case 0:
            guard let value = c.u32(), c.remaining == 0 else {
                return .malformed(truncatedFailure(phase: .tfdt, boxType: "tfdt", range: range))
            }
            return .success(Int64(value))
        case 1:
            guard let value = c.u64(), c.remaining == 0 else {
                return .malformed(truncatedFailure(phase: .tfdt, boxType: "tfdt", range: range))
            }
            guard value <= UInt64(Int64.max) else {
                return .malformed(ParseFailure(
                    phase: .tfdt, boxType: "tfdt", field: "base_media_decode_time",
                    reason: "overflow"
                ))
            }
            return .success(Int64(value))
        default:
            return .unsupported(ParseUnsupported(
                phase: .tfdt, boxType: "tfdt", field: "version",
                reason: "unsupported", version: version
            ))
        }
    }

    private struct TrunSample {
        var duration: UInt32?
        var size: UInt32?
        var flags: UInt32?
        var compositionOffset: Int64?
    }
    private struct TrunInfo { var dataOffset: Int32?; var firstSampleFlags: UInt32?; var samples: [TrunSample] }

    private static func parseTrunResult(
        _ data: Data,
        range: Range<Int>
    ) -> ParseResult<TrunInfo> {
        var c = Cursor(data, range)
        guard let vf = c.u32(), let sampleCount = c.u32() else {
            return .malformed(truncatedFailure(phase: .trun, boxType: "trun", range: range))
        }
        let version = vf >> 24
        guard version == 0 || version == 1 else {
            return .unsupported(ParseUnsupported(
                phase: .trun, boxType: "trun", field: "version",
                reason: "unsupported", version: version
            ))
        }
        let flags = vf & 0x00FF_FFFF
        let knownFlags: UInt32 = 0x0000_0001 | 0x0000_0004 | 0x0000_0100
            | 0x0000_0200 | 0x0000_0400 | 0x0000_0800
        guard flags & ~knownFlags == 0 else {
            return .malformed(ParseFailure(
                phase: .trun, boxType: "trun", field: "flags", reason: "unsupported"
            ))
        }
        let hasDataOffset = flags & 0x0000_0001 != 0
        let hasFirstSampleFlags = flags & 0x0000_0004 != 0
        let hasDur = flags & 0x0000_0100 != 0
        let hasSize = flags & 0x0000_0200 != 0
        let hasFlags = flags & 0x0000_0400 != 0
        let hasCTO = flags & 0x0000_0800 != 0
        guard !(hasFirstSampleFlags && hasFlags) else {
            return .malformed(ParseFailure(
                phase: .trun, boxType: "trun", field: "flags", reason: "contradictory"
            ))
        }
        let prefix = 8 + (hasDataOffset ? 4 : 0) + (hasFirstSampleFlags ? 4 : 0)
        guard range.count >= prefix else {
            return .malformed(ParseFailure(
                phase: .trun, boxType: "trun", field: "prefix", reason: "truncated",
                declaredCount: UInt64(sampleCount), availableBytes: max(0, range.count - 8)
            ))
        }
        let rowWidth = (hasDur ? 4 : 0) + (hasSize ? 4 : 0)
            + (hasFlags ? 4 : 0) + (hasCTO ? 4 : 0)
        if rowWidth > 0 {
            let availableRows = (range.count - prefix) / rowWidth
            guard UInt64(sampleCount) <= UInt64(availableRows) else {
                return .malformed(ParseFailure(
                    phase: .trun, boxType: "trun", field: "sampleCount",
                    reason: "row_bound", declaredCount: UInt64(sampleCount),
                    availableBytes: range.count - prefix
                ))
            }
        }
        let maxCount = rowWidth > 0 ? maxSamplesPerMoof : maxSamplesPerTrun
        guard sampleCount <= UInt32(maxCount) else {
            return .malformed(ParseFailure(
                phase: .trun, boxType: "trun", field: "sampleCount",
                reason: "ceiling", declaredCount: UInt64(sampleCount)
            ))
        }
        var info = TrunInfo(dataOffset: nil, firstSampleFlags: nil, samples: [])
        if hasDataOffset {
            guard let offset = c.i32() else {
                return .malformed(truncatedFailure(phase: .trun, boxType: "trun", range: range))
            }
            info.dataOffset = offset
        }
        if hasFirstSampleFlags {
            guard let flags = c.u32() else {
                return .malformed(truncatedFailure(phase: .trun, boxType: "trun", range: range))
            }
            info.firstSampleFlags = flags
        }
        let expectedSampleBytes = Int(sampleCount) * rowWidth
        guard c.remaining >= expectedSampleBytes else {
            return .malformed(truncatedFailure(phase: .trun, boxType: "trun", range: range))
        }
        guard c.remaining == expectedSampleBytes else {
            return .malformed(ParseFailure(
                phase: .trun, boxType: "trun", field: "payload", reason: "trailing",
                availableBytes: c.remaining - expectedSampleBytes
            ))
        }
        info.samples.reserveCapacity(Int(sampleCount))
        let rowsStart = c.position
        data.withUnsafeBytes { raw in
            var pos = rowsStart
            for _ in 0..<sampleCount {
                var duration: UInt32?
                var size: UInt32?
                var sampleFlags: UInt32?
                var cto: Int64?
                if hasDur {
                    duration = raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self).bigEndian
                    pos += 4
                }
                if hasSize {
                    size = raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self).bigEndian
                    pos += 4
                }
                if hasFlags {
                    sampleFlags = raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self).bigEndian
                    pos += 4
                }
                if hasCTO {
                    let rawValue = raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self).bigEndian
                    pos += 4
                    cto = version == 0 ? Int64(rawValue) : Int64(Int32(bitPattern: rawValue))
                }
                info.samples.append(TrunSample(
                    duration: duration,
                    size: size,
                    flags: sampleFlags,
                    compositionOffset: cto
                ))
            }
        }
        return .success(info)
    }

    // MARK: - Packetize a segment (one or more moof + mdat pairs)

    static func packetize(
        segment buffer: Data,
        segmentByteOffset: Int,
        tracks: [TrackInfo]
    ) -> [(sample: Sample, data: Data)] {
        guard case .success(let packets) = packetizeResult(
            segment: buffer,
            segmentByteOffset: segmentByteOffset,
            tracks: tracks
        ) else { return [] }
        return packets
    }

    static func packetizeResult(
        segment buffer: Data,
        segmentByteOffset: Int,
        tracks: [TrackInfo]
    ) -> ParseResult<[(sample: Sample, data: Data)]> {
        guard segmentByteOffset >= 0,
              validRange(0..<buffer.count, in: buffer) else {
            return .malformed(ParseFailure(
                phase: .packetize, field: "segmentOffset", reason: "invalid"
            ))
        }
        let topLevel: [Box]
        switch parseBoxesResult(buffer, range: 0..<buffer.count) {
        case .success(let boxes): topLevel = boxes
        case .needMoreData: return .malformed(truncatedFailure(phase: .packetize, range: 0..<buffer.count))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }

        var out: [(sample: Sample, data: Data)] = []
        out.reserveCapacity(min(maxSamplesPerPacketize, 256))
        var totalBytes = 0
        for (index, moof) in topLevel.enumerated() where moof.type == "moof" {
            guard index + 1 < topLevel.count, topLevel[index + 1].type == "mdat" else {
                return .malformed(ParseFailure(
                    phase: .packetize, boxType: "moof", field: "mdat", reason: "missing",
                    offset: moof.range.lowerBound
                ))
            }
            let mdat = topLevel[index + 1]
            guard let mdatStart = checkedAdd(
                segmentByteOffset, mdat.payload.lowerBound
            ), let mdatEnd = checkedAdd(segmentByteOffset, mdat.range.upperBound) else {
                return .malformed(ParseFailure(
                    phase: .packetize, boxType: "mdat", field: "range", reason: "overflow"
                ))
            }
            switch parseFragmentResult(
                buffer,
                segmentByteOffset: segmentByteOffset,
                moofRange: moof.range,
                tracks: tracks,
                sampleDataRange: mdatStart..<mdatEnd
            ) {
            case .needMoreData:
                return .malformed(truncatedFailure(phase: .packetize, boxType: "moof", range: moof.range))
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            case .success(let samples):
                guard out.count <= maxSamplesPerPacketize - samples.count else {
                    return .malformed(ParseFailure(
                        phase: .packetize, field: "sampleCount", reason: "ceiling",
                        declaredCount: UInt64(out.count) + UInt64(samples.count)
                    ))
                }
                for sample in samples {
                    let localStartResult = sample.offset.subtractingReportingOverflow(segmentByteOffset)
                    guard !localStartResult.overflow else {
                        return .malformed(ParseFailure(
                            phase: .packetize, field: "sampleOffset", reason: "overflow"
                        ))
                    }
                    let localStart = localStartResult.partialValue
                    let localEndResult = localStart.addingReportingOverflow(sample.size)
                    guard !localEndResult.overflow else {
                        return .malformed(ParseFailure(
                            phase: .packetize, field: "sampleSpan", reason: "overflow"
                        ))
                    }
                    let localEnd = localEndResult.partialValue
                    guard localStart >= 0, localStart < localEnd,
                          localEnd <= buffer.count else {
                        return .malformed(ParseFailure(
                            phase: .packetize, boxType: "mdat", trackID: sample.trackID,
                            field: "sampleSpan", reason: "out_of_range",
                            availableBytes: buffer.count, offset: max(0, localStart)
                        ))
                    }
                    let (updatedBytes, bytesOverflowed) = totalBytes.addingReportingOverflow(sample.size)
                    guard !bytesOverflowed, updatedBytes <= maxPacketizedBytes else {
                        return .malformed(ParseFailure(
                            phase: .packetize, field: "sampleBytes", reason: "ceiling",
                            declaredCount: UInt64(max(0, updatedBytes))
                        ))
                    }
                    totalBytes = updatedBytes
                    let base = buffer.startIndex
                    out.append((
                        sample,
                        buffer.subdata(in: (base + localStart)..<(base + localEnd))
                    ))
                }
            }
        }
        return .success(out)
    }

    // MARK: - sidx (segment index, for D4 seek) — offsets absolute in resource

    struct SidxEntry: Equatable, Sendable {
        var offset: Int
        var size: Int
        var durationSeconds: Double
        var presentationStartSeconds: Double = 0
        var referenceType: Int = 0
        var startsWithSAP: Bool = false
        var sapType: Int = 0
        var sapDeltaTimeTicks: UInt32 = 0
        var timescale: UInt32? = nil
        var earliestPresentationTimeTicks: UInt64? = nil

        var declaresClosedGOPStart: Bool {
            startsWithSAP && (sapType == 1 || sapType == 2) && sapDeltaTimeTicks == 0
        }
    }

    static func parseSidxResult(
        _ data: Data,
        sidxAbsoluteStart: Int
    ) -> ParseResult<[SidxEntry]> {
        guard sidxAbsoluteStart >= 0 else {
            return .malformed(ParseFailure(
                phase: .sidx, boxType: "sidx", field: "absoluteStart", reason: "negative"
            ))
        }
        let box: Box
        switch parseBoxesResult(data, range: 0..<data.count) {
        case .success(let boxes):
            guard let found = boxes.first(where: { $0.type == "sidx" }) else {
                return .malformed(ParseFailure(
                    phase: .sidx, boxType: "sidx", field: "box", reason: "missing"
                ))
            }
            box = found
        case .needMoreData:
            return .malformed(truncatedFailure(phase: .sidx, boxType: "sidx", range: 0..<data.count))
        case .malformed(let failure): return .malformed(failure)
        case .unsupported(let unsupported): return .unsupported(unsupported)
        }
        var c = Cursor(data, box.payload)
        guard let vf = c.u32() else {
            return .malformed(truncatedFailure(phase: .sidx, boxType: "sidx", range: box.payload))
        }
        let version = vf >> 24
        guard version == 0 || version == 1 else {
            return .unsupported(ParseUnsupported(
                phase: .sidx, boxType: "sidx", field: "version",
                reason: "unsupported", version: version
            ))
        }
        guard c.skip(4), let timescale = c.u32() else {
            return .malformed(truncatedFailure(phase: .sidx, boxType: "sidx", range: box.payload))
        }
        guard timescale > 0 else {
            return .malformed(ParseFailure(
                phase: .sidx, boxType: "sidx", field: "timescale", reason: "zero"
            ))
        }
        let earliestPresentationTime: UInt64
        let firstOffset: UInt64
        if version == 0 {
            guard let ept = c.u32(), let offset = c.u32() else {
                return .malformed(truncatedFailure(phase: .sidx, boxType: "sidx", range: box.payload))
            }
            earliestPresentationTime = UInt64(ept)
            firstOffset = UInt64(offset)
        } else {
            guard let ept = c.u64(), let offset = c.u64() else {
                return .malformed(truncatedFailure(phase: .sidx, boxType: "sidx", range: box.payload))
            }
            earliestPresentationTime = ept
            firstOffset = offset
        }
        guard c.skip(2), let refCount = c.u16() else {
            return .malformed(truncatedFailure(phase: .sidx, boxType: "sidx", range: box.payload))
        }
        guard Int(refCount) <= c.remaining / 12 else {
            return .malformed(ParseFailure(
                phase: .sidx, boxType: "sidx", field: "referenceCount", reason: "row_bound",
                declaredCount: UInt64(refCount), availableBytes: c.remaining
            ))
        }
        guard Int(refCount) <= maxSidxEntries else {
            return .malformed(ParseFailure(
                phase: .sidx, boxType: "sidx", field: "referenceCount", reason: "ceiling",
                declaredCount: UInt64(refCount), availableBytes: c.remaining
            ))
        }
        guard firstOffset <= UInt64(Int.max),
              let firstOffsetBase = checkedAdd(
                  sidxAbsoluteStart, box.range.upperBound
              ), let absoluteBase = checkedAdd(
                  firstOffsetBase, Int(firstOffset)
              ) else {
            return .malformed(ParseFailure(
                phase: .sidx, boxType: "sidx", field: "first_offset", reason: "overflow"
            ))
        }
        let expectedEntryBytes = Int(refCount) * 12
        guard c.remaining >= expectedEntryBytes else {
            return .malformed(truncatedFailure(phase: .sidx, boxType: "sidx", range: box.payload))
        }
        let entriesStart = c.position
        let trailingBytes = c.remaining - expectedEntryBytes
        let timescaleDouble = Double(timescale)
        var cursorOffset = absoluteBase
        var elapsedTicks = earliestPresentationTime
        var entries: [SidxEntry] = []
        entries.reserveCapacity(Int(refCount))
        let failure: ParseResult<[SidxEntry]>? = data.withUnsafeBytes { raw in
            var pos = entriesStart
            for _ in 0..<refCount {
                let word = raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self).bigEndian
                let duration = raw.loadUnaligned(fromByteOffset: pos + 4, as: UInt32.self).bigEndian
                let sapWord = raw.loadUnaligned(fromByteOffset: pos + 8, as: UInt32.self).bigEndian
                pos += 12
                let referenceType = (word & 0x8000_0000) != 0
                guard !referenceType else {
                    return .unsupported(ParseUnsupported(
                        phase: .sidx, boxType: "sidx", field: "reference_type",
                        reason: "hierarchical"
                    ))
                }
                let size = Int(word & 0x7FFF_FFFF)
                guard size > 0 else {
                    return .malformed(ParseFailure(
                        phase: .sidx, boxType: "sidx", field: "reference_size", reason: "zero"
                    ))
                }
                let durationStart = Double(elapsedTicks) / timescaleDouble
                let durationSeconds = Double(duration) / timescaleDouble
                let tickResult = elapsedTicks.addingReportingOverflow(UInt64(duration))
                guard durationStart.isFinite, durationSeconds.isFinite,
                      !tickResult.overflow,
                      let nextOffset = checkedAdd(cursorOffset, size) else {
                    return .malformed(ParseFailure(
                        phase: .sidx, boxType: "sidx", field: "range_or_time", reason: "overflow"
                    ))
                }
                entries.append(SidxEntry(
                    offset: cursorOffset,
                    size: size,
                    durationSeconds: durationSeconds,
                    presentationStartSeconds: durationStart,
                    referenceType: 0,
                    startsWithSAP: (sapWord & 0x8000_0000) != 0,
                    sapType: Int((sapWord >> 28) & 0x7),
                    sapDeltaTimeTicks: sapWord & 0x0FFF_FFFF,
                    timescale: timescale,
                    earliestPresentationTimeTicks: earliestPresentationTime
                ))
                cursorOffset = nextOffset
                elapsedTicks = tickResult.partialValue
            }
            return nil
        }
        if let failure { return failure }
        guard trailingBytes == 0 else {
            return .malformed(ParseFailure(
                phase: .sidx, boxType: "sidx", field: "payload", reason: "trailing",
                availableBytes: trailingBytes
            ))
        }
        return .success(entries)
    }

    // MARK: - Box scanning

    struct Box: Equatable, Sendable { var type: String; var range: Range<Int>; var payload: Range<Int> }

    private static func parseBoxAtResult(
        _ data: Data,
        position: Int,
        enclosingEnd: Int
    ) -> ParseResult<Box> {
        guard position >= 0, position <= enclosingEnd, enclosingEnd <= data.count else {
            return .malformed(ParseFailure(
                phase: .box, field: "range", reason: "invalid", offset: max(0, position)
            ))
        }
        let remaining = enclosingEnd - position
        guard remaining >= 8 else {
            return .needMoreData(requiredBytes: 8 - remaining)
        }
        var cursor = Cursor(data, position..<enclosingEnd)
        guard let size32 = cursor.u32(), let type = cursor.fourCC() else {
            return .malformed(ParseFailure(
                phase: .box, field: "header", reason: "truncated", offset: position
            ))
        }
        let headerLength: Int
        let boxSize: Int
        if size32 == 1 {
            headerLength = 16
            guard remaining >= headerLength, let large = cursor.u64() else {
                return .needMoreData(requiredBytes: max(1, headerLength - remaining))
            }
            guard large >= UInt64(headerLength) else {
                return .malformed(ParseFailure(
                    phase: .box, boxType: type, field: "largesize",
                    reason: "too_small", offset: position
                ))
            }
            guard large <= UInt64(Int.max) else {
                return .malformed(ParseFailure(
                    phase: .box, boxType: type, field: "largesize",
                    reason: "overflow", offset: position
                ))
            }
            boxSize = Int(large)
        } else if size32 == 0 {
            headerLength = 8
            boxSize = remaining
        } else {
            headerLength = 8
            boxSize = Int(size32)
        }
        guard boxSize >= headerLength else {
            return .malformed(ParseFailure(
                phase: .box, boxType: type, field: "size",
                reason: "too_small", offset: position
            ))
        }
        guard boxSize <= maxBoxSize else {
            return .malformed(ParseFailure(
                phase: .box, boxType: type, field: "size", reason: "ceiling",
                offset: position
            ))
        }
        guard boxSize <= remaining else {
            return .needMoreData(requiredBytes: boxSize - remaining)
        }
        guard let end = checkedAdd(position, boxSize), end <= enclosingEnd else {
            return .malformed(ParseFailure(
                phase: .box, boxType: type, field: "end",
                reason: "overflow", offset: position
            ))
        }
        return .success(Box(
            type: type,
            range: position..<end,
            payload: (position + headerLength)..<end
        ))
    }

    static func parseBoxesResult(
        _ data: Data,
        range: Range<Int>
    ) -> ParseResult<[Box]> {
        guard validRange(range, in: data) else {
            return .malformed(ParseFailure(
                phase: .box, field: "range", reason: "invalid",
                offset: max(0, range.lowerBound)
            ))
        }
        var result: [Box] = []
        var position = range.lowerBound
        var boxCount = 0
        while position < range.upperBound {
            switch parseBoxAtResult(data, position: position, enclosingEnd: range.upperBound) {
            case .success(let box):
                guard boxCount < maxBoxesPerRange else {
                    return .malformed(ParseFailure(
                        phase: .box, field: "boxCount", reason: "ceiling",
                        declaredCount: UInt64(boxCount + 1), offset: position
                    ))
                }
                result.append(box)
                boxCount += 1
                position = box.range.upperBound
            case .needMoreData(let required): return .needMoreData(requiredBytes: required)
            case .malformed(let failure): return .malformed(failure)
            case .unsupported(let unsupported): return .unsupported(unsupported)
            }
        }
        return .success(result)
    }

    static func boxes(in data: Data, range: Range<Int>) -> [Box] {
        guard case .success(let result) = parseBoxesResult(data, range: range) else { return [] }
        return result
    }

    static func firstBox(_ type: String, in data: Data, range: Range<Int>) -> Box? {
        boxes(in: data, range: range).first { $0.type == type }
    }

    private static func validRange(_ range: Range<Int>, in data: Data) -> Bool {
        range.lowerBound >= 0
            && range.lowerBound <= range.upperBound
            && range.upperBound <= data.count
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func checkedEnd(start: Int, size: UInt64) -> Int? {
        guard size <= UInt64(Int.max) else { return nil }
        return checkedAdd(start, Int(size))
    }

    private static func truncatedFailure(
        phase: ParsePhase,
        boxType: String? = nil,
        range: Range<Int>
    ) -> ParseFailure {
        ParseFailure(
            phase: phase,
            boxType: boxType,
            field: "box",
            reason: "truncated",
            availableBytes: max(0, range.upperBound - range.lowerBound),
            offset: max(0, range.lowerBound)
        )
    }

    private static func parseFragmentSequence(
        _ data: Data,
        children: [Box]
    ) -> UInt32? {
        guard let mfhd = children.first(where: { $0.type == "mfhd" }) else { return nil }
        var c = Cursor(data, mfhd.payload)
        guard c.skip(4) else { return nil }
        return c.u32()
    }

    // MARK: - Cursor (big-endian, range-bounded)

    private struct Cursor {
        let data: Data
        let end: Int
        private(set) var position: Int
        init(_ d: Data, _ range: Range<Int>) {
            data = d
            position = range.lowerBound
            end = min(range.upperBound, d.count)
        }
        var remaining: Int { end - position }

        mutating func u16() -> UInt16? {
            guard remaining >= 2 else { return nil }
            let base = data.startIndex + position
            let v = (UInt16(data[base]) << 8) | UInt16(data[base + 1])
            position += 2
            return v
        }
        mutating func u32() -> UInt32? {
            guard remaining >= 4 else { return nil }
            let base = data.startIndex + position
            let v = (UInt32(data[base]) << 24)
                | (UInt32(data[base + 1]) << 16)
                | (UInt32(data[base + 2]) << 8)
                | UInt32(data[base + 3])
            position += 4
            return v
        }
        mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
        mutating func u64() -> UInt64? {
            guard remaining >= 8 else { return nil }
            let base = data.startIndex + position
            let high = (UInt32(data[base]) << 24)
                | (UInt32(data[base + 1]) << 16)
                | (UInt32(data[base + 2]) << 8)
                | UInt32(data[base + 3])
            let low = (UInt32(data[base + 4]) << 24)
                | (UInt32(data[base + 5]) << 16)
                | (UInt32(data[base + 6]) << 8)
                | UInt32(data[base + 7])
            position += 8
            return (UInt64(high) << 32) | UInt64(low)
        }
        mutating func fourCC() -> String? {
            guard remaining >= 4 else { return nil }
            let base = data.startIndex + position
            let b0 = data[base]
            let b1 = data[base + 1]
            let b2 = data[base + 2]
            let b3 = data[base + 3]
            position += 4
            guard (b0 | b1 | b2 | b3) < 0x80 else { return nil }
            var bytes = (b0, b1, b2, b3)
            return withUnsafeBytes(of: &bytes) { raw in
                String(decoding: raw, as: UTF8.self)
            }
        }
        @discardableResult mutating func skip(_ n: Int) -> Bool {
            guard remaining >= n else { return false }
            position += n; return true
        }
    }
}
