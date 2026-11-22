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

    func settle(
        fence: DemandPresentationFence,
        failure: DemandPresentationFailure,
        ui userInterface: any PresentationFailureUI,
        transport: any PresentationFailureTransport,
        projection: any PresentationFailureProjection
    ) {
        userInterface.beginPresentationFailure(fence: fence)
        suppressesPauseProjection = true
        transport.pauseForPresentationFailure()
        suppressesPauseProjection = false
        userInterface.finishPresentationFailure(
            message: "Video presentation recovery failed (\(failure.rawValue)). Tap Retry."
        )
        projection.publishPresentationFailure(fence: fence)
        PlayerLog.log(
            "[Lifecycle] presentation failure=\(failure.rawValue) — no source reopen"
        )
    }
}
