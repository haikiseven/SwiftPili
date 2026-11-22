import Foundation

/// The fullscreen chrome's "log in to send danmaku", carried across the
/// fullscreen exit.
///
/// Login is a sheet from the root, and it cannot present while the fullscreen
/// host still covers the root (nor would its QR page fit a 393pt-tall
/// landscape phone). So the request is armed, fullscreen exits, and the
/// request becomes ready only when the host has actually gone — its own
/// dismissal completion — or at once when no host was presented. `RootView`
/// observes `isReady` and presents login.
///
/// Its own object rather than state on `PlayerViewModel`: `RootView` reads it
/// on its first frame, and reading the player singleton there would construct
/// the whole player (backends, audio session observers) at launch, ahead of
/// the off-main prewarm.
@MainActor
@Observable
final class FullscreenLoginHandoff {
    static let shared = FullscreenLoginHandoff()

    @ObservationIgnored private var awaitingExit = false
    private(set) var isReady = false

    /// A login was asked for from fullscreen; wait for the exit to finish.
    func arm() {
        awaitingExit = true
    }

    /// A new fullscreen supersedes a request still waiting on the last exit.
    func cancel() {
        awaitingExit = false
    }

    /// Nothing covers the root any more. A no-op when nothing was armed.
    func release() {
        guard awaitingExit else { return }
        awaitingExit = false
        isReady = true
    }

    /// True once per ready request; the caller presents login.
    func consume() -> Bool {
        guard isReady else { return false }
        isReady = false
        return true
    }
}
