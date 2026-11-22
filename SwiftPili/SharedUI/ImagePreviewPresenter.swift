import SwiftUI
import UIKit

extension View {
    func imagePreview(item: Binding<ImagePreviewItem?>) -> some View {
        background { ImagePreviewPresentation(item: item).frame(width: 0, height: 0) }
    }
}

private struct ImagePreviewPresentation: UIViewRepresentable {
    @Binding var item: ImagePreviewItem?

    func makeUIView(context: Context) -> ImagePreviewHostAnchorView {
        ImagePreviewHostAnchorView()
    }

    func updateUIView(_ view: ImagePreviewHostAnchorView, context: Context) {
        view.update(binding: $item)
    }

    static func dismantleUIView(_ view: ImagePreviewHostAnchorView, coordinator: ()) {
        view.retire()
    }
}

@MainActor final class ImagePreviewHostAnchorView: UIView {
    private let ownerID = UUID()
    private var binding: Binding<ImagePreviewItem?>?
    private weak var lastScene: UIWindowScene?
    private var retired = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scene = window?.windowScene {
            lastScene = scene
            reconcile()
        }
    }

    func update(binding: Binding<ImagePreviewItem?>) {
        self.binding = binding
        reconcile()
    }

    func retire() {
        retired = true
        let scene = window?.windowScene ?? lastScene
        if let scene {
            ImagePreviewOverlayCoordinator.shared(for: scene).dismiss(ownerID: ownerID, animated: false)
        }
    }

    private func reconcile() {
        guard !retired, let binding else { return }
        if let item = binding.wrappedValue {
            guard let sourceWindow = window, let scene = sourceWindow.windowScene else { return }
            lastScene = scene
            ImagePreviewOverlayCoordinator.shared(for: scene).present(
                item: item,
                ownerID: ownerID,
                sourceWindow: sourceWindow,
                clearBinding: { [weak self] dismissedID in
                    Task { @MainActor [weak self] in
                        guard let self, let current = self.binding,
                              current.wrappedValue?.id == dismissedID else { return }
                        current.wrappedValue = nil
                    }
                }
            )
        } else if let scene = window?.windowScene ?? lastScene {
            ImagePreviewOverlayCoordinator.shared(for: scene).dismiss(ownerID: ownerID, animated: true)
        }
    }
}

@MainActor private final class ImagePreviewOverlayWindow: UIWindow {
    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 2)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor final class ImagePreviewOverlayCoordinator {
    private static let instances = NSMapTable<UIWindowScene, ImagePreviewOverlayCoordinator>.weakToStrongObjects()

    static func shared(for scene: UIWindowScene) -> ImagePreviewOverlayCoordinator {
        if let existing = instances.object(forKey: scene) {
            return existing
        }
        let coordinator = ImagePreviewOverlayCoordinator(scene: scene)
        instances.setObject(coordinator, forKey: scene)
        return coordinator
    }

    private weak var scene: UIWindowScene?
    private var overlayWindow: ImagePreviewOverlayWindow?
    private var viewer: ImagePreviewViewController?
    private weak var previousKeyWindow: UIWindow?
    private var activeOwnerID: UUID?
    private var activeItemID: UUID?
    private var clearActiveBinding: ((UUID) -> Void)?

    private init(scene: UIWindowScene) {
        self.scene = scene
    }

    func present(
        item: ImagePreviewItem,
        ownerID: UUID,
        sourceWindow: UIWindow,
        clearBinding: @escaping (UUID) -> Void
    ) {
        guard !item.urls.isEmpty, item.urls.indices.contains(item.index) else {
            clearBinding(item.id)
            return
        }
        if activeItemID == item.id, activeOwnerID == ownerID { return }

        if let previousItemID = activeItemID, activeOwnerID != ownerID {
            clearActiveBinding?(previousItemID)
        }
        sourceWindow.endEditing(true)
        if let currentKey = scene?.windows.first(where: \.isKeyWindow), currentKey !== overlayWindow {
            previousKeyWindow = currentKey
        } else if previousKeyWindow == nil, sourceWindow !== overlayWindow {
            previousKeyWindow = sourceWindow
        }

        guard let activeScene = sourceWindow.windowScene ?? scene else { return }
        let (window, controller) = ensureOverlayHost(scene: activeScene)
        controller.cancelActiveTransition()
        let initialSource = item.origin?.resolve(index: item.index, in: sourceWindow)

        activeOwnerID = ownerID
        activeItemID = item.id
        clearActiveBinding = clearBinding

        window.frame = sourceWindow.frame
        controller.prepareForPresentation(item: item, sourceWindow: sourceWindow, initialSource: initialSource)
        window.isUserInteractionEnabled = true
        window.makeKeyAndVisible()
        controller.startOpenAnimation()
    }

    func dismiss(ownerID: UUID, animated: Bool) {
        guard activeOwnerID == ownerID else { return }
        viewer?.dismiss(animated: animated)
    }

    private func ensureOverlayHost(scene: UIWindowScene) -> (ImagePreviewOverlayWindow, ImagePreviewViewController) {
        if let overlayWindow, let viewer {
            return (overlayWindow, viewer)
        }
        let window = ImagePreviewOverlayWindow(windowScene: scene)
        let controller = ImagePreviewViewController()
        controller.onRequestDismiss = { [weak self] dismissedID in
            self?.handleDismissRequested(itemID: dismissedID)
        }
        controller.onDidFinishDismissal = { [weak self] dismissedID in
            self?.handleDismissFinished(itemID: dismissedID)
        }
        window.rootViewController = controller
        overlayWindow = window
        viewer = controller
        return (window, controller)
    }

    private func handleDismissRequested(itemID: UUID) {
        guard activeItemID == itemID else { return }
        overlayWindow?.isUserInteractionEnabled = false
        clearActiveBinding?(itemID)
    }

    private func handleDismissFinished(itemID: UUID) {
        guard activeItemID == itemID else { return }
        activeOwnerID = nil
        activeItemID = nil
        clearActiveBinding = nil
        overlayWindow?.isHidden = true
        if overlayWindow?.isKeyWindow == true {
            previousKeyWindow?.makeKey()
        }
        previousKeyWindow = nil
    }
}
