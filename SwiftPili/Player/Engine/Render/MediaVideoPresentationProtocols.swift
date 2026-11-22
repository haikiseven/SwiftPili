import UIKit

/// Native presentation surface required by the App's renderer host.
@MainActor
protocol MediaVideoPresentation: MediaVideoRendering {
    var hostViewController: UIViewController { get }
    /// Apply a temporary presentation-only corner mask to the renderer's
    /// source surface. The Demand PiP source may be composited by AVKit during
    /// restore, so the mask must reach the source layer itself as well as any
    /// app-owned container. Legacy/fake renderers may ignore this seam.
    func setPresentationCornerRadius(_ radius: CGFloat)
}

extension MediaVideoPresentation {
    func setPresentationCornerRadius(_ radius: CGFloat) {
        _ = radius
    }
}

/// Optional event-backed PiP surface exposed by a video renderer.
///
/// `isPiPActive` is a diagnostic/native state only. Owner/lifecycle code must
/// use the handler, which is driven by did-start/did-stop/failed-to-start
/// callbacks rather than by polling the native controller bit.
@MainActor
protocol MediaPiPLeaseEventSource: AnyObject {
    var isPiPActive: Bool { get }
    @discardableResult
    func startPiP() -> Bool
    func stopPiP()
    /// Cancel a native start that has not produced a terminal callback. The
    /// implementation must invalidate the old controller identity before
    /// returning so a late didStart cannot claim a new owner.
    func abandonPendingPiPStart()
    func setPiPLeaseChangeHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    )
    /// Native PiP edges retain their request/completion distinction. The
    /// session stamps these with its independent binding generation before
    /// forwarding them to lifecycle orchestration.
    func setPiPNativeTransitionHandler(
        _ handler: (@MainActor @Sendable (DemandPiPNativeEvent) -> Void)?
    )
    /// AVKit asks the app to restore inline UI while native PiP stop is still
    /// in flight. The renderer owns the raw completion closure and exposes only
    /// an opaque token across the engine boundary.
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
