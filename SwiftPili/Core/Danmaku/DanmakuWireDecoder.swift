import Foundation

struct DanmakuElem: Sendable, Equatable, Hashable {
    let id: Int64
    let progress: TimeInterval
    let mode: Int
    let fontSize: Int
    let color: UInt32
    let midHash: String
    let content: String
    let idStr: String
    var isSelfSent: Bool = false

    var renderKind: DanmakuRenderKind { DanmakuRenderKind(wireMode: mode) }

    var identityKey: String? {
        if !idStr.isEmpty {
            if Self.isCanonicalPositiveInt64Decimal(idStr) { return idStr }
            return Int64(idStr).map(String.init) ?? idStr
        }
        return id == 0 ? nil : String(id)
    }

    private static func isCanonicalPositiveInt64Decimal(_ value: String) -> Bool {
        let utf8 = value.utf8
        let count = utf8.count
        guard count >= 1, count <= 18 else { return false }
        var iterator = utf8.makeIterator()
        guard let first = iterator.next(), first >= UInt8(ascii: "1"), first <= UInt8(ascii: "9") else {
            return false
        }
        while let byte = iterator.next() {
            if byte < UInt8(ascii: "0") || byte > UInt8(ascii: "9") { return false }
        }
        return true
    }
}

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
    case riskControlEnvelope(code: Int, message: String)
    case truncated
    case lengthOutOfRange(UInt64)
    case unsupportedWireType(Int)
    case invalidSegmentIndex(Int)
}

enum DanmakuWireDecoder {
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

    private enum Default {
        static let mode = 1
        static let fontSize = 25
        static let color: UInt32 = 0xFF_FF_FF
    }

    static func decode(
        _ data: Data,
        segmentIndex: Int
    ) throws(DanmakuDecodeError) -> [DanmakuElem] {
        guard segmentIndex >= 1 else { throw .invalidSegmentIndex(segmentIndex) }
        if let envelope = riskControlEnvelope(in: data) { throw envelope }

        let outcome = data.withUnsafeBytes { raw -> Result<[DanmakuElem], DanmakuDecodeError> in
            do {
                return .success(try decodeElements(raw))
            } catch let error as DanmakuDecodeError {
                return .failure(error)
            } catch {
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
        elems.reserveCapacity(max(16, raw.count / 96))

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

    private static func riskControlEnvelope(in data: Data) -> DanmakuDecodeError? {
        guard data.first == UInt8(ascii: "{") else { return nil }
        struct Envelope: Decodable {
            let code: Int
            let message: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .riskControlEnvelope(code: 0, message: "unrecognised non-protobuf body")
        }
        return .riskControlEnvelope(code: envelope.code, message: envelope.message ?? "")
    }

}
