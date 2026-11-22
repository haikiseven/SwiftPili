import CoreGraphics
import Foundation

/// The SVG inside each webmask frame, decoded to a `CGPath`.
///
/// Only the potrace subset webmask uses: one viewBox, one `<g transform=
/// "translate(tx,ty) scale(sx,sy)">`, and `<path d>` elements whose commands
/// are `M m l c z` (42,803 real frames used nothing else; `L H h V v C` are
/// accepted too, since they cost nothing). The result is the union path in
/// canvas pixels, y down — potrace's `translate(0,H) scale(0.1,-0.1)` already
/// performs the flip. Pure; runs off the main actor.
enum DanmakuMaskSVG {
    /// `data:image/svg+xml;base64,<base64 with line breaks>` → SVG text.
    static func text(fromDataURL payload: Data) throws -> String {
        guard let comma = payload.firstIndex(of: UInt8(ascii: ",")) else {
            throw DanmakuMaskFormatError.svg("no data URL comma")
        }
        let encoded = payload[payload.index(after: comma)...]
        guard let decoded = Data(base64Encoded: Data(encoded), options: .ignoreUnknownCharacters),
              let text = String(data: decoded, encoding: .utf8) else {
            throw DanmakuMaskFormatError.svg("base64")
        }
        return text
    }

    static func path(_ svg: String) throws -> (canvas: CGSize, path: CGPath) {
        guard let viewBox = attribute("viewBox", in: svg) else { throw DanmakuMaskFormatError.svg("viewBox") }
        let box = numbers(in: viewBox)
        guard box.count == 4, box[2] > 0, box[3] > 0 else { throw DanmakuMaskFormatError.svg("viewBox values") }
        var builder = PathBuilder(transform: attribute("transform", in: svg).map(parseTransform) ?? .identity)
        var searchStart = svg.startIndex
        var found = false
        while let range = svg.range(of: "<path", range: searchStart ..< svg.endIndex) {
            let tagEnd = svg.range(of: ">", range: range.upperBound ..< svg.endIndex)?.lowerBound ?? svg.endIndex
            if let data = attribute("d", in: String(svg[range.lowerBound ..< tagEnd])) {
                try builder.append(data)
                found = true
            }
            searchStart = tagEnd
        }
        guard found else { throw DanmakuMaskFormatError.svg("no path") }
        return (CGSize(width: box[2], height: box[3]), builder.path)
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: " \(name)=\"") ?? text.range(of: "\n\(name)=\"") else { return nil }
        guard let end = text.range(of: "\"", range: start.upperBound ..< text.endIndex) else { return nil }
        return String(text[start.upperBound ..< end.lowerBound])
    }

    /// `translate(a,b) scale(c,d)` in document order. SVG composes left to
    /// right, so the rightmost function applies to the point first.
    private static func parseTransform(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let values = numbers(in: String(rest[rest.index(after: open) ..< close]))
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

    private static func numbers(in text: String) -> [CGFloat] {
        var scanner = SVGNumberScanner(Array(text.utf8))
        var out: [CGFloat] = []
        while let value = scanner.nextNumber() { out.append(value) }
        return out
    }
}

/// Accumulates `d` attributes into one path. Coordinates are tracked in the
/// SVG's own space (relative commands need that) and transformed on output.
private struct PathBuilder {
    let path = CGMutablePath()
    private let transform: CGAffineTransform
    private var current = CGPoint.zero
    private var subpathStart = CGPoint.zero
    private var isOpen = false

    init(transform: CGAffineTransform) {
        self.transform = transform
    }

    mutating func append(_ data: String) throws {
        var scanner = SVGNumberScanner(Array(data.utf8))
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

    /// Consumes one command's arguments. Returns the command that implicit
    /// repeats continue with — a moveto's extra pairs are linetos.
    private mutating func apply(_ command: UInt8, reading scanner: inout SVGNumberScanner) throws -> UInt8 {
        let relative = command >= UInt8(ascii: "a")
        switch command | 0x20 { // lowercase
        case UInt8(ascii: "m"):
            let values = try Self.read(2, from: &scanner)
            current = target(values[0], values[1], relative: relative)
            path.move(to: current.applying(transform))
            subpathStart = current
            isOpen = true
            return relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
        case UInt8(ascii: "l"):
            let values = try Self.read(2, from: &scanner)
            lineTo(target(values[0], values[1], relative: relative))
        case UInt8(ascii: "h"):
            let value = try Self.read(1, from: &scanner)[0]
            lineTo(CGPoint(x: relative ? current.x + value : value, y: current.y))
        case UInt8(ascii: "v"):
            let value = try Self.read(1, from: &scanner)[0]
            lineTo(CGPoint(x: current.x, y: relative ? current.y + value : value))
        case UInt8(ascii: "c"):
            let values = try Self.read(6, from: &scanner)
            let control1 = target(values[0], values[1], relative: relative)
            let control2 = target(values[2], values[3], relative: relative)
            let end = target(values[4], values[5], relative: relative)
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

    private static func read(_ count: Int, from scanner: inout SVGNumberScanner) throws -> [CGFloat] {
        var values: [CGFloat] = []
        for _ in 0 ..< count {
            guard let value = scanner.nextNumber() else { throw DanmakuMaskFormatError.svg("argument") }
            values.append(value)
        }
        return values
    }
}

/// SVG number tokenizer: optional sign, digits, one decimal point, optional
/// exponent; separators are whitespace and commas, and a sign or a second
/// decimal point also starts a new number (`-1-2`, `.5.5`).
private struct SVGNumberScanner {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

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
        while let byte = peek(), Self.isSeparator(byte) { cursor += 1 }
    }

    mutating func nextNumber() -> CGFloat? {
        skipSeparators()
        let start = cursor
        var end = cursor
        if end < bytes.count, Self.isSign(bytes[end]) { end += 1 }
        var sawDigit = false
        var sawPoint = false
        while end < bytes.count {
            if Self.isDigit(bytes[end]) {
                sawDigit = true
            } else if bytes[end] == UInt8(ascii: "."), !sawPoint {
                sawPoint = true
            } else {
                break
            }
            end += 1
        }
        guard sawDigit else { return nil }
        end = exponentEnd(from: end)
        cursor = end
        guard let text = String(bytes: bytes[start ..< end], encoding: .ascii), let value = Double(text) else {
            return nil
        }
        return CGFloat(value)
    }

    /// Where an exponent after `end` stops, or `end` when there is none.
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
