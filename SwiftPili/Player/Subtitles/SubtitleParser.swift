import CoreFoundation
import Foundation

enum SubtitleFileFormat: String, Sendable, Equatable {
    case auto
    case srt
    case vtt
}

enum SubtitleParseError: LocalizedError, Sendable, Equatable {
    case unreadableEncoding
    case emptyOrUnsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unreadableEncoding:
            String(localized: "Unable to decode subtitle text encoding.")
        case .emptyOrUnsupportedFormat:
            String(localized: "No valid SRT or WebVTT subtitle cues were found.")
        }
    }
}

/// Fast O(log N + K) interval lookup index over sorted subtitle cues,
/// supporting touching and overlapping cues without falling back to O(N) scans.
struct SubtitleCueIndex: Sendable {
    let cues: [PlayerViewModel.SubtitleCue]
    private let prefixMaxEnd: [Double]

    init(cues: [PlayerViewModel.SubtitleCue]) {
        let sorted: [PlayerViewModel.SubtitleCue]
        var isSorted = true
        if cues.count > 1 {
            for idx in 1..<cues.count {
                if cues[idx].from < cues[idx - 1].from {
                    isSorted = false
                    break
                }
            }
        }
        sorted = isSorted ? cues : cues.sorted { lhs, rhs in
            if lhs.from != rhs.from { return lhs.from < rhs.from }
            return lhs.to < rhs.to
        }

        self.cues = sorted
        var maxEnds = [Double]()
        maxEnds.reserveCapacity(sorted.count)
        var runningMax = -Double.infinity
        for cue in sorted {
            if cue.to > runningMax {
                runningMax = cue.to
            }
            maxEnds.append(runningMax)
        }
        self.prefixMaxEnd = maxEnds
    }

    var isEmpty: Bool { cues.isEmpty }

    func activeText(at time: TimeInterval, toleranceAfterEnd: TimeInterval = 0) -> String? {
        guard time.isFinite, !cues.isEmpty else { return nil }

        // Binary search for the first cue whose `from` is strictly greater than `time`.
        var low = 0
        var high = cues.count
        while low < high {
            let mid = low + (high - low) / 2
            if cues[mid].from <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        guard low > 0 else { return nil }
        var matched: [String] = []
        var index = low - 1
        while index >= 0 {
            if prefixMaxEnd[index] + toleranceAfterEnd < time {
                break
            }
            let cue = cues[index]
            if time >= cue.from && time <= cue.to + toleranceAfterEnd {
                matched.append(cue.content)
            }
            index -= 1
        }

        guard !matched.isEmpty else { return nil }
        if matched.count == 1 {
            return matched[0]
        }
        matched.reverse()
        var unique: [String] = []
        unique.reserveCapacity(matched.count)
        for line in matched where !unique.contains(line) {
            unique.append(line)
        }
        return unique.joined(separator: "\n")
    }
}

/// Pure, thread-safe parser for SubRip (`.srt`) and WebVTT (`.vtt`) subtitle files.
enum SubtitleParser {
    private static let gb18030Encoding: String.Encoding = {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }()

    /// Decodes raw subtitle bytes, automatically detecting UTF-8, UTF-16 (LE/BE), and GB18030.
    static func decodeText(from data: Data) -> String? {
        guard !data.isEmpty else { return "" }

        // 1. Explicit BOM checks first.
        if data.count >= 3, data[data.startIndex] == 0xEF,
           data[data.startIndex + 1] == 0xBB,
           data[data.startIndex + 2] == 0xBF {
            let stripped = data.dropFirst(3)
            return String(data: stripped, encoding: .utf8)
        }
        if data.count >= 2 {
            let b0 = data[data.startIndex]
            let b1 = data[data.startIndex + 1]
            if b0 == 0xFF, b1 == 0xFE {
                return String(data: data, encoding: .utf16LittleEndian)?.strippingLeadingBOM()
            }
            if b0 == 0xFE, b1 == 0xFF {
                return String(data: data, encoding: .utf16BigEndian)?.strippingLeadingBOM()
            }
        }

        // 2. Detect BOM-less UTF-16 before UTF-8 so embedded NUL bytes aren't misread as UTF-8.
        if let utf16Encoding = detectBOMlessUTF16(in: data),
           let decoded = String(data: data, encoding: utf16Encoding) {
            return decoded.strippingLeadingBOM()
        }

        // 3. Strict UTF-8 (invalid multi-byte GB18030 sequences fail here cleanly).
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.strippingLeadingBOM()
        }

        // 4. GB18030 (covers GB2312 / GBK / GB18030 Chinese subtitle files).
        if let gb = String(data: data, encoding: gb18030Encoding) {
            return gb.strippingLeadingBOM()
        }

        // 5. General UTF-16 & Western fallback.
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16.strippingLeadingBOM()
        }
        if let latin = String(data: data, encoding: .windowsCP1252) {
            return latin.strippingLeadingBOM()
        }
        return nil
    }

    static func parse(
        data: Data,
        fileExtension: String? = nil
    ) throws -> [PlayerViewModel.SubtitleCue] {
        guard let text = decodeText(from: data) else {
            throw SubtitleParseError.unreadableEncoding
        }
        let format: SubtitleFileFormat
        switch fileExtension?.lowercased() {
        case "srt": format = .srt
        case "vtt", "webvtt": format = .vtt
        default: format = .auto
        }
        let cues = parse(text: text, format: format)
        guard !cues.isEmpty else {
            throw SubtitleParseError.emptyOrUnsupportedFormat
        }
        return cues
    }

    static func parse(
        text: String,
        format: SubtitleFileFormat = .auto
    ) -> [PlayerViewModel.SubtitleCue] {
        let normalized = text
            .strippingLeadingBOM()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.components(separatedBy: "\n")
        var blocks: [[String]] = []
        var currentBlock: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                    currentBlock.removeAll(keepingCapacity: true)
                }
            } else {
                currentBlock.append(line)
            }
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }

        let isVTTHeader = blocks.first?.first?
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
            .hasPrefix("WEBVTT") == true
        let effectiveFormat: SubtitleFileFormat = switch format {
        case .auto: isVTTHeader ? .vtt : .srt
        case .srt, .vtt: format
        }

        var cues: [PlayerViewModel.SubtitleCue] = []
        cues.reserveCapacity(blocks.count)

        for block in blocks {
            guard let firstLine = block.first?.trimmingCharacters(in: .whitespaces) else { continue }

            // Skip WebVTT preamble/metadata blocks (WEBVTT header, NOTE comments, STYLE, REGION).
            if effectiveFormat == .vtt || isVTTHeader {
                let upper = firstLine.uppercased()
                if upper.hasPrefix("WEBVTT") || upper.hasPrefix("NOTE")
                    || upper == "STYLE" || upper == "REGION" {
                    continue
                }
            }

            // Locate the timestamp arrow line (line 0 if no cue ID, or line 1 after index/ID).
            guard let timingLineIndex = block.firstIndex(where: { $0.contains("-->") }),
                  timingLineIndex <= 1 else {
                continue
            }

            guard let (from, to) = parseTimingLine(block[timingLineIndex]),
                  from >= 0, to > from else {
                continue
            }

            let textLines = block.dropFirst(timingLineIndex + 1)
            let cleanedLines = textLines.compactMap { rawLine -> String? in
                let stripped = stripStylingTags(rawLine)
                return stripped.isEmpty ? nil : stripped
            }
            guard !cleanedLines.isEmpty else { continue }

            cues.append(
                PlayerViewModel.SubtitleCue(
                    from: from,
                    to: to,
                    content: cleanedLines.joined(separator: "\n")
                )
            )
        }

        return cues.sorted { lhs, rhs in
            if lhs.from != rhs.from { return lhs.from < rhs.from }
            return lhs.to < rhs.to
        }
    }

    /// Parses a timing range line such as `00:01:02,500 --> 00:01:05,000` or
    /// `01:02.500 --> 01:05.000 align:start position:10%`.
    static func parseTimingLine(_ line: String) -> (from: TimeInterval, to: TimeInterval)? {
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let startPart = line[..<arrowRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let afterArrow = line[arrowRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)

        // Ignore trailing WebVTT cue settings after the end timestamp.
        let endToken = afterArrow
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""

        guard let start = parseTimestamp(startPart),
              let end = parseTimestamp(endToken) else {
            return nil
        }
        return (start, end)
    }

    /// Parses `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS.mmm`, or `MM:SS,mmm`.
    static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let hours: Int
        let minutesPart: Substring
        let secondsPart: Substring

        if parts.count == 3 {
            guard let h = Int(parts[0]), h >= 0 else { return nil }
            hours = h
            minutesPart = parts[1]
            secondsPart = parts[2]
        } else {
            hours = 0
            minutesPart = parts[0]
            secondsPart = parts[1]
        }

        guard let minutes = Int(minutesPart), minutes >= 0 else { return nil }
        if parts.count == 3, minutes >= 60 { return nil }

        let normalizedSeconds = secondsPart.replacingOccurrences(of: ",", with: ".")
        let secComponents = normalizedSeconds.split(separator: ".", omittingEmptySubsequences: false)
        guard secComponents.count == 1 || secComponents.count == 2,
              let wholeSeconds = Int(secComponents[0]),
              wholeSeconds >= 0, wholeSeconds < 60 else {
            return nil
        }

        let fractionalSeconds: Double
        if secComponents.count == 2 {
            let fracStr = String(secComponents[1])
            guard !fracStr.isEmpty, fracStr.allSatisfy(\.isNumber),
                  let fracVal = Double("0." + fracStr) else {
                return nil
            }
            fractionalSeconds = fracVal
        } else {
            fractionalSeconds = 0
        }

        let total = Double(hours) * 3600.0 + Double(minutes) * 60.0 + Double(wholeSeconds) + fractionalSeconds
        return total.isFinite ? total : nil
    }

    /// Strips basic HTML (`<i>`, `<b>`, `<font ...>`, `<c.color>`, `<v Speaker>`), WebVTT timestamp tags,
    /// and ASS/SSA override blocks (`{\an8}`, `{\pos(x,y)}`) while decoding common HTML entities.
    static func stripStylingTags(_ raw: String) -> String {
        var text = raw

        // 1. Strip ASS/SSA override blocks: {\...}
        text = stripASSOverrides(from: text)

        // 2. Strip HTML / WebVTT tags: </?[a-zA-Z]...>, <00:01.200>
        text = stripHTMLAndVTTTags(from: text)

        // 3. Unescape common HTML entities.
        if text.contains("&") {
            text = text
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&#39;", with: "'")
        }

        // Collapse accidental multiple spaces while preserving clean text.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func activeText(
        at time: TimeInterval,
        in cues: [PlayerViewModel.SubtitleCue],
        toleranceAfterEnd: TimeInterval = 0
    ) -> String? {
        SubtitleCueIndex(cues: cues).activeText(at: time, toleranceAfterEnd: toleranceAfterEnd)
    }

    private static func stripASSOverrides(from input: String) -> String {
        guard input.contains("{\\") else { return input }
        var result = ""
        result.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            let next = input.index(after: index)
            if input[index] == "{", next < input.endIndex, input[next] == "\\" {
                if let closing = input[next...].firstIndex(of: "}") {
                    index = input.index(after: closing)
                    continue
                }
            }
            result.append(input[index])
            index = next
        }
        return result
    }

    private static func stripHTMLAndVTTTags(from input: String) -> String {
        guard input.contains("<") else { return input }
        var result = ""
        result.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            if input[index] == "<" {
                let afterOpen = input.index(after: index)
                if afterOpen < input.endIndex {
                    let probe = input[afterOpen]
                    let isTagStart = probe == "/" || (probe.isASCII && (probe.isLetter || probe.isNumber))
                    if isTagStart, let closing = input[afterOpen...].firstIndex(of: ">") {
                        index = input.index(after: closing)
                        continue
                    }
                }
            }
            result.append(input[index])
            index = input.index(after: index)
        }
        return result
    }

    private static func detectBOMlessUTF16(in data: Data) -> String.Encoding? {
        guard data.count >= 4, data.count % 2 == 0 else { return nil }
        let sampleLimit = min(data.count, 512)
        var evenNulls = 0
        var oddNulls = 0
        var idx = 0
        while idx + 1 < sampleLimit {
            let b0 = data[data.startIndex + idx]
            let b1 = data[data.startIndex + idx + 1]
            if b0 == 0 && b1 != 0 { evenNulls += 1 }
            if b1 == 0 && b0 != 0 { oddNulls += 1 }
            idx += 2
        }
        let pairs = sampleLimit / 2
        guard pairs > 0 else { return nil }
        // If at least 15% of code units have a NUL high byte, treat as UTF-16.
        if oddNulls > evenNulls, Double(oddNulls) / Double(pairs) >= 0.15 {
            return .utf16LittleEndian
        }
        if evenNulls > oddNulls, Double(evenNulls) / Double(pairs) >= 0.15 {
            return .utf16BigEndian
        }
        return nil
    }
}

private extension String {
    func strippingLeadingBOM() -> String {
        guard first == "\u{FEFF}" else { return self }
        return String(dropFirst())
    }
}
