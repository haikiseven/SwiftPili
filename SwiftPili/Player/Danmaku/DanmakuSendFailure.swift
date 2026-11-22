import Foundation

/// Toast copy for a failed danmaku POST. Never `localizedDescription`:
/// that string is the enum's own formatting (`API error N: …`), not a
/// sentence from either catalog.
enum DanmakuSendFailure {
    static func message(for error: BiliError) -> String {
        switch error {
        case .authRequired:
            return String(localized: "Sign in to send danmaku")
        case let .apiError(_, message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            // Risk-control and other API refusals often carry a sentence the
            // server already wrote for a person. An empty message, a bare
            // code, or a dump is not one of those.
            if text.contains(where: \.isLetter),
               !text.lowercased().hasPrefix("api error"),
               !text.lowercased().hasPrefix("bilierror") {
                return text
            }
            return String(localized: "Danmaku was rejected")
        case .network, .httpError, .decodingFailed:
            return String(localized: "Couldn't send danmaku")
        }
    }
}
