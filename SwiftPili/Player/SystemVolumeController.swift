import AVFoundation
import MediaPlayer
import UIKit

/// Drives the SYSTEM output volume from the player's vertical-swipe gesture
/// while suppressing iOS's stock volume HUD (the player shows its own).
///
/// A zero-alpha `MPVolumeView` parked in the key window is the only supported
/// way to both (a) move system volume programmatically and (b) keep the system
/// overlay from appearing — setting the `UISlider` it vends does both. Reads go
/// through `AVAudioSession.outputVolume`, the live value that also reflects
/// hardware-button changes, so a gesture always starts from the true level.
///
/// System volume (not the player's `playbackVolume`) is deliberate: the align
/// machine owns `playbackVolume` on the split DASH audio player and resets it
/// to 1 on every release — a UI gesture writing there would be clobbered.
@MainActor
final class SystemVolumeController {
    static let shared = SystemVolumeController()

    // Off-screen and barely visible, but genuinely in the hierarchy — both are
    // required for the slider to affect real volume and to swallow the HUD.
    private let volumeView = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
    private var slider: UISlider?

    private init() {
        volumeView.alpha = 0.0001
        volumeView.isUserInteractionEnabled = false
    }

    /// Current system output volume (0…1), including changes made with the
    /// hardware buttons since the last read.
    var volume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    /// Set system volume, suppressing the stock HUD. Returns false if the
    /// hidden slider isn't reachable yet — the caller then leaves volume alone
    /// (the next drag sample retries once the view has laid out).
    @discardableResult
    func setVolume(_ value: Float) -> Bool {
        ensureAttached()
        guard let slider else { return false }
        // Assigning .value (not sendActions) moves real system volume without
        // animating the stock overlay in.
        slider.value = min(max(value, 0), 1)
        return true
    }

    private func ensureAttached() {
        if volumeView.superview == nil, let window = Self.activeWindow {
            window.addSubview(volumeView)
            // MPVolumeView builds its slider during layout, not init.
            volumeView.layoutIfNeeded()
        }
        if slider == nil {
            slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        }
    }

    /// The app's own window — via `AppWindowMetrics`, not a local scan.
    ///
    /// This probe filtered on `.foregroundActive` but not on `windowLevel` or
    /// `rootViewController`, so `windows.first` could return UIKit's
    /// `UITextEffectsWindow` / `UIRemoteKeyboardWindow`. Parking the
    /// `MPVolumeView` in a keyboard window is worse than parking it nowhere:
    /// those windows are UIKit's to create and destroy, so the view — and the
    /// `UISlider` that IS the volume control — would silently go away with the
    /// keyboard, leaving the gesture reading a live volume it could not change.
    private static var activeWindow: UIWindow? { AppWindowMetrics.current }
}
