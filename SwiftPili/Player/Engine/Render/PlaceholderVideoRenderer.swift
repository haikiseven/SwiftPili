import UIKit

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
