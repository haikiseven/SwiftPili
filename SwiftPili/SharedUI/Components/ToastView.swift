import SwiftUI

struct ToastMessage: Identifiable, Equatable {
    enum Style {
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

    var body: some View {
        HStack(spacing: 8) {
            switch message.style {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            case .error:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .progress:
                ProgressView()
                    .controlSize(.small)
            }

            Text(message.text)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .transition(motion.transition(normal: .move(edge: .bottom).combined(with: .opacity)))
    }
}

@MainActor
@Observable
final class AppNoticeCenter {
    static let shared = AppNoticeCenter()

    private(set) var message: ToastMessage?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    init() {}

    func showError(_ text: String) {
        show(text, style: .error)
    }

    func show(_ text: String, style: ToastMessage.Style = .error) {
        dismissTask?.cancel()
        message = ToastMessage(text: text, style: style)
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            self.message = nil
        }
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

private struct AppNoticeOverlayModifier: ViewModifier {
    let bottomPadding: CGFloat
    @AppMotion private var motion
    @Environment(AppNoticeCenter.self) private var environmentNoticeCenter: AppNoticeCenter?
    @Environment(\.appNoticeCenter) private var keyNoticeCenter

    private var activeNoticeCenter: AppNoticeCenter {
        environmentNoticeCenter ?? keyNoticeCenter ?? .shared
    }

    private var currentMessage: ToastMessage? {
        let center = activeNoticeCenter
        if let message = center.message {
            return message
        }
        if center !== AppNoticeCenter.shared {
            return AppNoticeCenter.shared.message
        }
        return nil
    }

    func body(content: Content) -> some View {
        let currentMessage = currentMessage
        content.overlay(alignment: .bottom) {
            Group {
                if let currentMessage {
                    ToastView(message: currentMessage)
                        .padding(.horizontal, AppSpacing.l)
                        .padding(.bottom, AppSpacing.m + bottomPadding)
                }
            }
            .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: currentMessage)
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func appNoticeOverlay(bottomPadding: CGFloat = 0) -> some View {
        modifier(AppNoticeOverlayModifier(bottomPadding: bottomPadding))
    }
}
