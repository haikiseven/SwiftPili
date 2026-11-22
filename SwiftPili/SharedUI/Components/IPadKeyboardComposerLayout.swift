import SwiftUI
import UIKit

/// Shared policy and unified Liquid Glass pill metrics for floating input bars
/// across comment, chat, live danmaku, and fullscreen danmaku composers.
enum IPadKeyboardComposerLayout {
    /// Comfortable line length for centered keyboard-docked bars on iPad landscape.
    static let maxWidth: CGFloat = 600
    /// Single-line floating pill height (`46–48pt` Apple iOS 26 rhythm).
    static let pillHeight: CGFloat = 46
    static let pillHorizontalPadding: CGFloat = 16
    static let pillVerticalPadding: CGFloat = 10
    /// Balanced breathing space between a floating bar and the docked keyboard.
    static let keyboardBottomSpacing: CGFloat = 10
    /// Tactile circular send button inside the 44pt accessible hit target.
    static let sendButtonVisualDiameter: CGFloat = 32
    static let hitTargetSize: CGFloat = 44

    /// True for an iPad window that is wider than tall. Phones and portrait
    /// iPad windows (including narrow Split View / Slide Over) keep the
    /// existing full-width presentation.
    @MainActor static func usesDock(windowSize: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && windowSize.width > windowSize.height
    }
}

extension View {
    /// Unified floating Liquid Glass surface: interactive Liquid Glass on iOS 26+,
    /// clean soft-elevated material on iOS 18, and crisp opaque card fill under
    /// Reduce Transparency — without muddy `0.5pt` borders.
    @ViewBuilder
    func floatingGlassInputSurface<S: Shape>(
        in shape: S,
        interactive: Bool = true,
        reduceTransparency: Bool
    ) -> some View {
        if reduceTransparency {
            background(AppFill.card, in: shape)
        } else if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        }
    }
}

/// Tactile accent circular send control shared across all floating input bars.
struct FloatingComposerSendButton: View {
    let canSend: Bool
    var isBusy: Bool = false
    var isSendingWithoutCancel: Bool = false
    var accessibilityLabel: LocalizedStringKey = "Send"
    var onSend: () -> Void
    var onCancel: (() -> Void)?

    var body: some View {
        Button {
            if isBusy {
                onCancel?()
            } else if canSend {
                onSend()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(
                        width: IPadKeyboardComposerLayout.sendButtonVisualDiameter,
                        height: IPadKeyboardComposerLayout.sendButtonVisualDiameter
                    )
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isSendingWithoutCancel ? .white : .secondary)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                }
            }
            .frame(
                width: IPadKeyboardComposerLayout.hitTargetSize,
                height: IPadKeyboardComposerLayout.hitTargetSize
            )
            .contentShape(Circle())
        }
        .buttonStyle(.appControl)
        .disabled(isBusy ? (onCancel == nil) : !canSend)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(resolvedAccessibilityLabel)
    }

    private var circleFill: AnyShapeStyle {
        if isBusy {
            return isSendingWithoutCancel
                ? AnyShapeStyle(Color.biliAccent.opacity(0.65))
                : AnyShapeStyle(AppFill.inset)
        }
        return canSend ? AnyShapeStyle(Color.biliAccent) : AnyShapeStyle(AppFill.inset)
    }

    private var resolvedAccessibilityLabel: Text {
        if isBusy {
            return onCancel != nil ? Text("Cancel sending") : Text("Sending…")
        }
        return Text(accessibilityLabel)
    }
}

extension View {
    /// Reports whether the hosting window is an iPad landscape window. The probe
    /// reads the real window bounds so a clipped or narrow parent column (such
    /// as the 360 pt stage comment panel) does not change the answer.
    func iPadLandscapeWindowProbe(_ isLandscape: Binding<Bool>) -> some View {
        background {
            IPadWindowGeometryProbe(isLandscape: isLandscape)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct IPadWindowGeometryProbe: UIViewRepresentable {
    @Binding var isLandscape: Bool

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = { value in
            if isLandscape != value { isLandscape = value }
        }
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = { value in
            if isLandscape != value { isLandscape = value }
        }
        view.report()
    }

    final class ProbeView: UIView {
        var onChange: ((Bool) -> Void)?
        private var lastReported: Bool?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        func report() {
            guard let window else { return }
            let value = IPadKeyboardComposerLayout.usesDock(windowSize: window.bounds.size)
            guard value != lastReported else { return }
            lastReported = value
            // Never mutate SwiftUI state inside a view update pass.
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(value)
            }
        }
    }
}

private let dockHiddenTransform = CGAffineTransform(translationX: 0, y: 10)

/// Presents SwiftUI content in a transparent, touch-through overlay window that
/// spans the whole scene. A child inside a clipped column (for example the
/// stage comment panel) cannot escape the clip; a window can. The hosting
/// controller receives the scene's keyboard safe area, so the content tracks
/// the keyboard natively, and the overlay becomes key while presented so text
/// focus inside it behaves as it does in the app window.
struct IPadKeyboardDockPresenter<Content: View>: UIViewRepresentable {
    let isPresented: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.self) private var environment

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        let root = AnyView(
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content()
                    .frame(maxWidth: IPadKeyboardComposerLayout.maxWidth)
                    .padding(.horizontal, AppSpacing.l)
                    .padding(.bottom, IPadKeyboardComposerLayout.keyboardBottomSpacing)
                    .frame(maxWidth: .infinity)
            }
            .environment(\.self, environment)
        )
        view.update(isPresented: isPresented, root: root)
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: ()) {
        view.dismiss()
    }

    @MainActor
    final class AnchorView: UIView {
        private var overlay: DockWindow?
        private var host: UIHostingController<AnyView>?
        private weak var restoredKeyWindow: UIWindow?

        func update(isPresented: Bool, root: AnyView) {
            guard isPresented else {
                dismiss(animated: true)
                return
            }
            if let host {
                host.rootView = root
                cancelPendingDismissal()
                return
            }
            // Wait for window attachment; `didMoveToWindow` retries.
            pendingRoot = root
            presentIfPossible()
        }

        private var pendingRoot: AnyView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                dismiss()
            } else {
                presentIfPossible()
            }
        }

        private func presentIfPossible() {
            guard overlay == nil, let root = pendingRoot,
                  let sourceWindow = window, let scene = sourceWindow.windowScene else { return }
            let controller = UIHostingController(rootView: root)
            controller.view.backgroundColor = .clear
            let dock = DockWindow(windowScene: scene)
            dock.windowLevel = .normal + 1
            dock.backgroundColor = .clear
            dock.rootViewController = controller
            restoredKeyWindow = sourceWindow
            host = controller
            overlay = dock
            pendingRoot = nil
            dock.makeKeyAndVisible()
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            controller.view.alpha = 0
            controller.view.transform = dockHiddenTransform
            UIView.animate(
                withDuration: 0.30,
                delay: 0,
                usingSpringWithDamping: 0.92,
                initialSpringVelocity: 0.2,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                controller.view.alpha = 1
                controller.view.transform = .identity
            }
        }

        private var isDismissing = false
        private var dismissToken = 0

        /// A re-open while the fade-out is pending reuses the live window.
        private func cancelPendingDismissal() {
            guard isDismissing, let view = host?.view else { return }
            isDismissing = false
            dismissToken += 1
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                view.alpha = 1
                view.transform = .identity
            }
        }

        /// Fades the dock out before tearing the window down. Detachment from
        /// the window hierarchy (`didMoveToWindow`, dismantle) tears down at once.
        func dismiss(animated: Bool = false) {
            pendingRoot = nil
            guard overlay != nil else { return }
            guard animated, !UIAccessibility.isReduceMotionEnabled, let view = host?.view else {
                tearDown()
                return
            }
            guard !isDismissing else { return }
            isDismissing = true
            dismissToken += 1
            let token = dismissToken
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                view.alpha = 0
                view.transform = dockHiddenTransform
            } completion: { [weak self] _ in
                guard let self, self.isDismissing, self.dismissToken == token else { return }
                self.tearDown()
            }
        }

        private func tearDown() {
            isDismissing = false
            dismissToken += 1
            guard let dock = overlay else { return }
            overlay = nil
            host = nil
            dock.isHidden = true
            dock.rootViewController = nil
            if let restoredKeyWindow, restoredKeyWindow.windowScene != nil {
                restoredKeyWindow.makeKey()
            }
            restoredKeyWindow = nil
        }
    }

    /// Full-scene overlay that forwards touches outside the hosted content to
    /// the app window beneath it.
    private final class DockWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let hit = super.hitTest(point, with: event) else { return nil }
            if hit === self || hit === rootViewController?.view { return nil }
            return hit
        }
    }
}
