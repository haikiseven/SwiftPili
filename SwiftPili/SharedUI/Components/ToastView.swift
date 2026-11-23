import SwiftUI
import UIKit

struct ToastMessage: Identifiable, Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case success
        case warning
        case error
        case progress
    }

    let id = UUID()
    let text: String
    let style: Style
}

struct ToastView: View {
    let message: ToastMessage
    @AppMotion private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 8) {
            switch message.style {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .error:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .progress:
                ProgressView()
                    .controlSize(.small)
            }

            Text(message.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .toastCapsuleSurface(reduceTransparency: reduceTransparency)
        .transition(motion.transition(normal: .move(edge: .bottom).combined(with: .opacity)))
    }
}

private extension View {
    @ViewBuilder
    func toastCapsuleSurface(reduceTransparency: Bool) -> some View {
        if !reduceTransparency, #available(iOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        }
    }
}

@MainActor
private final class WeakNoticeHost {
    let id: UUID
    weak var view: UIView?

    init(id: UUID, view: UIView) {
        self.id = id
        self.view = view
    }

    var isEligible: Bool {
        guard let view, let window = view.window else { return false }
        guard !window.isHidden, window.alpha > 0.01 else { return false }
        var current: UIView? = view
        while let node = current {
            if node.isHidden || node.alpha <= 0.01 { return false }
            current = node.superview
        }
        return true
    }

    var isKeyWindow: Bool {
        view?.window?.isKeyWindow == true
    }

    var isForegroundActive: Bool {
        view?.window?.windowScene?.activationState == .foregroundActive
    }

    var isOnTopController: Bool {
        var responder: UIResponder? = view?.next
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller.presentedViewController == nil
            }
            responder = current.next
        }
        return false
    }
}

@MainActor
@Observable
final class AppNoticeCenter {
    static let shared = AppNoticeCenter()

    private(set) var message: ToastMessage?
    private(set) var alert: ToastMessage?
    private(set) var messageHostID: UUID?
    private(set) var alertHostID: UUID?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var hosts: [WeakNoticeHost] = []

    init() {}

    func showError(_ text: String) {
        show(text, style: .error)
    }

    func show(_ text: String, style: ToastMessage.Style = .error) {
        if style == .error {
            alert = ToastMessage(text: text, style: .error)
            alertHostID = resolveActiveHostID()
            return
        }
        dismissTask?.cancel()
        let toast = ToastMessage(text: text, style: style)
        message = toast
        messageHostID = resolveActiveHostID()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, self.message?.id == toast.id else { return }
            self.message = nil
            self.messageHostID = nil
        }
    }

    func dismissAlert(id: UUID? = nil) {
        guard let current = alert else { return }
        if let id, current.id != id { return }
        alert = nil
        alertHostID = nil
    }

    fileprivate func registerHost(_ id: UUID, view: UIView) {
        hosts.removeAll { $0.view == nil || $0.id == id }
        hosts.append(WeakNoticeHost(id: id, view: view))
        if (alert != nil && alertHostID == nil) || (message != nil && messageHostID == nil) {
            scheduleMainRunloopTurn { [weak self] in
                guard let self else { return }
                if self.alert != nil, self.alertHostID == nil {
                    self.alertHostID = self.resolveActiveHostID()
                }
                if self.message != nil, self.messageHostID == nil {
                    self.messageHostID = self.resolveActiveHostID()
                }
            }
        }
    }

    fileprivate func unregisterHost(_ id: UUID) {
        hosts.removeAll { $0.view == nil || $0.id == id }
        if alertHostID == id || messageHostID == id {
            scheduleMainRunloopTurn { [weak self] in
                guard let self else { return }
                if self.alertHostID == id {
                    self.alert = nil
                    self.alertHostID = nil
                }
                if self.messageHostID == id {
                    self.messageHostID = self.resolveActiveHostID()
                }
            }
        }
    }

    private func resolveActiveHostID() -> UUID? {
        hosts.removeAll { $0.view == nil }
        let reversed = hosts.reversed()
        if let match = reversed.first(where: { $0.isEligible && $0.isOnTopController && $0.isKeyWindow }) {
            return match.id
        }
        if let match = reversed.first(where: { $0.isEligible && $0.isOnTopController && $0.isForegroundActive }) {
            return match.id
        }
        if let match = reversed.first(where: { $0.isEligible && $0.isOnTopController }) {
            return match.id
        }
        if let match = reversed.first(where: { $0.isEligible && $0.isKeyWindow }) {
            return match.id
        }
        if let match = reversed.first(where: { $0.isEligible }) {
            return match.id
        }
        return hosts.last?.id
    }
}

private struct AppNoticeCenterKey: EnvironmentKey {
    static let defaultValue: AppNoticeCenter? = nil
}

extension EnvironmentValues {
    var appNoticeCenter: AppNoticeCenter? {
        get { self[AppNoticeCenterKey.self] }
        set { self[AppNoticeCenterKey.self] = newValue }
    }
}

private struct AppNoticeHostProbe: UIViewRepresentable {
    let onAttach: @MainActor (UIView) -> Void
    let onDetach: @MainActor () -> Void

    func makeUIView(context: Context) -> HostProbeView {
        let view = HostProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.onAttach = onAttach
        view.onDetach = onDetach
        return view
    }

    func updateUIView(_ uiView: HostProbeView, context: Context) {
        uiView.onAttach = onAttach
        uiView.onDetach = onDetach
    }

    static func dismantleUIView(_ uiView: HostProbeView, coordinator: ()) {
        let onDetach = uiView.onDetach
        uiView.onAttach = nil
        uiView.onDetach = nil
        onDetach?()
    }

    @MainActor
    final class HostProbeView: UIView {
        var onAttach: (@MainActor (UIView) -> Void)?
        var onDetach: (@MainActor () -> Void)?

        override var intrinsicContentSize: CGSize { .zero }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onAttach?(self)
            } else {
                onDetach?()
            }
        }
    }
}

private struct AppNoticeOverlayModifier: ViewModifier {
    let bottomPadding: CGFloat
    @State private var hostID = UUID()
    @AppMotion private var motion
    @Environment(AppNoticeCenter.self) private var environmentNoticeCenter: AppNoticeCenter?
    @Environment(\.appNoticeCenter) private var keyNoticeCenter

    private var activeNoticeCenter: AppNoticeCenter {
        environmentNoticeCenter ?? keyNoticeCenter ?? .shared
    }

    private var currentMessage: ToastMessage? {
        let center = activeNoticeCenter
        if let message = center.message, message.style != .error, center.messageHostID == hostID {
            return message
        }
        if center !== AppNoticeCenter.shared,
           let message = AppNoticeCenter.shared.message,
           message.style != .error,
           AppNoticeCenter.shared.messageHostID == hostID {
            return message
        }
        return nil
    }

    private var currentAlert: ToastMessage? {
        let center = activeNoticeCenter
        if let alert = center.alert, center.alertHostID == hostID {
            return alert
        }
        if center !== AppNoticeCenter.shared,
           let alert = AppNoticeCenter.shared.alert,
           AppNoticeCenter.shared.alertHostID == hostID {
            return alert
        }
        return nil
    }

    private func register(view: UIView) {
        let center = activeNoticeCenter
        center.registerHost(hostID, view: view)
        if center !== AppNoticeCenter.shared {
            AppNoticeCenter.shared.registerHost(hostID, view: view)
        }
    }

    private func unregister() {
        let center = activeNoticeCenter
        center.unregisterHost(hostID)
        if center !== AppNoticeCenter.shared {
            AppNoticeCenter.shared.unregisterHost(hostID)
        }
    }

    private func dismissAlert(id: UUID) {
        let center = activeNoticeCenter
        center.dismissAlert(id: id)
        if center !== AppNoticeCenter.shared {
            AppNoticeCenter.shared.dismissAlert(id: id)
        }
    }

    func body(content: Content) -> some View {
        let visibleMessage = currentMessage
        let visibleAlert = currentAlert
        content
            .background {
                AppNoticeHostProbe(
                    onAttach: { register(view: $0) },
                    onDetach: { unregister() }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                Group {
                    if let visibleMessage {
                        ToastView(message: visibleMessage)
                            .padding(.horizontal, AppSpacing.l)
                            .padding(.bottom, AppSpacing.m + bottomPadding)
                    }
                }
                .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: visibleMessage)
                .allowsHitTesting(false)
            }
            .alert(
                "Operation Failed",
                isPresented: Binding(
                    get: { currentAlert != nil },
                    set: { isPresented in
                        if !isPresented, let alert = currentAlert {
                            dismissAlert(id: alert.id)
                        }
                    }
                ),
                presenting: visibleAlert
            ) { alert in
                Button("OK", role: .cancel) {
                    dismissAlert(id: alert.id)
                }
            } message: { alert in
                Text(alert.text)
            }
    }
}

extension View {
    func appNoticeOverlay(bottomPadding: CGFloat = 0) -> some View {
        modifier(AppNoticeOverlayModifier(bottomPadding: bottomPadding))
    }
}
