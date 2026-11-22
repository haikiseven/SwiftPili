import Foundation

@MainActor
@Observable
final class FullscreenLoginHandoff {
    static let shared = FullscreenLoginHandoff()

    @ObservationIgnored private var awaitingExit = false
    private(set) var isReady = false

    func arm() {
        awaitingExit = true
    }

    func cancel() {
        awaitingExit = false
    }

    func release() {
        guard awaitingExit else { return }
        awaitingExit = false
        isReady = true
    }

    func consume() -> Bool {
        guard isReady else { return false }
        isReady = false
        return true
    }
}
