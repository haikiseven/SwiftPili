import UIKit

/// Empty host surface until ASBD layer is wired. Keeps backend render VC non-nil.
/// A2-α: `setDisplayPlayback` is a deliberate no-op (protocol default also no-ops).
@MainActor
final class PlaceholderVideoRenderer: MediaVideoPresentation {
    let hostViewController: UIViewController

    init() {
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        hostViewController = vc
    }

    func setScaleMode(_ mode: VideoScaleMode) {
        _ = mode
    }

    func present(_ frame: MediaVideoFrame) throws {
        _ = frame
        throw MediaEngineError.notImplemented("AVSampleBufferDisplayLayer present")
    }

    func setDisplayPlayback(rate: Float, mediaTime: TimeInterval) {
        _ = rate
        _ = mediaTime
    }

    func flush() {}
    func invalidate() {}
}