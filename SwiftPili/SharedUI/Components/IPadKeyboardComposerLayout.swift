import SwiftUI
import UIKit

enum IPadKeyboardComposerLayout {
    static let maxWidth: CGFloat = 600
    static let pillHeight: CGFloat = 46
    static let pillHorizontalPadding: CGFloat = 16
    static let pillVerticalPadding: CGFloat = 10
    static let keyboardBottomSpacing: CGFloat = 10
    static let sendButtonVisualDiameter: CGFloat = 32
    static let hitTargetSize: CGFloat = 44

    @MainActor static func usesDock(
        windowSize: CGSize,
        isRegularWidth: Bool = true
    ) -> Bool {
        DeviceCapability.supportsPadKeyboardDock
            && isRegularWidth
            && windowSize.width > windowSize.height
    }
}

extension View {
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
            let value = IPadKeyboardComposerLayout.usesDock(
                windowSize: window.bounds.size,
                isRegularWidth: window.traitCollection.horizontalSizeClass == .regular
            )
            guard value != lastReported else { return }
            lastReported = value
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(value)
            }
        }
    }
}

private let dockHiddenTransform = CGAffineTransform(translationX: 0, y: 10)

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
        guard isPresented else {
            view.dismiss(animated: true)
            return
        }
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
        view.update(isPresented: true, root: root)
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

    private final class DockWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let hit = super.hitTest(point, with: event) else { return nil }
            if hit === self || hit === rootViewController?.view { return nil }
            return hit
        }
    }
}
