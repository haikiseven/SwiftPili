import Foundation
import Observation

/// One synchronous owner for PGC draft replacement and accepted POST cleanup.
@MainActor
@Observable
final class PGCCommentComposerState {
    let identifier = UUID()
    var text = ""
    var pictures: [ComposedPicture] = []
    var replyTarget: CommentResult.CommentItem?
    var submission = CommentComposerSubmission()
    var acceptedClear: CommentComposerUploadOwner.Context?
    private(set) var replacementEpoch: UInt64 = 0
    let upload = CommentComposerUploadOwner()

    func draftDidChange() {
        submission.draftDidChange()
        acceptedClear = nil
    }

    func replaceWithEmptyDraft() {
        // Preserve an active POST slot; only its matching finish may release it.
        draftDidChange()
        replacementEpoch &+= 1
        upload.retire()
        text = ""
        pictures = []
        replyTarget = nil
    }
}
