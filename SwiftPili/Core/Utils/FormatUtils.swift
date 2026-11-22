import Foundation
import os

enum FormatUtils {
    static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func parseDurationSeconds(_ value: String?) -> Int {
        guard let value else { return 0 }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let rawParts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        let parts = rawParts.compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == rawParts.count else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static let isChineseUI: Bool =
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? false

    static func viewCount(_ count: Int) -> String {
        if isChineseUI {
            if count >= 100_000_000 {
                return String(format: "%.1f亿", Double(count) / 100_000_000)
            }
            if count >= 10_000 {
                let wan = Double(count) / 10_000
                if wan >= 9999.95 {
                    return String(format: "%.1f亿", Double(count) / 100_000_000)
                }
                return String(format: "%.1f万", wan)
            }
        } else {
            if count >= 1_000_000_000 {
                return String(format: "%.1fB", Double(count) / 1_000_000_000)
            }
            if count >= 1_000_000 {
                let millions = Double(count) / 1_000_000
                if millions >= 999.95 {
                    return String(format: "%.1fB", Double(count) / 1_000_000_000)
                }
                return String(format: "%.1fM", millions)
            }
            if count >= 10_000 {
                let thousands = Double(count) / 1_000
                if thousands >= 999.95 {
                    return String(format: "%.1fM", Double(count) / 1_000_000)
                }
                return String(format: "%.1fK", thousands)
            }
        }
        return "\(count)"
    }

    static func historyProgressFraction(progress: Int, duration: Int) -> Double {
        guard duration > 0 else { return 0 }
        if progress < 0 { return 1 }
        return min(1, max(0, Double(progress) / Double(duration)))
    }

    private static let relativeFormatter = OSAllocatedUnfairLock(uncheckedState: {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        return formatter
    }())

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func timeAgo(from timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return String(localized: "just now")
        }
        if interval < 2_592_000 {
            return relativeFormatter.withLockUnchecked {
                $0.localizedString(for: date, relativeTo: now)
            }
        }

        return dayFormatter.string(from: date)
    }
}

extension String {
    var jsonEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
