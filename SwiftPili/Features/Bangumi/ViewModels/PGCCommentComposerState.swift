import Foundation
import Observation

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
        draftDidChange()
        replacementEpoch &+= 1
        upload.retire()
        text = ""
        pictures = []
        replyTarget = nil
    }
}
