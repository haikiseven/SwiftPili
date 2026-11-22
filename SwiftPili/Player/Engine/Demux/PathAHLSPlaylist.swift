import Foundation

struct PathAHLSPlaylist: Equatable, Sendable {
    static let maxPlaylistBytes = PathAHLSMediaPlaylist.maxPlaylistBytes
    typealias Segment = PathAHLSMediaPlaylist.Segment

    let mediaSequence: Int
    let targetDuration: TimeInterval
    let mapURL: URL
    let segments: [Segment]
    let isEndList: Bool

    static func parse(_ text: String, relativeTo playlistURL: URL) throws -> Self {
        do {
            let playlist = try PathAHLSMediaPlaylist.parse(text, relativeTo: playlistURL, format: .fmp4)
            guard let mapURL = playlist.mapURL else {
                throw PathAHLSMediaPlaylist.Failure.invalid("missing fMP4 init map")
            }
            return Self(
                mediaSequence: playlist.mediaSequence, targetDuration: playlist.targetDuration,
                mapURL: mapURL, segments: playlist.segments, isEndList: playlist.isEndList
            )
        } catch let failure as PathAHLSMediaPlaylist.Failure {
            throw MediaEngineError.demuxFailed(failure.diagnostic)
        }
    }
}

struct PathAHLSMediaPlaylist: Sendable {
    static let maxPlaylistBytes = 1024 * 1024

    struct Segment: Equatable, Hashable, Sendable {
        let sequence: Int
        let duration: TimeInterval
        let url: URL
        let discontinuitySequence: Int
        let isGap: Bool
    }

    enum Format { case fmp4, mpegTS }

    enum Failure: Error {
        case invalid(String)
        case unsupported(String)

        var diagnostic: String {
            switch self {
            case .invalid(let reason), .unsupported(let reason): "HLS playlist: \(reason)"
            }
        }
    }

    private(set) var mediaSequence = 0
    private(set) var targetDuration: TimeInterval = 1
    private(set) var mapURL: URL?
    private(set) var segments: [Segment] = []
    private(set) var isEndList = false

    static func parse(_ text: String, relativeTo playlistURL: URL, format: Format) throws -> Self {
        guard text.utf8.count <= maxPlaylistBytes else {
            throw Failure.invalid("response exceeds bound")
        }
        let lines = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { throw Failure.invalid("missing EXTM3U") }

        var parser = Parser(playlistURL: playlistURL, format: format)
        for line in lines.dropFirst() { try parser.consume(line) }
        guard parser.pendingDuration == nil, !parser.pendingGap else {
            throw Failure.invalid(parser.pendingGap ? "dangling gap" : "dangling EXTINF")
        }
        return parser.playlist
    }

    private struct Parser {
        let playlistURL: URL
        let format: Format
        var playlist = PathAHLSMediaPlaylist()
        var pendingDuration: TimeInterval?
        var pendingGap = false
        private var discontinuitySequence = 0
        private var sawDiscontinuity = false
        private var sawSequence = false
        private var sawDiscontinuitySequence = false

        init(playlistURL: URL, format: Format) {
            self.playlistURL = playlistURL
            self.format = format
        }

        mutating func consume(_ line: String) throws {
            guard line.hasPrefix("#") else {
                try appendSegment(line)
                return
            }
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let tag = fields.first else { return }
            let value = fields.count == 2 ? fields[1] : nil
            try admitTag(tag, value: value)
            switch tag {
            case "#EXT-X-DISCONTINUITY", "#EXT-X-DISCONTINUITY-SEQUENCE", "#EXT-X-GAP":
                try updateBoundary(tag, value: value)
            case "#EXT-X-MEDIA-SEQUENCE", "#EXT-X-TARGETDURATION", "#EXTINF":
                if let value { try setNumber(tag, value: value) }
            case "#EXT-X-MAP":
                if value != nil { try setMap(line) }
            case "#EXT-X-ENDLIST":
                if value == nil { playlist.isEndList = true }
            default:
                break
            }
        }

        private func admitTag(_ tag: Substring, value: Substring?) throws {
            switch tag {
            case "#EXT-X-KEY":
                guard let value else { return }
                guard isUnencryptedKey(value) else {
                    throw Failure.unsupported("encrypted input unsupported")
                }
            case "#EXT-X-BYTERANGE", "#EXT-X-PART", "#EXT-X-PRELOAD-HINT":
                if value != nil { throw Failure.unsupported("partial/byte-range input unsupported") }
            case "#EXT-X-STREAM-INF", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-I-FRAMES-ONLY",
                 "#EXT-X-SKIP", "#EXT-X-SESSION-KEY":
                if format == .mpegTS {
                    throw Failure.unsupported("requires a complete-segment media playlist")
                }
            default:
                break
            }
        }

        private func isUnencryptedKey(_ attributes: Substring) -> Bool {
            var sawMethod = false
            var insideQuotes = false
            for field in attributes.split(separator: ",", omittingEmptySubsequences: false) {
                if !insideQuotes, field.hasPrefix("METHOD=") {
                    guard !sawMethod, field == "METHOD=NONE" else { return false }
                    sawMethod = true
                }
                for character in field where character == "\"" { insideQuotes.toggle() }
            }
            return sawMethod && !insideQuotes
        }

        private mutating func setNumber(_ tag: Substring, value: Substring) throws {
            switch tag {
            case "#EXT-X-MEDIA-SEQUENCE":
                guard let sequence = Int(value), sequence >= 0,
                      format == .fmp4 || (!sawSequence && playlist.segments.isEmpty) else {
                    throw Failure.invalid("invalid media sequence")
                }
                sawSequence = true
                playlist.mediaSequence = sequence
            case "#EXT-X-TARGETDURATION":
                guard let duration = TimeInterval(value), duration.isFinite, duration > 0 else {
                    throw Failure.invalid("invalid target duration")
                }
                playlist.targetDuration = duration
            default:
                guard format == .fmp4 || pendingDuration == nil,
                      let raw = value.split(separator: ",", maxSplits: 1).first,
                      let duration = TimeInterval(raw), duration.isFinite, duration > 0 else {
                    throw Failure.invalid("invalid segment duration")
                }
                pendingDuration = duration
            }
        }

        private mutating func updateBoundary(_ tag: Substring, value: Substring?) throws {
            if format == .fmp4 {
                if tag == "#EXT-X-DISCONTINUITY", value == nil {
                    throw Failure.invalid("discontinuity requires reload")
                }
                return
            }
            switch tag {
            case "#EXT-X-DISCONTINUITY":
                let incremented = discontinuitySequence.addingReportingOverflow(1)
                guard !incremented.overflow else { throw Failure.invalid("discontinuity sequence overflow") }
                discontinuitySequence = incremented.partialValue
                sawDiscontinuity = true
            case "#EXT-X-DISCONTINUITY-SEQUENCE":
                guard playlist.segments.isEmpty, !sawDiscontinuity, !sawDiscontinuitySequence,
                      let value, let sequence = Int(value), sequence >= 0 else {
                    throw Failure.invalid("invalid discontinuity sequence")
                }
                sawDiscontinuitySequence = true
                discontinuitySequence = sequence
            default:
                pendingGap = true
            }
        }

        private mutating func setMap(_ line: String) throws {
            guard format == .fmp4 else { throw Failure.unsupported("MPEG-TS rendition has an init map") }
            guard !line.localizedCaseInsensitiveContains("BYTERANGE"),
                  let start = line.range(of: "URI=\""),
                  let end = line[start.upperBound...].firstIndex(of: "\"") else {
                throw Failure.invalid("invalid init map")
            }
            let path = String(line[start.upperBound..<end])
            guard let url = URL(string: path, relativeTo: playlistURL)?.absoluteURL else {
                throw Failure.invalid("invalid init map")
            }
            playlist.mapURL = url
        }

        private mutating func appendSegment(_ line: String) throws {
            guard let duration = pendingDuration,
                  let url = URL(string: line, relativeTo: playlistURL)?.absoluteURL else {
                throw Failure.invalid("segment missing EXTINF or URL")
            }
            if format == .mpegTS, !DemandLiveHTTPTransport.isHTTPURL(url) {
                throw Failure.invalid("invalid segment URL")
            }
            let sequence = playlist.mediaSequence.addingReportingOverflow(playlist.segments.count)
            guard !sequence.overflow else { throw Failure.invalid("media sequence overflow") }
            playlist.segments.append(Segment(
                sequence: sequence.partialValue, duration: duration, url: url,
                discontinuitySequence: discontinuitySequence, isGap: pendingGap
            ))
            pendingDuration = nil
            pendingGap = false
        }
    }
}
