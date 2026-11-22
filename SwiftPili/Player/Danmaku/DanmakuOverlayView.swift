import SwiftUI
import UIKit

struct DanmakuOverlayView: UIViewRepresentable {
    var scaleMode: VideoScaleMode = .fit
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
    static let danmakuPreferencesCommit = Notification.Name("SwiftPili.danmakuPreferencesCommit")
}

final class DanmakuHostView: UIView {
    let controller = DanmakuRenderController()
    private var appliedPreferences = DanmakuRenderPreferences.load()
    var scaleMode: VideoScaleMode = .fit
    var picture: CGRect?
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
        if controller.resize(
            viewport: bounds.size,
            picture: picture,
            presentation: Self.presentation(),
            preferences: preferences,
            maskFit: scaleMode
        ) {
            PlayerViewModel.shared.noteDanmakuVisibleSetWiped()
            PlayerViewModel.shared.noteDanmakuLayoutDefaultsChange()
        }
    }

    private static func presentation() -> DanmakuPresentation {
        PlayerViewModel.shared.isFullscreen ? .fullscreen : .inline
    }

    fileprivate func applyRenderPreferenceChange() {
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
