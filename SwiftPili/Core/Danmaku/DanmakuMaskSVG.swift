import CoreGraphics
import Foundation

enum DanmakuMaskSVG {
    static func text(fromDataURL payload: Data) throws -> String {
        guard let comma = payload.firstIndex(of: UInt8(ascii: ",")) else {
            throw DanmakuMaskFormatError.svg("no data URL comma")
        }
        let encoded = payload[payload.index(after: comma)...]
        guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let text = String(data: decoded, encoding: .utf8) else {
            throw DanmakuMaskFormatError.svg("base64")
        }
        return text
    }

    static func path(_ svg: String) throws -> (canvas: CGSize, path: CGPath) {
        let full = svg[...]
        guard let viewBox = attribute("viewBox", in: full) else { throw DanmakuMaskFormatError.svg("viewBox") }
        let box = numbers(in: viewBox)
        guard box.count == 4, box[2] > 0, box[3] > 0 else { throw DanmakuMaskFormatError.svg("viewBox values") }
        var builder = PathBuilder(transform: attribute("transform", in: full).map(parseTransform) ?? .identity)
        var searchStart = svg.startIndex
        var found = false
        while let range = svg.range(of: "<path", range: searchStart ..< svg.endIndex) {
            let tagEnd = svg.range(of: ">", range: range.upperBound ..< svg.endIndex)?.lowerBound ?? svg.endIndex
            if let data = attribute("d", in: svg[range.lowerBound ..< tagEnd]) {
                try builder.append(data)
                found = true
            }
            searchStart = tagEnd
        }
        guard found else { throw DanmakuMaskFormatError.svg("no path") }
        return (CGSize(width: box[2], height: box[3]), builder.path)
    }

    private static func attribute(_ name: String, in text: Substring) -> Substring? {
        guard let start = text.range(of: " \(name)=\"") ?? text.range(of: "\n\(name)=\"") else { return nil }
        guard let end = text.range(of: "\"", range: start.upperBound ..< text.endIndex) else { return nil }
        return text[start.upperBound ..< end.lowerBound]
    }

    private static func parseTransform(_ text: Substring) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = text
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let values = numbers(in: rest[rest.index(after: open) ..< close])
            let first = values.first
            let second = values.count > 1 ? values[1] : nil
            let step: CGAffineTransform = switch name {
            case "translate": CGAffineTransform(translationX: first ?? 0, y: second ?? 0)
            case "scale": CGAffineTransform(scaleX: first ?? 1, y: second ?? first ?? 1)
            default: .identity
            }
            result = step.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    private static func numbers(in text: Substring) -> [CGFloat] {
        var out: [CGFloat] = []
        let parsed: Bool = text.utf8.withContiguousStorageIfAvailable { buffer in
            var scanner = SVGNumberScanner(buffer)
            while let value = scanner.nextNumber() { out.append(value) }
            return true
        } ?? false
        if !parsed {
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                var scanner = SVGNumberScanner(buffer)
                while let value = scanner.nextNumber() { out.append(value) }
            }
        }
        return out
    }
}

private struct PathBuilder {
    let path = CGMutablePath()
    private let transform: CGAffineTransform
    private var current = CGPoint.zero
    private var subpathStart = CGPoint.zero
    private var isOpen = false

    init(transform: CGAffineTransform) {
        self.transform = transform
    }

    mutating func append(_ data: Substring) throws {
        let handled = try data.utf8.withContiguousStorageIfAvailable { buffer -> Bool in
            try appendBuffer(buffer)
            return true
        } ?? false
        if !handled {
            let bytes = Array(data.utf8)
            try bytes.withUnsafeBufferPointer { buffer in
                try appendBuffer(buffer)
            }
        }
    }

    private mutating func appendBuffer(_ buffer: UnsafeBufferPointer<UInt8>) throws {
        var scanner = SVGNumberScanner(buffer)
        var command: UInt8 = 0
        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek() else { return }
            if SVGNumberScanner.isCommand(next) {
                command = next
                scanner.advance()
                if command == UInt8(ascii: "z") || command == UInt8(ascii: "Z") {
                    close()
                    continue
                }
            } else if command == 0 {
                throw DanmakuMaskFormatError.svg("data before a command")
            }
            command = try apply(command, reading: &scanner)
        }
    }

    private mutating func apply(_ command: UInt8, reading scanner: inout SVGNumberScanner) throws -> UInt8 {
        let relative = command >= UInt8(ascii: "a")
        switch command | 0x20 {
        case UInt8(ascii: "m"):
            let x = try Self.next(&scanner)
            let y = try Self.next(&scanner)
            current = target(x, y, relative: relative)
            path.move(to: current.applying(transform))
            subpathStart = current
            isOpen = true
            return relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
        case UInt8(ascii: "l"):
            let x = try Self.next(&scanner)
            let y = try Self.next(&scanner)
            lineTo(target(x, y, relative: relative))
        case UInt8(ascii: "h"):
            let value = try Self.next(&scanner)
            lineTo(CGPoint(x: relative ? current.x + value : value, y: current.y))
        case UInt8(ascii: "v"):
            let value = try Self.next(&scanner)
            lineTo(CGPoint(x: current.x, y: relative ? current.y + value : value))
        case UInt8(ascii: "c"):
            let x1 = try Self.next(&scanner)
            let y1 = try Self.next(&scanner)
            let x2 = try Self.next(&scanner)
            let y2 = try Self.next(&scanner)
            let x3 = try Self.next(&scanner)
            let y3 = try Self.next(&scanner)
            let control1 = target(x1, y1, relative: relative)
            let control2 = target(x2, y2, relative: relative)
            let end = target(x3, y3, relative: relative)
            path.addCurve(
                to: end.applying(transform),
                control1: control1.applying(transform),
                control2: control2.applying(transform)
            )
            current = end
        default:
            throw DanmakuMaskFormatError.svg("command \(UnicodeScalar(command))")
        }
        return command
    }

    private func target(_ first: CGFloat, _ second: CGFloat, relative: Bool) -> CGPoint {
        relative ? CGPoint(x: current.x + first, y: current.y + second) : CGPoint(x: first, y: second)
    }

    private mutating func lineTo(_ point: CGPoint) {
        path.addLine(to: point.applying(transform))
        current = point
    }

    private mutating func close() {
        if isOpen { path.closeSubpath() }
        isOpen = false
        current = subpathStart
    }

    private static func next(_ scanner: inout SVGNumberScanner) throws -> CGFloat {
        guard let value = scanner.nextNumber() else { throw DanmakuMaskFormatError.svg("argument") }
        return value
    }
}

private struct SVGNumberScanner {
    private static let pow10Divisors: (
        Double, Double, Double, Double, Double, Double, Double, Double,
        Double, Double, Double, Double, Double, Double, Double, Double
    ) = (
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7,
        1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15
    )

    private let bytes: UnsafeBufferPointer<UInt8>
    private var cursor = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    static func isCommand(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "e"), UInt8(ascii: "E"): false
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"): true
        default: false
        }
    }

    func peek() -> UInt8? { cursor < bytes.count ? bytes[cursor] : nil }

    mutating func advance() { cursor += 1 }

    mutating func skipSeparators() {
        while cursor < bytes.count, Self.isSeparator(bytes[cursor]) { cursor += 1 }
    }

    mutating func nextNumber() -> CGFloat? {
        skipSeparators()
        let start = cursor
        let count = bytes.count
        var end = cursor
        var negative = false
        if end < count {
            let b = bytes[end]
            if b == UInt8(ascii: "-") {
                negative = true
                end += 1
            } else if b == UInt8(ascii: "+") {
                end += 1
            }
        }
        var mantissa: UInt64 = 0
        var digits = 0
        var fracDigits = 0
        var sawDigit = false
        var sawPoint = false
        var overflow = false
        while end < count {
            let b = bytes[end]
            if b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") {
                sawDigit = true
                let digit = UInt64(b - UInt8(ascii: "0"))
                if digits < 15 {
                    mantissa = mantissa * 10 + digit
                    digits += 1
                    if sawPoint { fracDigits += 1 }
                } else {
                    overflow = true
                }
            } else if b == UInt8(ascii: "."), !sawPoint {
                sawPoint = true
            } else {
                break
            }
            end += 1
        }
        guard sawDigit else { return nil }
        let afterExponent = exponentEnd(from: end)
        let hasExponent = afterExponent != end
        cursor = afterExponent
        if !overflow, !hasExponent {
            var value = Double(mantissa)
            if fracDigits > 0 {
                value /= Self.divisor(for: fracDigits)
            }
            return CGFloat(negative ? -value : value)
        }
        guard let text = String(bytes: bytes[start ..< afterExponent], encoding: .ascii),
              let value = Double(text) else {
            return nil
        }
        return CGFloat(value)
    }

    private static func divisor(for power: Int) -> Double {
        switch power {
        case 0: pow10Divisors.0
        case 1: pow10Divisors.1
        case 2: pow10Divisors.2
        case 3: pow10Divisors.3
        case 4: pow10Divisors.4
        case 5: pow10Divisors.5
        case 6: pow10Divisors.6
        case 7: pow10Divisors.7
        case 8: pow10Divisors.8
        case 9: pow10Divisors.9
        case 10: pow10Divisors.10
        case 11: pow10Divisors.11
        case 12: pow10Divisors.12
        case 13: pow10Divisors.13
        case 14: pow10Divisors.14
        default: pow10Divisors.15
        }
    }

    private func exponentEnd(from end: Int) -> Int {
        guard end < bytes.count, bytes[end] == UInt8(ascii: "e") || bytes[end] == UInt8(ascii: "E") else {
            return end
        }
        var probe = end + 1
        if probe < bytes.count, Self.isSign(bytes[probe]) { probe += 1 }
        let digits = probe
        while probe < bytes.count, Self.isDigit(bytes[probe]) { probe += 1 }
        return probe > digits ? probe : end
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
    private static func isSign(_ byte: UInt8) -> Bool { byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") }
    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
    }
}
