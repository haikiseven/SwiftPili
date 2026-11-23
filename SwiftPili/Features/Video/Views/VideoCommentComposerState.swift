import Observation
import SwiftUI

@MainActor
@Observable
final class VideoCommentComposerState {
    struct Capture {
        let model: VideoDetailViewModel
        let requestedID: VideoID
        let source: VideoDetailViewModel.CommentSource?
        let context: CommentComposerUploadOwner.Context
        let sessionGeneration: UUID
    }

    var text = ""
    var pictures: [ComposedPicture] = []
    var submission = CommentComposerSubmission()
    var replyTarget: CommentResult.CommentItem?
    let presentation = CommentComposerPresentation()
    let focus = CommentComposerFocus()

    @ObservationIgnored var replyCommentSource: VideoDetailViewModel.CommentSource?
    @ObservationIgnored private var sendTask: Task<Void, Never>?

    var isExpanded: Bool {
        get { presentation.isExpanded }
        set { presentation.isExpanded = newValue }
    }

    var isSending: Bool { submission.isSending }

    var hasDraft: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pictures.isEmpty
            || replyTarget != nil
    }

    func capture(model: VideoDetailViewModel, requestedID: VideoID) -> Capture {
        Capture(
            model: model,
            requestedID: requestedID,
            source: model.currentCommentSource,
            context: model.commentComposerContext,
            sessionGeneration: AuthManager.shared.sessionGeneration
        )
    }

    func isCurrent(
        _ captured: Capture,
        isCurrentModelAndVideo: () -> Bool
    ) -> Bool {
        guard let source = captured.source else { return false }
        return isCurrentModelAndVideo()
            && captured.model.hasCommentSource(for: captured.requestedID)
            && captured.model.currentCommentSource == source
            && captured.model.commentComposerContext == captured.context
            && AuthManager.shared.isLoggedIn
            && AuthManager.shared.sessionGeneration == captured.sessionGeneration
    }

    func uploadScope(
        for captured: Capture,
        isCurrentModelAndVideo: @escaping @MainActor () -> Bool
    ) -> CommentComposerUploadScope {
        CommentComposerUploadScope(
            owner: captured.model.commentUpload,
            context: captured.context,
            isCurrent: { [weak self] in
                self?.isCurrent(captured, isCurrentModelAndVideo: isCurrentModelAndVideo) ?? false
            },
            onAdmission: { [weak self] in
                self?.submission.draftDidChange()
            }
        )
    }

    func textBinding(
        for captured: Capture,
        isCurrentModelAndVideo: @escaping @MainActor () -> Bool
    ) -> Binding<String> {
        Binding(
            get: { self.text },
            set: { newText in
                guard self.isCurrent(captured, isCurrentModelAndVideo: isCurrentModelAndVideo) else { return }
                self.updateText(newText)
            }
        )
    }

    func picturesBinding(
        for captured: Capture,
        isCurrentModelAndVideo: @escaping @MainActor () -> Bool
    ) -> Binding<[ComposedPicture]> {
        Binding(
            get: { self.pictures },
            set: { newPictures in
                guard self.isCurrent(captured, isCurrentModelAndVideo: isCurrentModelAndVideo) else { return }
                self.updatePictures(newPictures)
            }
        )
    }

    func updateText(_ newText: String) {
        submission.draftDidChange()
        text = newText
    }

    func updatePictures(_ newPictures: [ComposedPicture]) {
        guard newPictures != pictures else { return }
        submission.draftDidChange()
        pictures = newPictures
    }

    func setReplyTarget(_ target: CommentResult.CommentItem?) {
        if replyTarget?.rpid != target?.rpid { submission.draftDidChange() }
        replyTarget = target
    }

    func beginReply(
        to target: CommentResult.CommentItem,
        aid: Int,
        motion: AppMotionPreferences
    ) {
        if presentation.isExpanded {
            withAnimation(motion.animation(normal: CollapsibleComposer.composerExpandAnimation)) {
                setReplyTarget(target)
            }
        } else {
            setReplyTarget(target)
        }
        PlayerLog.log(
            "[Composer] reply target set rpid=\(target.rpid) "
            + "aid=\(aid)"
        )
        open(motion: motion)
    }

    func cancelReply(
        captured: Capture,
        isCurrentModelAndVideo: () -> Bool,
        motion: AppMotionPreferences
    ) {
        guard isCurrent(captured, isCurrentModelAndVideo: isCurrentModelAndVideo) else { return }
        PlayerLog.log(
            "[Composer] reply target cleared (explicit ✕) "
            + "was rpid=\(replyTarget?.rpid ?? 0)"
        )
        let shouldCollapse = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pictures.isEmpty
        if shouldCollapse {
            setReplyTarget(nil)
            collapse(motion: motion)
        } else {
            withAnimation(motion.animation(normal: CollapsibleComposer.composerCollapseAnimation)) {
                setReplyTarget(nil)
            }
            focus.dismiss()
        }
    }

    func open(motion: AppMotionPreferences) {
        guard !presentation.isExpanded else {
            focus.request()
            return
        }
        PlayerLog.log("[Composer] expanding from launcher")
        // `CommentComposerMorphContainer` owns the expand spring transition on `presentedExpanded`.
        // Setting `isExpanded` directly avoids double-nesting two staggered animations.
        presentation.isExpanded = true
        focus.request()
    }

    func collapse(motion: AppMotionPreferences) {
        focus.dismiss()
        guard presentation.isExpanded else { return }
        PlayerLog.log(
            "[Composer] collapsing to launcher draft=\(hasDraft ? 1 : 0)"
        )
        // `CommentComposerMorphContainer` owns the collapse spring transition on `presentedExpanded`.
        presentation.isExpanded = false
    }

    func collapseImmediatelyIfSourceCleared(_ source: VideoDetailViewModel.CommentSource?) {
        guard source == nil, presentation.isExpanded else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            presentation.isExpanded = false
        }
    }

    func clearDraft(in model: VideoDetailViewModel) {
        updateText("")
        updatePictures([])
        setReplyTarget(nil)
        model.commentDraftWasReplaced()
    }

    func cancelSend() {
        sendTask?.cancel()
    }

    func send(
        model: VideoDetailViewModel,
        requestedVideoID: VideoID,
        isCurrentModelAndVideo: @escaping @MainActor () -> Bool,
        motion: AppMotionPreferences,
        onReveal: @escaping @MainActor (
            _ postedRpid: Int,
            _ target: CommentResult.CommentItem?,
            _ model: VideoDetailViewModel,
            _ sourceIsCurrent: @escaping @MainActor () -> Bool
        ) -> Void
    ) {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty || !pictures.isEmpty,
              !model.commentUpload.isUploading,
              model.hasCommentSource(for: requestedVideoID),
              let aid = model.videoInfo?.aid,
              let attempt = submission.begin() else { return }
        let target = replyTarget
        let attachedPictures = pictures
        let generation = model.commentSourceGeneration
        let sourceIsCurrent: @MainActor () -> Bool = {
            isCurrentModelAndVideo()
                && model.hasCommentSource(for: requestedVideoID)
                && model.videoInfo?.aid == aid
                && model.commentSourceGeneration == generation
        }
        let canApply: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && sourceIsCurrent() && self.submission.canApply(attempt)
        }
        sendTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, sourceIsCurrent() else {
                self.finishSubmission(attempt)
                return
            }
            let postedRpid = await model.postComment(
                message: msg,
                root: target?.rpid,
                parent: target?.rpid,
                pictures: attachedPictures
            )
            self.finishSubmission(attempt)
            guard let postedRpid, canApply() else { return }
            self.clearDraft(in: model)
            self.collapse(motion: motion)
            onReveal(postedRpid, target, model, sourceIsCurrent)
        }
    }

    private func finishSubmission(_ attempt: CommentComposerSubmission.Attempt) {
        if submission.finish(attempt) { sendTask = nil }
    }
}
