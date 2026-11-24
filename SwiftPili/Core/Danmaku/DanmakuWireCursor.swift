import Foundation

enum DanmakuWireType: Int {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

struct DanmakuWireCursor {
    private let raw: UnsafeRawBufferPointer
    private var index: Int

    init(_ raw: UnsafeRawBufferPointer) {
        self.raw = raw
        self.index = 0
    }

    var isAtEnd: Bool { index >= raw.count }

    mutating func readVarint() throws(DanmakuDecodeError) -> UInt64 {
        guard index < raw.count else { throw .truncated }
        let first = raw[index]
        index += 1
        if first < 0x80 { return UInt64(first) }
        var result = UInt64(first & 0x7F)
        var shift: UInt64 = 7
        while true {
            guard index < raw.count else { throw .truncated }
            let byte = raw[index]
            index += 1
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
        let remaining = UInt64(raw.count - index)
        guard claimed <= remaining else { throw .lengthOutOfRange(claimed) }
        let length = Int(claimed)
        let slice = UnsafeRawBufferPointer(rebasing: raw[index ..< index + length])
        index += length
        return slice
    }

    mutating func readString() throws(DanmakuDecodeError) -> String {
        let slice = try readLengthDelimited()
        if slice.isEmpty { return "" }
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
