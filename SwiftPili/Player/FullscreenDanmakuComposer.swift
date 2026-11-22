import SwiftUI
import UIKit

/// One in-flight danmaku send per composer. `begin` admits a trimmed,
/// non-empty draft only while no send is pending and returns the text to post;
/// `settle` reopens the gate when the result has been applied. The draft stays
/// the caller's: it is cleared on success only, so a failure keeps what the
/// user wrote. A second submit while pending is refused here, not by the POST
/// (which never retries and would double-post).
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

/// The sending indicator every danmaku composer shows beside its field.
struct DanmakuSendingIndicator: View {
    var tint: Color = .secondary

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(tint)
            .accessibilityLabel(Text("Sending…"))
    }
}

/// A send result shown over the fullscreen host: the failure, or "sent".
///
/// Identity is per presentation, not per text: two identical messages in a row
/// are two notices, and the second restarts the dismissal.
struct DanmakuNotice: Equatable, Sendable {
    let text: String
    let id = UUID()
}

extension View {
    /// Draws `notice` as a capsule over this view and clears it after
    /// `DanmakuNoticeToast.duration`. The timer is the view's own task, keyed
    /// by the notice: a new notice restarts it, clearing cancels it, and it
    /// ends with the view.
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

/// Fullscreen send bar. It is an overlay sibling of `PlayerView`, so only this
/// bar moves for the keyboard. A docked keyboard whose bottom edge meets the
/// container puts the bar on the keyboard's top; a floating keyboard that does
/// not meet that edge leaves the bar on the physical inset.
///
/// Close always dismisses. A focus resignation does not: the host decides, so
/// scrubbing can drop the keyboard without posting, and a send that clears the
/// draft can resign without taking the empty-draft path.
struct FullscreenDanmakuComposer: View {
    @Binding var draft: String
    var notice: String?
    /// A send is pending: the field is disabled and shows the sending state.
    var isSending = false
    var keyboardFrame: CGRect?
    var onSubmit: () -> Void
    var onClose: () -> Void
    var onFocusLost: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        field
            .frame(maxWidth: Self.maxFieldWidth)
            .frame(maxWidth: .infinity)
            .padding(.leading, AppWindowMetrics.safeAreaInsets.left + AppSpacing.l)
            .padding(.trailing, AppWindowMetrics.safeAreaInsets.right + AppSpacing.l)
            .padding(.bottom, bottomInset)
            // `bottomInset` is the single keyboard offset; the host also opts
            // out of safe-area avoidance so SwiftUI adds none on top.
            .ignoresSafeArea()
    }

    /// Comfortable field width on iPad, where fullscreen is far wider than a
    /// single-line input needs. iPhone keeps the full available width.
    private static var maxFieldWidth: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? IPadKeyboardComposerLayout.maxWidth : .infinity
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bottomInset: CGFloat {
        let physical = AppWindowMetrics.safeAreaInsets.bottom
        let inset = LivePortraitKeyboardLayout.effectiveBottomInset(
            physicalBottomInset: physical,
            keyboardFrame: keyboardFrame,
            containerFrame: AppWindowMetrics.frameInScreen ?? .zero
        )
        // A docked keyboard raised the inset above the physical one; rest the
        // bar a fixed gap above it instead of touching it.
        return inset > physical ? inset + IPadKeyboardComposerLayout.keyboardBottomSpacing : inset
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
