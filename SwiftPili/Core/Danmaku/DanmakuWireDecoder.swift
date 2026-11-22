import Foundation

/// One bullet comment, as the wire carries it.
///
/// `progress` is absolute media seconds. The wire carries absolute media
/// milliseconds, including in segments after the first (official segment 2:
/// oid109224, id17272184, progress415700). Segment indices select request
/// windows; they never shift element clocks.
struct DanmakuElem: Sendable, Equatable, Hashable {
    let id: Int64
    /// Absolute media seconds.
    let progress: TimeInterval
    /// The raw wire value, NOT an enum. An unknown mode is data, not a decode
    /// failure — BiliBili has added modes before and would otherwise be able to
    /// break the whole segment by introducing one.
    let mode: Int
    let fontSize: Int
    /// 0xRRGGBB.
    let color: UInt32
    /// CRC32 of the sender's mid. NOT reversible to a mid, which is why the
    /// user blocklist (`BlocklistManager`, a `Set<Int>` of real mids) cannot be
    /// matched against this without hashing the blocklist first.
    let midHash: String
    let content: String
    let idStr: String
    /// The viewer sent this one from this device. Never set by the decoder —
    /// the wire has no such field — only by the player's local echo of a
    /// successful post. The renderer frames it and never drops or filters it.
    var isSelfSent: Bool = false

    var renderKind: DanmakuRenderKind { DanmakuRenderKind(wireMode: mode) }

    /// idStr can identify a post whose reply omitted numeric dmid (the local
    /// echo then has a synthetic negative id). Normalize numeric strings so
    /// ordinary/package/echo copies share one identity without text matching.
    var identityKey: String? {
        if !idStr.isEmpty { return Int64(idStr).map(String.init) ?? idStr }
        return id == 0 ? nil : String(id)
    }
}

/// What the renderer is being asked to draw, as opposed to what the wire said.
///
/// `.unsupported` is a real answer and covers two different things deliberately:
/// a mode this app will never draw (8 = code danmaku, which is a script, and 9 =
/// BAS, which is its own language), and a mode that does not exist yet. Both are
/// filtered at the same place, and neither is a decode error.
enum DanmakuRenderKind: Sendable, Equatable, Hashable {
    case scroll
    case top
    case bottom
    case reverse
    case advanced
    case unsupported

    init(wireMode: Int) {
        switch wireMode {
        case 1: self = .scroll
        case 4: self = .bottom
        case 5: self = .top
        case 6: self = .reverse
        case 7: self = .advanced
        default: self = .unsupported
        }
    }
}

enum DanmakuDecodeError: Error, Equatable {
    /// The body is a JSON envelope, not protobuf. BiliBili answers a
    /// risk-control rejection with HTTP 200 and a `{"code":-352,...}` body, so
    /// the status line cannot be the discriminator — the first byte is.
    case riskControlEnvelope(code: Int, message: String)
    /// A length or varint ran past the end of the buffer.
    case truncated
    /// A length prefix claims more bytes than the buffer holds, or more than an
    /// `Int` can name. Separate from `.truncated` because it is the shape a
    /// CORRUPTED or hostile body takes rather than a cut-short one, and because
    /// converting it before checking it is a trap, not an error — measured.
    case lengthOutOfRange(UInt64)
    /// Protobuf defines four wire types this format can use; anything else means
    /// the bytes are not what they claim to be.
    case unsupportedWireType(Int)
    /// Segment indices are 1-based (`segment_index=1` is the first six minutes).
    /// A zero or negative index cannot name a server segment.
    case invalidSegmentIndex(Int)
}

/// Hand-rolled protobuf wire decoder for `x/v2/dm/web/seg.so` (repeated field-1
/// `DanmakuElem` messages with scalar fields).
enum DanmakuWireDecoder {
    // Wire field numbers inside `DanmakuElem`; unconsumed fields (ctime, weight, attr) are skipped.
    private enum Tag {
        static let id = 1
        static let progress = 2
        static let mode = 3
        static let fontSize = 4
        static let color = 5
        static let midHash = 6
        static let content = 7
        static let idStr = 12
    }

    /// proto3 does not transmit zero values, so an absent field is a DEFAULT and
    /// never a failure. Measured on the reference segment: `progress` is missing
    /// from 9 elements and `color` from 55 — a decoder that treated absence as
    /// malformed would reject a segment over bullets that are merely at t=0 or
    /// coloured black.
    private enum Default {
        static let mode = 1
        static let fontSize = 25
        static let color: UInt32 = 0xFF_FF_FF
    }

    /// - Parameters:
    ///   - data: the raw `seg.so` body.
    ///   - segmentIndex: 1-based, as the query parameter uses it.
    /// - Returns: elements with ABSOLUTE media-second timestamps, in wire order.
    ///   Sorting is the store's job — this returns what the segment said.
    static func decode(
        _ data: Data,
        segmentIndex: Int
    ) throws(DanmakuDecodeError) -> [DanmakuElem] {
        guard segmentIndex >= 1 else { throw .invalidSegmentIndex(segmentIndex) }
        if let envelope = riskControlEnvelope(in: data) { throw envelope }

        // One contiguous read over the whole body. `Data`'s own subscript goes
        // through bounds/indexing machinery per byte, which is measurable over
        // 1.2 MB; the raw buffer keeps the tag loop to pointer arithmetic.
        //
        // The `Result` round-trip is not decoration. `withUnsafeBytes` is
        // `rethrows` over an untyped closure, and `rethrows` does NOT carry a
        // typed throw through — handing it a `throws(DanmakuDecodeError)` body
        // erases to `any Error` and stops compiling. Catching at the boundary
        // and unwrapping outside keeps this function's typed signature, which is
        // what lets every caller switch over the cases exhaustively.
        let outcome = data.withUnsafeBytes { raw -> Result<[DanmakuElem], DanmakuDecodeError> in
            do {
                return .success(try decodeElements(raw))
            } catch let error as DanmakuDecodeError {
                return .failure(error)
            } catch {
                // Unreachable. `decodeElements` is `throws(DanmakuDecodeError)`
                // and nothing else in the block throws; this arm exists only
                // because `rethrows` erased the type on the way in, and the
                // compiler cannot see that the erasure is lossless here. Assert
                // the invariant rather than inventing a case — a fabricated
                // `.truncated` would describe a buffer that is fine.
                preconditionFailure("DanmakuWireDecoder: untyped throw \(error)")
            }
        }
        return try outcome.get()
    }

    private static func decodeElements(
        _ raw: UnsafeRawBufferPointer
    ) throws(DanmakuDecodeError) -> [DanmakuElem] {
        var cursor = DanmakuWireCursor(raw)
        var elems: [DanmakuElem] = []
        // The reference segment holds 5,861 in 1.2 MB. Reserving off the byte
        // count keeps this to one or two growth steps instead of ~13.
        elems.reserveCapacity(raw.count / 192)

        while !cursor.isAtEnd {
            let (field, wire) = try cursor.readTag()
            guard field == 1, wire == .lengthDelimited else {
                try cursor.skip(wire)
                continue
            }
            let body = try cursor.readLengthDelimited()
            elems.append(try decodeElement(body))
        }
        return elems
    }

    private static func decodeElement(
        _ raw: UnsafeRawBufferPointer
    ) throws(DanmakuDecodeError) -> DanmakuElem {
        var cursor = DanmakuWireCursor(raw)
        var id: Int64 = 0
        var progressMS: Int = 0
        var mode = Default.mode
        var fontSize = Default.fontSize
        var color = Default.color
        var midHash = ""
        var content = ""
        var idStr = ""

        while !cursor.isAtEnd {
            let (field, wire) = try cursor.readTag()
            switch (field, wire) {
            case (Tag.id, .varint):        id = Int64(bitPattern: try cursor.readVarint())
            // `Int(clamping:)`, not `Int(_:)`. These are network-supplied
            // varints and a full-width one traps the plain conversion — the
            // same defect as the length prefix above, measured the same way. A
            // clamped value is harmless: a progress of `Int.max` ms lands
            // outside every segment and simply never renders, which is the
            // right outcome for a bullet whose timestamp is nonsense.
            case (Tag.progress, .varint):  progressMS = Int(clamping: try cursor.readVarint())
            case (Tag.mode, .varint):      mode = Int(clamping: try cursor.readVarint())
            case (Tag.fontSize, .varint):  fontSize = Int(clamping: try cursor.readVarint())
            case (Tag.color, .varint):     color = UInt32(truncatingIfNeeded: try cursor.readVarint())
            case (Tag.midHash, .lengthDelimited): midHash = try cursor.readString()
            case (Tag.content, .lengthDelimited): content = try cursor.readString()
            case (Tag.idStr, .lengthDelimited):   idStr = try cursor.readString()
            default: try cursor.skip(wire)
            }
        }

        return DanmakuElem(
            id: id,
            progress: TimeInterval(progressMS) / 1000,
            mode: mode,
            fontSize: fontSize,
            color: color,
            midHash: midHash,
            content: content,
            idStr: idStr
        )
    }

    /// A protobuf body's first byte is the tag for field 1, wire type 2 — `0x0A`
    /// — and can never be `{`. That one byte is the only reliable discriminator:
    /// the rejection arrives as HTTP 200 with a JSON envelope, so neither the
    /// status code nor the content type separates them.
    ///
    /// Returns the typed error to throw, or nil when the body is protobuf.
    private static func riskControlEnvelope(in data: Data) -> DanmakuDecodeError? {
        guard data.first == UInt8(ascii: "{") else { return nil }
        struct Envelope: Decodable {
            let code: Int
            let message: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            // It opened with `{` and is not the envelope either. Still not
            // protobuf, and still must not reach the tag loop.
            return .riskControlEnvelope(code: 0, message: "unrecognised non-protobuf body")
        }
        return .riskControlEnvelope(code: envelope.code, message: envelope.message ?? "")
    }

}
