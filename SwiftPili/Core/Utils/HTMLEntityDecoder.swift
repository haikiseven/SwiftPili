import Foundation

enum HTMLEntityDecoder {
    static func decode(_ raw: String) -> String {
        guard raw.utf8.contains(0x26) else { return raw } // '&'
        let bytes = Array(raw.utf8)
        let count = bytes.count
        var output: [UInt8]?
        var copyStart = 0
        var index = 0

        while index < count {
            guard bytes[index] == 0x26 else {
                index += 1
                continue
            }
            if let (scalar, next) = decodeEntity(bytes, from: index) {
                if output == nil {
                    var buffer: [UInt8] = []
                    buffer.reserveCapacity(count)
                    output = buffer
                }
                if copyStart < index {
                    output!.append(contentsOf: bytes[copyStart ..< index])
                }
                output!.append(contentsOf: scalar.utf8)
                index = next
                copyStart = next
            } else {
                index += 1
            }
        }

        guard var decoded = output else { return raw }
        if copyStart < count {
            decoded.append(contentsOf: bytes[copyStart ..< count])
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private static func decodeEntity(_ bytes: [UInt8], from start: Int) -> (Unicode.Scalar, Int)? {
        let count = bytes.count
        var index = start + 1
        guard index < count else { return nil }

        if bytes[index] == 0x23 { // '#'
            index += 1
            guard index < count else { return nil }
            let isHex = bytes[index] == 0x78 || bytes[index] == 0x58 // 'x' / 'X'
            if isHex { index += 1 }
            let digitsStart = index
            var value: UInt32 = 0
            while index < count, bytes[index] != 0x3B { // ';'
                guard index - digitsStart < 8 else { return nil }
                let byte = bytes[index]
                let digit: UInt32
                if byte >= 0x30, byte <= 0x39 {
                    digit = UInt32(byte - 0x30)
                } else if isHex, byte >= 0x61, byte <= 0x66 {
                    digit = UInt32(byte - 0x61 + 10)
                } else if isHex, byte >= 0x41, byte <= 0x46 {
                    digit = UInt32(byte - 0x41 + 10)
                } else {
                    return nil
                }
                value = value &* (isHex ? 16 : 10) &+ digit
                index += 1
            }
            guard index < count, index > digitsStart, let scalar = Unicode.Scalar(value) else {
                return nil
            }
            return (scalar, index + 1)
        }

        let nameStart = index
        let maxEnd = min(count, nameStart + 5)
        while index < maxEnd, bytes[index] != 0x3B { // ';'
            index += 1
        }
        guard index < count, bytes[index] == 0x3B else { return nil }
        let length = index - nameStart
        let scalar: Unicode.Scalar? = switch length {
        case 2:
            if bytes[nameStart] == 0x6C, bytes[nameStart + 1] == 0x74 { // lt
                "<"
            } else if bytes[nameStart] == 0x67, bytes[nameStart + 1] == 0x74 { // gt
                ">"
            } else {
                nil
            }
        case 3:
            if bytes[nameStart] == 0x61, bytes[nameStart + 1] == 0x6D, bytes[nameStart + 2] == 0x70 { // amp
                "&"
            } else {
                nil
            }
        case 4:
            if bytes[nameStart] == 0x71, bytes[nameStart + 1] == 0x75,
               bytes[nameStart + 2] == 0x6F, bytes[nameStart + 3] == 0x74 { // quot
                "\""
            } else if bytes[nameStart] == 0x61, bytes[nameStart + 1] == 0x70,
                      bytes[nameStart + 2] == 0x6F, bytes[nameStart + 3] == 0x73 { // apos
                "'"
            } else if bytes[nameStart] == 0x6E, bytes[nameStart + 1] == 0x62,
                      bytes[nameStart + 2] == 0x73, bytes[nameStart + 3] == 0x70 { // nbsp
                "\u{00A0}"
            } else {
                nil
            }
        default:
            nil
        }
        guard let scalar else { return nil }
        return (scalar, index + 1)
    }
}
