import Foundation
import os

enum FormatUtils {
    private static let paddedTwoDigits: [String] = (0 ..< 60).map { $0 < 10 ? "0\($0)" : "\($0)" }

    @inline(__always)
    private static func twoDigit(_ value: Int) -> String {
        if value >= 0, value < 60 { return paddedTwoDigits[value] }
        return value < 10 && value >= 0 ? "0\(value)" : "\(value)"
    }

    static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return "\(hours):\(twoDigit(minutes)):\(twoDigit(secs))"
        }
        return "\(minutes):\(twoDigit(secs))"
    }

    static func parseDurationSeconds(_ value: String?) -> Int {
        guard let value else { return 0 }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var total = 0
        var part = 0
        var hasDigits = false
        for byte in trimmed.utf8 {
            if byte == 0x3A { // ':'
                guard hasDigits else { return 0 }
                total = total * 60 + part
                part = 0
                hasDigits = false
            } else if byte >= 0x30, byte <= 0x39 {
                let digit = Int(byte - 0x30)
                let (mul, overflow1) = part.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = mul.addingReportingOverflow(digit)
                guard !overflow1, !overflow2 else { return 0 }
                part = sum
                hasDigits = true
            } else {
                return 0
            }
        }
        guard hasDigits else { return 0 }
        return total * 60 + part
    }

    private static let isChineseUI: Bool =
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? false

    @inline(__always)
    private static func oneDecimal(_ value: Double, suffix: String) -> String {
        let tenths = Int((value * 10).rounded(.toNearestOrEven))
        return "\(tenths / 10).\(tenths % 10)\(suffix)"
    }

    static func viewCount(_ count: Int) -> String {
        if isChineseUI {
            if count >= 100_000_000 {
                return oneDecimal(Double(count) / 100_000_000, suffix: "亿")
            }
            if count >= 10_000 {
                let wan = Double(count) / 10_000
                if wan >= 9999.95 {
                    return oneDecimal(Double(count) / 100_000_000, suffix: "亿")
                }
                return oneDecimal(wan, suffix: "万")
            }
        } else {
            if count >= 1_000_000_000 {
                return oneDecimal(Double(count) / 1_000_000_000, suffix: "B")
            }
            if count >= 1_000_000 {
                let millions = Double(count) / 1_000_000
                if millions >= 999.95 {
                    return oneDecimal(Double(count) / 1_000_000_000, suffix: "B")
                }
                return oneDecimal(millions, suffix: "M")
            }
            if count >= 10_000 {
                let thousands = Double(count) / 1_000
                if thousands >= 999.95 {
                    return oneDecimal(Double(count) / 1_000_000, suffix: "M")
                }
                return oneDecimal(thousands, suffix: "K")
            }
        }
        return "\(count)"
    }

    static func historyProgressFraction(progress: Int, duration: Int) -> Double {
        guard duration > 0 else { return 0 }
        if progress < 0 { return 1 }
        return min(1, max(0, Double(progress) / Double(duration)))
    }

    private struct TimeAgoState {
        let relativeFormatter: RelativeDateTimeFormatter
        let dayFormatter: DateFormatter
        var localeID: String
        var justNowText: String
        var relativeCache: [Int: String] = [:]
        var timeZoneID: String
        var dayCache: [Int: String] = [:]
    }

    private static let timeAgoState = OSAllocatedUnfairLock(uncheckedState: {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        relative.locale = .autoupdatingCurrent
        relative.calendar = .autoupdatingCurrent

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"

        return TimeAgoState(
            relativeFormatter: relative,
            dayFormatter: day,
            localeID: Locale.autoupdatingCurrent.identifier,
            justNowText: String(localized: "just now"),
            timeZoneID: TimeZone.autoupdatingCurrent.identifier
        )
    }())

    static func timeAgo(from timestamp: Int) -> String {
        let nowTimestamp = Date().timeIntervalSince1970
        let interval = nowTimestamp - TimeInterval(timestamp)

        if interval < 60 {
            let currentLocaleID = Locale.autoupdatingCurrent.identifier
            return timeAgoState.withLockUnchecked { state in
                if state.localeID != currentLocaleID {
                    state.localeID = currentLocaleID
                    state.justNowText = String(localized: "just now")
                    state.relativeCache.removeAll(keepingCapacity: true)
                }
                return state.justNowText
            }
        }

        if interval < 2_592_000 {
            let key: Int
            let bucketInterval: TimeInterval
            if interval < 3_600 {
                let minutes = Int(interval) / 60
                key = minutes
                bucketInterval = -TimeInterval(minutes * 60)
            } else if interval < 86_400 {
                let hours = Int(interval) / 3_600
                key = 100 + hours
                bucketInterval = -TimeInterval(hours * 3_600)
            } else {
                let days = Int(interval) / 86_400
                key = 200 + days
                bucketInterval = -TimeInterval(days * 86_400)
            }
            let currentLocaleID = Locale.autoupdatingCurrent.identifier
            return timeAgoState.withLockUnchecked { state in
                if state.localeID != currentLocaleID {
                    state.localeID = currentLocaleID
                    state.justNowText = String(localized: "just now")
                    state.relativeCache.removeAll(keepingCapacity: true)
                }
                if let cached = state.relativeCache[key] {
                    return cached
                }
                let formatted = state.relativeFormatter.localizedString(fromTimeInterval: bucketInterval)
                state.relativeCache[key] = formatted
                return formatted
            }
        }

        let currentTZID = TimeZone.autoupdatingCurrent.identifier
        return timeAgoState.withLockUnchecked { state in
            if state.timeZoneID != currentTZID {
                state.timeZoneID = currentTZID
                state.dayFormatter.timeZone = .autoupdatingCurrent
                state.dayCache.removeAll(keepingCapacity: true)
            }
            if let cached = state.dayCache[timestamp] {
                return cached
            }
            let formatted = state.dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
            if state.dayCache.count >= 512 {
                state.dayCache.removeAll(keepingCapacity: true)
            }
            state.dayCache[timestamp] = formatted
            return formatted
        }
    }
}

extension String {
    var jsonEscaped: String {
        let utf8View = self.utf8
        let needsEscape = utf8View.contains {
            $0 == 0x5C || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09
        }
        guard needsEscape else { return self }

        var output: [UInt8] = []
        output.reserveCapacity(utf8View.count + 8)
        for byte in utf8View {
            switch byte {
            case 0x5C: output.append(contentsOf: [0x5C, 0x5C]) // \\
            case 0x22: output.append(contentsOf: [0x5C, 0x22]) // \"
            case 0x0A: output.append(contentsOf: [0x5C, 0x6E]) // \n
            case 0x0D: output.append(contentsOf: [0x5C, 0x72]) // \r
            case 0x09: output.append(contentsOf: [0x5C, 0x74]) // \t
            default: output.append(byte)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
