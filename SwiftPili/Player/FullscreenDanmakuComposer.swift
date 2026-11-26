import SwiftUI
import UIKit

struct DanmakuComposerSendGate: Equatable, Sendable {
    private(set) var isSending = false

    mutating func begin(draft: String) -> String? {
        guard !isSending else { return nil }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        isSending = true
        return text
    }

    mutating func settle() {
        isSending = false
    }
}

struct DanmakuSendingIndicator: View {
    var tint: Color = .secondary

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(tint)
            .accessibilityLabel(Text("Sending…"))
    }
}

struct DanmakuNotice: Equatable, Sendable {
    let text: String
    let id = UUID()
}

extension View {
    func danmakuNoticeToast(_ notice: Binding<DanmakuNotice?>) -> some View {
        modifier(DanmakuNoticeToast(notice: notice))
    }
}

private struct DanmakuNoticeToast: ViewModifier {
    static let duration: Duration = .seconds(3)

    @Binding var notice: DanmakuNotice?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .overlay {
                if let notice {
                    Text(notice.text)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, IPadKeyboardComposerLayout.pillHorizontalPadding)
                        .padding(.vertical, IPadKeyboardComposerLayout.pillVerticalPadding)
                        .floatingGlassInputSurface(
                            in: Capsule(),
                            interactive: false,
                            reduceTransparency: reduceTransparency
                        )
                        .environment(\.colorScheme, .dark)
                        .allowsHitTesting(false)
                }
            }
            .task(id: notice) {
                guard let shown = notice else { return }
                try? await Task.sleep(for: Self.duration)
                guard !Task.isCancelled, notice == shown else { return }
                notice = nil
            }
    }
}

struct FullscreenDanmakuComposer: View {
    @Binding var draft: String
    var notice: String?
    var isSending = false
    var keyboardFrame: CGRect?
    var onSubmit: () -> Void
    var onClose: () -> Void
    var onFocusLost: () -> Void

    static let horizontalPortraitMargin: CGFloat = 20
    static let restingBottomFloor: CGFloat = 14
    static let restingExtraBottomSpacing: CGFloat = 6

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let safeInsets = AppWindowMetrics.safeAreaInsets
        let screenFrame = AppWindowMetrics.frameInScreen ?? .zero
        let isPortraitViewport = screenFrame.height >= screenFrame.width
        let horizontalMargin = isPortraitViewport ? Self.horizontalPortraitMargin : AppSpacing.l
        field
            .frame(maxWidth: Self.maxFieldWidth)
            .frame(maxWidth: .infinity)
            .padding(.leading, max(0, safeInsets.left) + horizontalMargin)
            .padding(.trailing, max(0, safeInsets.right) + horizontalMargin)
            .padding(.bottom, bottomInset)
            .ignoresSafeArea()
    }

    private static var maxFieldWidth: CGFloat {
        DeviceCapability.supportsPadKeyboardDock ? IPadKeyboardComposerLayout.maxWidth : .infinity
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bottomInset: CGFloat {
        let physical = max(0, AppWindowMetrics.safeAreaInsets.bottom)
        let inset = LivePortraitKeyboardLayout.effectiveBottomInset(
            physicalBottomInset: physical,
            keyboardFrame: keyboardFrame,
            containerFrame: AppWindowMetrics.frameInScreen ?? .zero
        )
        if inset > physical {
            return inset + IPadKeyboardComposerLayout.keyboardBottomSpacing
        }
        return max(physical, Self.restingBottomFloor) + Self.restingExtraBottomSpacing
    }

    private var field: some View {
        HStack(spacing: 0) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(
                        width: IPadKeyboardComposerLayout.hitTargetSize,
                        height: IPadKeyboardComposerLayout.hitTargetSize
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.appControl)
            .accessibilityLabel(Text("Close"))
            .padding(.leading, 1)
            .padding(.vertical, 1)

            TextField(String(localized: "Send danmaku"), text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.white)
                .submitLabel(.send)
                .focused($isFocused)
                .padding(.vertical, IPadKeyboardComposerLayout.pillVerticalPadding)
                .padding(.trailing, AppSpacing.xs)
                .frame(maxWidth: .infinity)
                .disabled(isSending)
                .onSubmit {
                    guard !isSending else { return }
                    onSubmit()
                }
                .onAppear { isFocused = true }
                .onChange(of: isFocused) { _, focused in
                    guard !focused else { return }
                    onFocusLost()
                }

            FloatingComposerSendButton(
                canSend: canSend,
                isBusy: isSending,
                isSendingWithoutCancel: true,
                onSend: {
                    guard !isSending else { return }
                    onSubmit()
                }
            )
            .padding(.trailing, 1)
            .padding(.vertical, 1)
        }
        .frame(minHeight: IPadKeyboardComposerLayout.pillHeight)
        .floatingGlassInputSurface(
            in: Capsule(),
            interactive: true,
            reduceTransparency: reduceTransparency
        )
        .environment(\.colorScheme, .dark)
        .overlay {
            if let notice {
                Text(notice)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, IPadKeyboardComposerLayout.pillHorizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: IPadKeyboardComposerLayout.pillHeight)
                    .floatingGlassInputSurface(
                        in: Capsule(),
                        interactive: false,
                        reduceTransparency: reduceTransparency
                    )
                    .environment(\.colorScheme, .dark)
                    .allowsHitTesting(false)
            }
        }
    }
}
