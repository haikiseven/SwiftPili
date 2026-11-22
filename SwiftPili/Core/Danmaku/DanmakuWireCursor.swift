import Foundation

/// Checked protobuf reader. Its buffer and all slices stay inside withUnsafeBytes.
enum DanmakuWireType: Int {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

/// A moving read head over one buffer. A struct with an index rather than a
/// class: the element loop makes one per element, and this way that costs
/// nothing and cannot be aliased by the caller.
struct DanmakuWireCursor {
    private let raw: UnsafeRawBufferPointer
    private var index: Int

    init(_ raw: UnsafeRawBufferPointer) {
        self.raw = raw
        self.index = 0
    }

    var isAtEnd: Bool { index >= raw.count }

    mutating func readVarint() throws(DanmakuDecodeError) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < raw.count else { throw .truncated }
            let byte = raw[index]
            index += 1
            // Past 63 bits the remaining payload bits cannot affect the
            // value; keep consuming the continuation bytes so the stream
            // stays framed, but stop shifting rather than trapping.
            if shift < 64 {
                result |= UInt64(byte & 0x7F) << shift
                shift += 7
            }
            if byte & 0x80 == 0 { return result }
        }
    }

    mutating func readTag() throws(DanmakuDecodeError) -> (field: Int, wire: DanmakuWireType) {
        let key = try readVarint()
        let rawWire = Int(key & 0x07)
        guard let wire = DanmakuWireType(rawValue: rawWire) else {
            throw .unsupportedWireType(rawWire)
        }
        return (Int(key >> 3), wire)
    }

    mutating func readLengthDelimited() throws(DanmakuDecodeError) -> UnsafeRawBufferPointer {
        let claimed = try readVarint()
        // Compare BEFORE converting. `Int(someUInt64)` traps on anything
        // above `Int.max`, and this buffer is network input: a corrupted
        // length prefix would take the app down instead of raising an
        // error. Measured against a body whose prefix is 2^63.
        let remaining = UInt64(raw.count - index)
        guard claimed <= remaining else { throw .lengthOutOfRange(claimed) }
        let length = Int(claimed)
        let slice = UnsafeRawBufferPointer(rebasing: raw[index ..< index + length])
        index += length
        return slice
    }

    mutating func readString() throws(DanmakuDecodeError) -> String {
        let slice = try readLengthDelimited()
        // Invalid UTF-8 becomes replacement characters rather than a thrown
        // error: one bullet with a broken byte must not cost the segment.
        // Lossy replacement is intentional: one invalid text byte preserves its segment.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: slice, as: UTF8.self)
    }

    mutating func skip(_ wire: DanmakuWireType) throws(DanmakuDecodeError) {
        switch wire {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            guard index + 8 <= raw.count else { throw .truncated }
            index += 8
        case .fixed32:
            guard index + 4 <= raw.count else { throw .truncated }
            index += 4
        case .lengthDelimited:
            _ = try readLengthDelimited()
        }
    }
}
