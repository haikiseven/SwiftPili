import SwiftUI
import UIKit

struct VideoDetailComposerDismissScrim: View {
    @AppMotion private var motion
    let composer: VideoCommentComposerState
    let isActive: Bool
    var ignoresSafeArea = false

    var body: some View {
        if isActive, composer.isExpanded {
            let scrim = Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    composer.collapse(motion: motion)
                }
            if ignoresSafeArea {
                scrim.ignoresSafeArea()
            } else {
                scrim
            }
        }
    }
}

struct VideoDetailCommentComposerOverlay: View {
    @AppMotion private var motion
    let composer: VideoCommentComposerState
    let model: VideoDetailViewModel
    let commentPresentation: CommentZoomPresentation
    let requestedVideoID: VideoID
    let isCompactOverlay: Bool
    let showsWideChrome: Bool
    let isWideLayout: Bool
    let stagePresentation: DetailStagePresentation
    let hasActiveThread: Bool
    let isInlineCommentInputEligible: Bool
    let isModelCurrent: @MainActor () -> Bool
    let onRevealPostedComment: @MainActor (
        _ postedRpid: Int,
        _ target: CommentResult.CommentItem?,
        _ model: VideoDetailViewModel,
        _ sourceIsCurrent: @escaping @MainActor () -> Bool
    ) -> Void

    var body: some View {
        VideoDetailCommentPresentationReader(presentation: commentPresentation) { commentsPresented in
            let showsToast = isCompactOverlay
                || (showsWideChrome && stagePresentation == .stage && !hasActiveThread)
            let showsInput = (isCompactOverlay || showsWideChrome)
                && showsCommentInput(for: commentsPresented)
            let usesFeedWidth = !showsWideChrome && DeviceCapability.supportsPadDetailSplit
            VStack(spacing: 10) {
                Group {
                    if showsToast, let toast = model.toast {
                        ToastView(message: toast)
                    }
                }
                .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: model.toast)

                if showsInput {
                    VideoDetailCommentComposerBar(
                        composer: composer,
                        model: model,
                        commentPresentation: commentPresentation,
                        requestedVideoID: requestedVideoID,
                        usesFeedWidth: usesFeedWidth,
                        showsCommentInput: { showsCommentInput(for: $0) },
                        isModelCurrent: isModelCurrent,
                        onRevealPostedComment: onRevealPostedComment
                    )
                }
            }
        }
    }

    private func showsCommentInput(for commentsPresented: Bool) -> Bool {
        !hasActiveThread && isInlineCommentInputEligible
            && (isWideLayout ? stagePresentation == .stage : commentsPresented)
    }
}

struct VideoDetailCommentComposerBar: View {
    @AppMotion private var motion
    let composer: VideoCommentComposerState
    let model: VideoDetailViewModel
    let commentPresentation: CommentZoomPresentation
    let requestedVideoID: VideoID
    let usesFeedWidth: Bool
    let showsCommentInput: @MainActor (Bool) -> Bool
    let isModelCurrent: @MainActor () -> Bool
    let onRevealPostedComment: @MainActor (
        _ postedRpid: Int,
        _ target: CommentResult.CommentItem?,
        _ model: VideoDetailViewModel,
        _ sourceIsCurrent: @escaping @MainActor () -> Bool
    ) -> Void

    var body: some View {
        let captured = composer.capture(model: model, requestedID: requestedVideoID)
        CommentComposerMorphContainer(
            isExpanded: composer.isExpanded,
            hasDraft: composer.hasDraft,
            sourceIdentity: AnyHashable(captured.context.sourceIdentity),
            onExpand: { composer.open(motion: motion) },
            expandedComposer: { expandedComposer(captured: captured) }
        )
        .frame(maxWidth: usesFeedWidth ? ReadableWidth.feed : .infinity)
        .frame(maxWidth: .infinity)
    }

    private func expandedComposer(captured: VideoCommentComposerState.Capture) -> some View {
        CommentComposerBar(
            text: composer.textBinding(for: captured, isCurrentModelAndVideo: isModelCurrent),
            pictures: composer.picturesBinding(for: captured, isCurrentModelAndVideo: isModelCurrent),
            placeholder: composer.replyTarget.map { CommentComposerBar.replyPlaceholder(to: $0.member.uname) }
                ?? String(localized: "Write a comment..."),
            replyBanner: composer.replyTarget.map { CommentComposerBar.replyBannerText(for: $0.member.uname) },
            isSending: composer.isSending,
            focus: composer.focus,
            autoFocusOnAppear: composer.isExpanded && !composer.isSending,
            usesExternalMorphSurface: true,
            onCancelReply: {
                composer.cancelReply(
                    captured: captured,
                    isCurrentModelAndVideo: isModelCurrent,
                    motion: motion
                )
            },
            onCollapse: { composer.collapse(motion: motion) },
            onSend: {
                guard composer.isExpanded,
                      composer.isCurrent(captured, isCurrentModelAndVideo: isModelCurrent) else { return }
                composer.send(
                    model: model,
                    requestedVideoID: requestedVideoID,
                    isCurrentModelAndVideo: isModelCurrent,
                    motion: motion,
                    onReveal: onRevealPostedComment
                )
            },
            onCancelSend: { composer.cancelSend() },
            uploadScope: composer.uploadScope(for: captured, isCurrentModelAndVideo: isModelCurrent),
            isInteractionCurrent: {
                showsCommentInput(commentPresentation.isPresented)
                    && composer.isCurrent(captured, isCurrentModelAndVideo: isModelCurrent)
            }
        )
        .id(captured.context.sourceIdentity)
        .id(captured.sessionGeneration)
    }
}
