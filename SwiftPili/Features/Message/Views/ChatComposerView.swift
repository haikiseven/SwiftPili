import SwiftUI

struct ChatComposerView: View {
    let sendMessage: @MainActor (String) async throws -> Void
    @State private var draft = ""
    @State private var submission = CommentComposerSubmission()
    @State private var sendError: String?
    @State private var isIPadLandscape = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 4) {
            if let sendError {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(sendError)
                        .appFont(.messageMeta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            }
            HStack(alignment: .bottom, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.s) {
                    Image(systemName: "bubble.left")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Message...", text: draftBinding, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .appFont(.messageBody)
                }
                .padding(.leading, IPadKeyboardComposerLayout.pillHorizontalPadding)
                .padding(.vertical, IPadKeyboardComposerLayout.pillVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)

                FloatingComposerSendButton(
                    canSend: canSend,
                    isBusy: submission.isSending,
                    isSendingWithoutCancel: true,
                    onSend: send
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
            .padding(.horizontal, AppSpacing.l)
            .padding(.top, 6)
            .padding(.bottom, isIPadLandscape ? IPadKeyboardComposerLayout.keyboardBottomSpacing : AppSpacing.s)
        }
        .frame(maxWidth: isIPadLandscape ? IPadKeyboardComposerLayout.maxWidth : ReadableWidth.feed)
        .frame(maxWidth: .infinity)
        .iPadLandscapeWindowProbe($isIPadLandscape)
    }

    private var canSend: Bool {
        !submission.isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var draftBinding: Binding<String> {
        Binding(get: { draft }, set: { value in
            submission.draftDidChange()
            sendError = nil
            draft = value
        })
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let attempt = submission.begin() else { return }
        sendError = nil
        Task { await performSend(text, attempt: attempt) }
    }

    private func performSend(_ text: String, attempt: CommentComposerSubmission.Attempt) async {
        defer { submission.finish(attempt) }
        do {
            try await sendMessage(text)
            if submission.canApply(attempt) {
                draftBinding.wrappedValue = ""
            }
        } catch {
            let nsError = error as NSError
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  (error as? BiliError)?.isCancellation != true,
                  !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
            sendError = String(
                format: String(localized: "Send failed: %@"),
                error.localizedDescription
            )
        }
    }
}
