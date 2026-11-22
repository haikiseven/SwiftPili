import UIKit

enum PlayerPresentationCensus {
    static func census(of layer: CALayer) -> (count: Int, depth: Int) {
        var count = 0
        var deepest = 0
        var stack: [(layer: CALayer, depth: Int)] = [(layer, 1)]
        while let node = stack.popLast() {
            count += 1
            deepest = max(deepest, node.depth)
            guard count < 20_000 else { break }
            for sublayer in node.layer.sublayers ?? [] {
                stack.append((sublayer, node.depth + 1))
            }
        }
        return (count, deepest)
    }

    static func name(of object: AnyObject) -> String {
        String(describing: type(of: object))
    }

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
