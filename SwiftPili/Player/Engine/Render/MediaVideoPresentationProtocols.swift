import UIKit

@MainActor
protocol MediaVideoPresentation: MediaVideoRendering {
    var hostViewController: UIViewController { get }
    func setPresentationCornerRadius(_ radius: CGFloat)
}

extension MediaVideoPresentation {
    func setPresentationCornerRadius(_ radius: CGFloat) {
        _ = radius
    }
}

@MainActor
protocol MediaPiPLeaseEventSource: AnyObject {
    var isPiPActive: Bool { get }
    @discardableResult
    func startPiP() -> Bool
    func stopPiP()
    func abandonPendingPiPStart()
    func setPiPLeaseChangeHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    )
    func setPiPNativeTransitionHandler(
        _ handler: (@MainActor @Sendable (DemandPiPNativeEvent) -> Void)?
    )
    func setPiPRestoreRequestHandler(
        _ handler: (@MainActor @Sendable (UInt64) -> Void)?
    )
    func completePiPRestore(token: UInt64, success: Bool)
}

extension MediaPiPLeaseEventSource {
    func abandonPendingPiPStart() {}
}

extension MediaPiPLeaseEventSource {
    func setPiPNativeTransitionHandler(
        _: (@MainActor @Sendable (DemandPiPNativeEvent) -> Void)?
    ) {}

    func setPiPRestoreRequestHandler(
        _: (@MainActor @Sendable (UInt64) -> Void)?
    ) {}

    func completePiPRestore(token _: UInt64, success _: Bool) {}
}
