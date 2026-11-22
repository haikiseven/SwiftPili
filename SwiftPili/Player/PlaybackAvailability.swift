import Foundation

enum PlaybackUnavailability: String, Equatable, Sendable, CaseIterable {
    case deleted
    case privateVideo
    case underReview
    case regionLocked
    case paidContent
    case loginRequired
    case accessDenied
    case noPlayableStream
    case streamUnreachable

    var isRetryable: Bool {
        switch self {
        case .streamUnreachable: true
        case .deleted, .privateVideo, .underReview, .regionLocked,
             .paidContent, .loginRequired, .accessDenied, .noPlayableStream: false
        }
    }

    var suggestsSignIn: Bool {
        switch self {
        case .loginRequired: true
        case .deleted, .privateVideo, .underReview, .regionLocked,
             .paidContent, .noPlayableStream, .streamUnreachable, .accessDenied: false
        }
    }

    var message: String {
        switch self {
        case .deleted:
            String(localized: "This video is no longer available.")
        case .privateVideo:
            String(localized: "This video is private.")
        case .underReview:
            String(localized: "This video is being reviewed and cannot be played yet.")
        case .regionLocked:
            String(localized: "This video is not available in your region.")
        case .paidContent:
            String(localized: "This video requires a purchase or subscription.")
        case .loginRequired:
            String(localized: "Sign in to watch this video.")
        case .accessDenied:
            String(localized: "This account cannot watch this video.")
        case .noPlayableStream:
            String(localized: "No playable stream is available for this video.")
        case .streamUnreachable:
            String(localized: "Could not reach the video server. Check your connection and try again.")
        }
    }

    var symbolName: String {
        switch self {
        case .deleted: "trash.slash"
        case .privateVideo: "lock"
        case .underReview: "clock.badge.questionmark"
        case .regionLocked: "globe.badge.chevron.backward"
        case .paidContent: "creditcard"
        case .loginRequired: "person.crop.circle.badge.exclamationmark"
        case .accessDenied: "hand.raised"
        case .noPlayableStream: "film.stack"
        case .streamUnreachable: "wifi.exclamationmark"
        }
    }
}

enum PlaybackAvailabilityPolicy {
    static func unavailability(apiCode: Int) -> PlaybackUnavailability? {
        switch apiCode {
        case -404: .deleted
        case 62002, 62012: .privateVideo
        case 62004: .underReview
        case -10403: .regionLocked
        case 87007, 87008: .paidContent
        case -101: .loginRequired
        case -403: .accessDenied
        default: nil
        }
    }

    static func unavailability(for error: BiliError) -> PlaybackUnavailability? {
        switch error {
        case .apiError(let code, _):
            unavailability(apiCode: code)
        case .authRequired:
            .loginRequired
        case .network, .httpError, .decodingFailed:
            nil
        }
    }

    static func unavailability(forAny error: any Error) -> PlaybackUnavailability? {
        guard let bili = error as? BiliError else { return nil }
        return unavailability(for: bili)
    }
}
