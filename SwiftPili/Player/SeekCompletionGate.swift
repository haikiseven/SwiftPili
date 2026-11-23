import Foundation

@MainActor
final class SeekCompletionGate {
    private var completion: (@MainActor @Sendable (Bool) -> Void)?
    private var nativePiPRequest: EnginePiPSeekRequest?
    var timeoutTask: Task<Void, Never>?

    var hasPendingWork: Bool {
        completion != nil || nativePiPRequest != nil
    }

    init(
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil,
        nativePiPRequest: EnginePiPSeekRequest? = nil
    ) {
        self.completion = completion
        self.nativePiPRequest = nativePiPRequest
    }

    func settle(_ ok: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let cb = completion
        let pip = nativePiPRequest
        completion = nil
        nativePiPRequest = nil
        cb?(ok)
        pip?.finish(success: ok)
    }

    isolated deinit {
        timeoutTask?.cancel()
        timeoutTask = nil
        completion?(false)
        nativePiPRequest?.finish(success: false)
    }
}
