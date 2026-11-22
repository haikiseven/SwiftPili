import UIKit

@MainActor
protocol MediaEnginePresentation: MediaEngining {
    var videoHost: UIViewController { get }
    var onPresentationFailure: (@MainActor @Sendable (DemandPresentationFailure, Int?) -> Void)? { get set }
}
