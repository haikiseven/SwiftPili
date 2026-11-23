import Foundation

@MainActor
protocol PresentationFailureUI: AnyObject {
    func beginPresentationFailure(fence: DemandPresentationFence)
    func finishPresentationFailure(message: String)
}

@MainActor
protocol PresentationFailureTransport: AnyObject {
    func pauseForPresentationFailure()
}

@MainActor
protocol PresentationFailureProjection: AnyObject {
    func publishPresentationFailure(fence: DemandPresentationFence)
}

@MainActor
final class PlaybackTerminalSettlement {
    private(set) var suppressesPauseProjection = false

    func suppressingPauseProjection(_ body: () -> Void) {
        let previous = suppressesPauseProjection
        suppressesPauseProjection = true
        defer { suppressesPauseProjection = previous }
        body()
    }

    func settle(
        fence: DemandPresentationFence,
        failure: DemandPresentationFailure,
        ui userInterface: any PresentationFailureUI,
        transport: any PresentationFailureTransport,
        projection: any PresentationFailureProjection
    ) {
        userInterface.beginPresentationFailure(fence: fence)
        suppressingPauseProjection {
            transport.pauseForPresentationFailure()
        }
        userInterface.finishPresentationFailure(
            message: "Video presentation recovery failed (\(failure.rawValue)). Tap Retry."
        )
        projection.publishPresentationFailure(fence: fence)
        PlayerLog.log(
            "[Lifecycle] presentation failure=\(failure.rawValue) — no source reopen"
        )
    }
}
