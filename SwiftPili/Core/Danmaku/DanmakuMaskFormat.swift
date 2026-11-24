import Compression
import CoreGraphics
import Foundation

struct DanmakuMaskInfo: Decodable, Sendable, Equatable {
    let cid: Int?
    let fps: Int?
    let maskURL: URL?

    init(cid: Int?, fps: Int?, maskURL: URL?) {
        self.cid = cid
        self.fps = fps
        self.maskURL = maskURL
    }

    private enum CodingKeys: String, CodingKey {
        case cid
        case fps
        case maskURL = "mask_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cid = try? container.decodeIfPresent(Int.self, forKey: .cid)
        fps = try? container.decodeIfPresent(Int.self, forKey: .fps)
        let raw = (try? container.decodeIfPresent(String.self, forKey: .maskURL)) ?? nil
        maskURL = raw.flatMap(Self.resolve)
    }

    static func resolve(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let absolute = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard let url = URL(string: absolute), url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        return url
    }
}

struct DanmakuMaskIndex: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let startMs: Int64
        let offset: Int64
    }

    let entries: [Entry]

    var count: Int { entries.count }

    func byteRange(of index: Int) -> (from: Int64, through: Int64?)? {
        guard entries.indices.contains(index) else { return nil }
        let from = entries[index].offset
        guard index + 1 < entries.count else { return (from, nil) }
        let next = entries[index + 1].offset
        guard next > from else { return nil }
        return (from, next - 1)
    }

    func segment(containing mediaTime: TimeInterval) -> Int? {
        guard mediaTime.isFinite else { return nil }
        let milliseconds = Int64((mediaTime * 1000).rounded(.down))
        var low = 0
        var high = entries.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if entries[mid].startMs <= milliseconds {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    func start(of index: Int) -> TimeInterval? {
        guard entries.indices.contains(index) else { return nil }
        return TimeInterval(entries[index].startMs) / 1000
    }

    func declaredEnd(of index: Int) -> TimeInterval? {
        guard entries.indices.contains(index + 1) else { return nil }
        return TimeInterval(entries[index + 1].startMs) / 1000
    }
}

struct DanmakuMaskFrame: @unchecked Sendable {
    let time: TimeInterval
    let path: CGPath
}

struct DanmakuMaskSegment: @unchecked Sendable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
    let canvas: CGSize
    let frames: [DanmakuMaskFrame]
}

enum DanmakuMaskFormatError: Error, Equatable, CustomStringConvertible {
    case badMagic
    case unsupported(version: UInt32, kind: UInt8)
    case truncated(String)
    case gzip
    case svg(String)
    case empty

    var description: String {
        switch self {
        case .badMagic: "badMagic"
        case let .unsupported(version, kind): "unsupported(version: \(version), kind: \(kind))"
        case .truncated(let what): "truncated(\(what))"
        case .gzip: "gzip"
        case .svg(let what): "svg(\(what))"
        case .empty: "empty"
        }
    }
}

enum DanmakuMaskFormat {
    static let headerLength = 16
    static let indexEntryLength = 16
    static let webmaskKind: UInt8 = 2

    static func segmentCount(header data: Data) throws -> Int {
        guard data.count >= headerLength else { throw DanmakuMaskFormatError.truncated("header") }
        return try data.withUnsafeBytes { raw -> Int in
            guard raw[0] == 0x4D, raw[1] == 0x41, raw[2] == 0x53, raw[3] == 0x4B else {
                throw DanmakuMaskFormatError.badMagic
            }
            let version = readUInt32(raw, at: 4)
            let kind = raw[8]
            guard version == 1, kind == webmaskKind else {
                throw DanmakuMaskFormatError.unsupported(version: version, kind: kind)
            }
            let count = Int(readUInt32(raw, at: 12))
            guard count > 0 else { throw DanmakuMaskFormatError.empty }
            return count
        }
    }

    static func indexByteCount(segments: Int) -> Int {
        headerLength + segments * indexEntryLength
    }

    static func index(from data: Data) throws -> DanmakuMaskIndex {
        let count = try segmentCount(header: data)
        let needed = indexByteCount(segments: count)
        guard data.count >= needed else { throw DanmakuMaskFormatError.truncated("index") }
        let entries = try data.withUnsafeBytes { raw -> [DanmakuMaskIndex.Entry] in
            var entries: [DanmakuMaskIndex.Entry] = []
            entries.reserveCapacity(count)
            for slot in 0 ..< count {
                let base = headerLength + slot * indexEntryLength
                let start = Int64(bitPattern: readUInt64(raw, at: base))
                let offset = Int64(bitPattern: readUInt64(raw, at: base + 8))
                guard start >= 0, offset >= Int64(needed) else {
                    throw DanmakuMaskFormatError.truncated("index entry \(slot)")
                }
                if let previous = entries.last, start < previous.startMs || offset <= previous.offset {
                    throw DanmakuMaskFormatError.truncated("index order at \(slot)")
                }
                entries.append(.init(startMs: start, offset: offset))
            }
            return entries
        }
        return DanmakuMaskIndex(entries: entries)
    }

    static func segment(
        _ compressed: Data,
        index: Int,
        start: TimeInterval,
        declaredEnd: TimeInterval?
    ) throws -> DanmakuMaskSegment {
        let raw = try gunzip(compressed)
        var frames: [DanmakuMaskFrame] = []
        var canvas: CGSize?
        try raw.withUnsafeBytes { bytes in
            var cursor = 0
            let total = bytes.count
            let baseIndex = raw.startIndex
            while cursor < total {
                guard cursor + 12 <= total else { throw DanmakuMaskFormatError.truncated("frame header") }
                let length = Int(readUInt32(bytes, at: cursor))
                let timeMs = Int64(bitPattern: readUInt64(bytes, at: cursor + 4))
                let body = cursor + 12
                guard length > 0, body + length <= total else {
                    throw DanmakuMaskFormatError.truncated("frame body")
                }
                let payload = raw[(baseIndex + body) ..< (baseIndex + body + length)]
                let svg = try DanmakuMaskSVG.text(fromDataURL: payload)
                let parsed = try DanmakuMaskSVG.path(svg)
                if canvas == nil { canvas = parsed.canvas }
                frames.append(DanmakuMaskFrame(time: TimeInterval(timeMs) / 1000, path: parsed.path))
                cursor = body + length
            }
        }
        guard let canvas, let last = frames.last else { throw DanmakuMaskFormatError.empty }
        let interval: TimeInterval = frames.count >= 2
            ? max(0.001, last.time - frames[frames.count - 2].time)
            : 1.0 / 30
        let end = max(declaredEnd ?? (last.time + interval), last.time + 0.001)
        return DanmakuMaskSegment(
            index: index,
            start: min(start, frames[0].time),
            end: end,
            canvas: canvas,
            frames: frames
        )
    }

    // MARK: - gzip

    static func gunzip(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { bytes -> Data in
            guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
                throw DanmakuMaskFormatError.gzip
            }
            let flags = bytes[3]
            var cursor = 10
            if flags & 0x04 != 0 {
                guard cursor + 2 <= bytes.count else { throw DanmakuMaskFormatError.gzip }
                let extraLength = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
                cursor += 2 + extraLength
            }
            if flags & 0x08 != 0 { cursor = try skipZeroTerminated(bytes, from: cursor) }
            if flags & 0x10 != 0 { cursor = try skipZeroTerminated(bytes, from: cursor) }
            if flags & 0x02 != 0 { cursor += 2 }
            let trailer = bytes.count - 8
            guard cursor < trailer else { throw DanmakuMaskFormatError.gzip }
            let declared = Int(bytes[trailer + 4]) | Int(bytes[trailer + 5]) << 8
                | Int(bytes[trailer + 6]) << 16 | Int(bytes[trailer + 7]) << 24
            let capacity = max(declared, 1)
            guard capacity <= 64 << 20 else { throw DanmakuMaskFormatError.gzip }
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination -> Int in
                guard let input = bytes.bindMemory(to: UInt8.self).baseAddress,
                      let target = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    target, capacity,
                    input + cursor, trailer - cursor,
                    nil, COMPRESSION_ZLIB
                )
            }
            guard written == declared, written > 0 else { throw DanmakuMaskFormatError.gzip }
            return output
        }
    }

    private static func skipZeroTerminated(_ bytes: UnsafeRawBufferPointer, from start: Int) throws -> Int {
        var cursor = start
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        guard cursor < bytes.count else { throw DanmakuMaskFormatError.gzip }
        return cursor + 1
    }

    // MARK: - bytes

    private static func readUInt32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        UInt64(readUInt32(bytes, at: offset)) << 32 | UInt64(readUInt32(bytes, at: offset + 4))
    }
}
