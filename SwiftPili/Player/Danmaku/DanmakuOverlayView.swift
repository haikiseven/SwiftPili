import SwiftUI
import UIKit

/// Hosts the danmaku layer tree outside SwiftUI's observation graph.
///
/// `updateUIView` deliberately ignores playback time. A body that read
/// `mediaTime` would redraw `PlayerView` on every clock tick. The clock reaches
/// the tree only through `DanmakuTimelineSink`.
struct DanmakuOverlayView: UIViewRepresentable {
    /// The view covers the whole player: bullets fly over letterbox bars, as
    /// in PiliPlus and wiliwili. The scale mode tells the person mask where
    /// the video sits inside it.
    var scaleMode: VideoScaleMode = .fit
    /// The video's rectangle in this view, for mode 7, which is authored
    /// against the video frame. Nil means the whole view.
    var picture: CGRect?

    func makeUIView(context _: Context) -> DanmakuHostView {
        let view = DanmakuHostView()
        view.isUserInteractionEnabled = false
        PlayerViewModel.shared.attachDanmakuSink(view.controller)
        return view
    }

    func updateUIView(_ uiView: DanmakuHostView, context _: Context) {
        uiView.scaleMode = scaleMode
        uiView.picture = picture
        uiView.syncBounds()
    }

    static func dismantleUIView(_ uiView: DanmakuHostView, coordinator _: ()) {
        PlayerViewModel.shared.detachDanmakuSink(uiView.controller)
        uiView.controller.teardown()
    }
}

/// Removes the render-preference observer when the host is released.
///
/// NotificationCenter removal is thread-safe. `DanmakuHostView` is main-actor
/// isolated and its `deinit` is not, so the token — not the view — calls
/// `removeObserver`. The view's `deinit` is what drops this token.
private final class DanmakuPreferenceObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    nonisolated(unsafe) weak var host: DanmakuHostView?

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func install() {
        let names: [Notification.Name] = [
            UserDefaults.didChangeNotification,
            .danmakuPreferencesCommit,
        ]
        let installed = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == UserDefaults.didChangeNotification, note.object as? UserDefaults !== UserDefaults.standard {
                    return
                }
                MainActor.assumeIsolated {
                    self?.host?.applyRenderPreferenceChange()
                }
            }
        }
        lock.lock()
        tokens = installed
        lock.unlock()
    }

    /// Idempotent. A second call sees an empty list and does not remove twice.
    func invalidate() {
        lock.lock()
        let installed = tokens
        tokens = []
        lock.unlock()
        for token in installed {
            center.removeObserver(token)
        }
    }

    deinit {
        invalidate()
    }
}

extension Notification.Name {
    /// Posted when the landscape danmaku panel closes. Each write is already
    /// applied while the panel is open; this catches a commit that did not
    /// itself post `UserDefaults.didChangeNotification`. Not a UserDefaults write.
    static let danmakuPreferencesCommit = Notification.Name("SwiftPili.danmakuPreferencesCommit")
}

final class DanmakuHostView: UIView {
    let controller = DanmakuRenderController()
    /// Last preferences applied from a defaults notification. Layout passes
    /// do not write this: a bounds change is not a preference change.
    private var appliedPreferences = DanmakuRenderPreferences.load()
    /// Set by `DanmakuOverlayView` before each `syncBounds`.
    var scaleMode: VideoScaleMode = .fit
    /// Set by `DanmakuOverlayView` before each `syncBounds`.
    var picture: CGRect?
    /// `nonisolated(unsafe)` so `deinit`, which is not main-actor isolated,
    /// can drop the token and remove the observer.
    nonisolated(unsafe) private var preferenceObserver: DanmakuPreferenceObserver?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(controller.container)
        let observer = DanmakuPreferenceObserver()
        preferenceObserver = observer
        observer.host = self
        observer.install()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        preferenceObserver?.invalidate()
        preferenceObserver = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncBounds()
    }

    func syncBounds() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controller.container.frame = bounds
        let preferences = DanmakuRenderPreferences.load()
        controller.setContainerOpacity(preferences.opacity)
        CATransaction.commit()
        // Lane count is (player height × display area) / lane height, and
        // the lane height follows the presentation, not these bounds (B1).
        // `isFullscreen` is read here, on a layout pass, never per tick: an
        // enter or exit remounts this host or resizes it, and either lands here.
        if controller.resize(
            viewport: bounds.size,
            picture: picture,
            presentation: Self.presentation(),
            preferences: preferences,
            maskFit: scaleMode
        ) {
            // Same as a layout-preference change. The wipe flag is only consumed
            // on a clock edge, and a paused rotation produces no media tick.
            PlayerViewModel.shared.noteDanmakuVisibleSetWiped()
            PlayerViewModel.shared.noteDanmakuLayoutDefaultsChange()
        }
    }

    private static func presentation() -> DanmakuPresentation {
        PlayerViewModel.shared.isFullscreen ? .fullscreen : .inline
    }

    /// `UserDefaults.didChangeNotification` fires for every key. Ignore a post
    /// that does not change the loaded preferences. No display link, and this
    /// does not read `mediaTime` — a paused refill goes through the view model.
    ///
    /// Opacity is the container alpha and applies to bullets already on screen,
    /// including while the landscape panel is open. Font scale, scroll lifetime,
    /// display area, overlap avoidance, block words and the kind switches apply
    /// only to bullets admitted after this call (B3, option a): in-flight
    /// layers keep their size, speed and lane, and the allocator keeps their
    /// occupancy so a new bullet cannot land on one. Nothing is cleared. A
    /// viewport or presentation change still wipes through `syncBounds` → `resize`.
    fileprivate func applyRenderPreferenceChange() {
        // Not a layout input and not part of `DanmakuRenderPreferences`: the
        // switch attaches or detaches the mask at once, on bullets already up.
        controller.mask.setEnabled(DanmakuRenderPreferences.smartMaskEnabled())
        let preferences = DanmakuRenderPreferences.load()
        guard preferences != appliedPreferences else { return }
        let layout = preferences.layoutChanged(from: appliedPreferences)
        appliedPreferences = preferences
        controller.setContainerOpacity(preferences.opacity)
        guard layout else { return }
        controller.retargetLayout(preferences: preferences)
    }
}
