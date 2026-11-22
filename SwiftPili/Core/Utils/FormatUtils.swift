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

    /// The app's ACTIVE UI language (respects the per-app language chosen
    /// in iOS Settings, unlike Locale.preferredLanguages).
    private static let isChineseUI: Bool =
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? false

    static func viewCount(_ count: Int) -> String {
        if isChineseUI {
            if count >= 100_000_000 {
                return String(format: "%.1f亿", Double(count) / 100_000_000)
            }
            if count >= 10_000 {
                // %.1f can round 9999.95万 up to "10000.0万" — promote to 亿.
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
                // 999_999 → 999.999K rounds to "1000.0K"; promote to M.
                let thousands = Double(count) / 1_000
                if thousands >= 999.95 {
                    return String(format: "%.1fM", Double(count) / 1_000_000)
                }
                return String(format: "%.1fK", thousands)
            }
        }
        return "\(count)"
    }

    /// Watch-history progress fraction in `0...1`.
    ///
    /// Bilibili `x/web-interface/history/cursor` uses **`progress == -1`** as
    /// "watched to the end" — same sentinel as `last_play_time` in
    /// `PlayerViewModel.serverResumePoint`. A one-sided `min(1, p/d)` turns
    /// that into a negative bar width (empty bar = looks never watched).
    static func historyProgressFraction(progress: Int, duration: Int) -> Double {
        guard duration > 0 else { return 0 }
        if progress < 0 { return 1 }
        return min(1, max(0, Double(progress) / Double(duration)))
    }

    /// Built once, not per call: constructing a DateFormatter measured
    /// 24.9 µs vs 0.4 µs to reuse one (-O, Apple silicon), and timeAgo runs
    /// once per list row on every body evaluation — rows re-materialize
    /// every time a list scrolls them back into view. Same cached-formatter
    /// rule CommentContextActions.exactTimeFormatter already follows.
    /// NSDateFormatter is thread-safe for formatting (iOS 7+); only the
    /// formatter is shared, the result still depends on the date given.
    ///
    /// RelativeDateTimeFormatter is shared behind a lock because it is not
    /// Sendable. The reuse gain is small (2.5 µs constructed vs 1.7 µs reused
    /// when measured on its own) and it was kept per-call until the comment
    /// rows' main-thread profile was reviewed; it follows the same
    /// one-instance-per-process rule as the day formatter. Locale and calendar
    /// are autoupdating so a system change still reaches the next call, as a
    /// formatter built per call would.
    private static let relativeFormatter = OSAllocatedUnfairLock(uncheckedState: {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        return formatter
    }())

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed locale so `yyyy` is always the Gregorian year. Without this,
        // Locale.current + dateFormat uses the user's calendar era
        // (th_TH → Buddhist 2563, ja_JP@calendar=japanese → Reiwa 2).
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
            // System-localized "5 minutes ago" / "5分钟前".
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
