import UIKit

/// Native App presentation requirements layered over media-session control.
@MainActor
protocol MediaEnginePresentation: MediaEngining {
    var videoHost: UIViewController { get }
    /// Emits a typed local-presentation failure from a continuation-owned
    /// refresh. This is distinct from a transport/runtime fault and cannot
    /// authorize a source reopen.
    var onPresentationFailure: (@MainActor @Sendable (DemandPresentationFailure, Int?) -> Void)? { get set }
}
