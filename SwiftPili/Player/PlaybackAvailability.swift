import Foundation

/// Why a video cannot be played, when the answer is "it never will be".
///
/// The distinction this type exists to draw is **permanent vs transient**. A
/// deleted, private, region-locked or unpublished video is not a failed load
/// that might succeed on a second attempt — it is a final answer from the
/// server, and treating it as retryable is what produced the reported loop: a
/// raw `apiError(code: -404, message: "啥都木有")` painted into the player's
/// error overlay next to a Retry button that refetches the same permanent
/// refusal, forever, while the detail screen showed nothing at all.
enum PlaybackUnavailability: String, Equatable, Sendable, CaseIterable {
    /// The video no longer exists.
    case deleted
    /// Visible only to its uploader, or otherwise not public.
    case privateVideo
    /// Accepted but not yet published.
    case underReview
    /// Blocked in the caller's region.
    case regionLocked
    /// Requires a purchase or a subscription this account does not have.
    case paidContent
    /// Requires a signed-in account.
    case loginRequired
    /// Signed in, but this account may not watch it — age-gated, member-only,
    /// or otherwise restricted. Distinct from `loginRequired` because telling a
    /// signed-in user to sign in explains nothing.
    case accessDenied
    /// The request succeeded but produced no stream this client can open.
    /// A settled answer: the server offered nothing openable.
    case noPlayableStream
    /// Streams WERE offered, but none of the candidate hosts answered a probe
    /// right now. **Transient**, and the only retryable case in this type.
    ///
    /// It exists because `noPlayableStream` was doing both jobs. A probe that
    /// times out during a load is not a server verdict, and branding it one
    /// produced a dead end with no Retry and a `retryPlayback` that refused —
    /// recoverable only by leaving the screen.
    case streamUnreachable

    /// Whether an explicit user Retry could plausibly change the outcome.
    ///
    /// Exhaustive rather than a default, because the Retry affordance keys off
    /// it and a new case must be forced to choose. Everything except
    /// `streamUnreachable` is a settled server answer.
    var isRetryable: Bool {
        switch self {
        case .streamUnreachable: true
        case .deleted, .privateVideo, .underReview, .regionLocked,
             .paidContent, .loginRequired, .accessDenied, .noPlayableStream: false
        }
    }

    /// Whether signing in is the action that would resolve this.
    var suggestsSignIn: Bool {
        switch self {
        case .loginRequired: true
        case .deleted, .privateVideo, .underReview, .regionLocked,
             .paidContent, .noPlayableStream, .streamUnreachable, .accessDenied: false
        }
    }

    /// User-facing explanation. Deliberately concrete: "this video was
    /// deleted" is actionable information, `apiError(code: -404, …)` is not.
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

    /// SF Symbol for the unavailable state.
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

/// Maps a server refusal onto a permanent unavailability, or to nil when the
/// failure could plausibly be transient.
///
/// **Fails open to retryable on purpose.** Only codes whose meaning is settled
/// are classified; anything unrecognized keeps the existing retryable
/// behaviour. Silently turning an unknown transient failure into a permanent
/// dead end is a far worse regression than leaving one more code retryable, so
/// this table grows only from observed responses.
enum PlaybackAvailabilityPolicy {
    /// BiliBili result codes that mean "not playable, and that is final".
    ///
    /// Codes are shared between `x/web-interface/view` and `x/player/playurl`;
    /// both surface the same refusals, so one table serves both.
    static func unavailability(apiCode: Int) -> PlaybackUnavailability? {
        switch apiCode {
        // -404 啥都木有 — the video is gone.
        case -404: .deleted
        // 62002 稿件不可见 / 62012 仅UP主自己可见 — withdrawn or owner-only.
        case 62002, 62012: .privateVideo
        // 62004 稿件审核中 — accepted, not yet published.
        case 62004: .underReview
        // -10403 该视频在您所在地区不可观看
        case -10403: .regionLocked
        // 87007 / 87008 付费内容 — a season or episode this account has not
        // bought.
        case 87007, 87008: .paidContent
        // -101 账号未登录 — no session at all.
        case -101: .loginRequired
        // -403 访问权限不足 — there IS a session, it just may not watch this
        // (age-gated, member-only). Reported separately: "sign in" is not the
        // action, and telling a signed-in user to sign in explains nothing.
        case -403: .accessDenied
        default: nil
        }
    }

    /// Classifies a network-layer error. Only `apiError` and `authRequired`
    /// carry a settled verdict; transport failures never do.
    static func unavailability(for error: BiliError) -> PlaybackUnavailability? {
        switch error {
        case .apiError(let code, _):
            unavailability(apiCode: code)
        case .authRequired:
            .loginRequired
        case .network, .httpError, .decodingFailed:
            // A timeout, a 5xx or a malformed body says nothing about whether
            // the video exists. These stay retryable.
            nil
        }
    }

    /// Classifies any error, so call sites with an untyped `Error` (the
    /// detail-screen loader) get the same verdict as typed ones.
    static func unavailability(forAny error: any Error) -> PlaybackUnavailability? {
        guard let bili = error as? BiliError else { return nil }
        return unavailability(for: bili)
    }
}
