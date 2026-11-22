import UIKit

/// The shared vocabulary of a presentation-diagnostics row: the layer census,
/// and the closed labels for the three UIKit enums such a row prints.
///
/// Its own type, in its own file, because the census convention is the one fact
/// a reader has to trust before trusting any number in a capture — and because
/// it OUTLIVED the probes it was extracted for. Three presented controllers
/// formatted rows from it once: the Stage 0 probe, its `.fullScreen`
/// measurement host, and the real `PlayerFullscreenHostController` promoted out
/// of that shell. The first two were deleted when their questions closed; this
/// is what produces the `winLayers=` the fullscreen contract grades on, so it
/// stayed. The file was named after the probe and has been renamed after what
/// it actually is.
enum PlayerPresentationCensus {
    /// `(count, depth)` of the layer tree rooted at `layer`, with `layer`
    /// itself counted as depth 1 — the convention the 313–344 layers / depth
    /// 34–35 census in `research/nine-falsified-hypotheses-2026-09-05.md` used,
    /// so the numbers here are comparable to the ones that motivated the task.
    static func census(of layer: CALayer) -> (count: Int, depth: Int) {
        var count = 0
        var deepest = 0
        var stack: [(layer: CALayer, depth: Int)] = [(layer, 1)]
        while let node = stack.popLast() {
            count += 1
            deepest = max(deepest, node.depth)
            // A diagnostic must not be able to become the outage it measures.
            guard count < 20_000 else { break }
            for sublayer in node.layer.sublayers ?? [] {
                stack.append((sublayer, node.depth + 1))
            }
        }
        return (count, deepest)
    }

    /// Bare class name — the parked subtree's owner (`UITransitionView`,
    /// `UIDropShadowView`, a SwiftUI hosting view) is the second half of the
    /// answer when `offWindow=y`.
    static func name(of object: AnyObject) -> String {
        String(describing: type(of: object))
    }

    /// Same closed-label rule as `PlayerViewModel.orientationMaskLabel`: no
    /// UIKit type ever reaches a log line or the diagnostics sink.
    static func maskLabel(_ mask: UIInterfaceOrientationMask) -> String {
        switch mask {
        case .landscape: "landscape"
        case .portrait: "portrait"
        case .all: "all"
        case .allButUpsideDown: "allButUpsideDown"
        default: "other"
        }
    }

    static func orientationLabel(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    /// The mask that describes exactly one settled interface orientation, so a
    /// caller can ask "is the scene already where the mask wants it" without
    /// re-deriving UIKit's raw-value relationship at the call site.
    /// `UIInterfaceOrientationMask.landscapeLeft` is `1 << UIInterfaceOrientation
    /// .landscapeLeft.rawValue`, but spelling the pairs out is the version a
    /// reader can check.
    static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .unknown: []
        @unknown default: []
        }
    }
}
