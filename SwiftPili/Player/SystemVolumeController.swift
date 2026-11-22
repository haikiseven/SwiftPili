import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class SystemVolumeController {
    static let shared = SystemVolumeController()

    private let volumeView = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
    private var slider: UISlider?

    private init() {
        volumeView.alpha = 0.0001
        volumeView.isUserInteractionEnabled = false
    }

    var volume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    @discardableResult
    func setVolume(_ value: Float) -> Bool {
        ensureAttached()
        guard let slider else { return false }
        slider.value = min(max(value, 0), 1)
        return true
    }

    private func ensureAttached() {
        if volumeView.superview == nil, let window = Self.activeWindow {
            window.addSubview(volumeView)
            volumeView.layoutIfNeeded()
        }
        if slider == nil {
            slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        }
    }

    private static var activeWindow: UIWindow? { AppWindowMetrics.current }
}
