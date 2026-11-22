import Foundation

enum DanmakuSendFailure {
    static func message(for error: BiliError) -> String {
        switch error {
        case .authRequired:
            return String(localized: "Sign in to send danmaku")
        case let .apiError(_, message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
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
