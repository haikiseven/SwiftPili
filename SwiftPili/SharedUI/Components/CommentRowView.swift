import SwiftUI

struct CommentRowView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    let comment: CommentResult.CommentItem
    var upMid: Int?
    var showsInlineReplies = true
    var bypassContentFilter = false
    var onReply: ((CommentResult.CommentItem) -> Void)?
    var onViewThread: ((CommentResult.CommentItem) -> Void)?
    var onOpenReply: ((CommentResult.CommentItem, Int) -> Void)?
    var onImageTap: ((ImagePreviewItem) -> Void)?
    var onAvatarTap: ((Int) -> Void)?
    var onDelete: (() -> Void)?

    @Environment(AppCoordinator.self) private var coordinator
    @State private var actionState = CommentActionState()

    var isRegularWidth: Bool { sizeClass == .regular }

    private func openProfile(_ mid: Int) {
        guard mid > 0 else { return }
        if let onAvatarTap {
            onAvatarTap(mid)
        } else {
            coordinator.navigate(to: .userSpace(mid))
        }
    }

    var body: some View {
        let _ = actionState.syncReplyHandler(onReply)
        ContentFilterCommentRowContainer(comment: comment, bypass: bypassContentFilter) {
            CommentAIFilterRowContainer(comment: comment, upMid: upMid) { aiAssessment, onInspectAI in
                commentBody(aiAssessment: aiAssessment, onInspectAI: onInspectAI)
            }
        }
    }

    private func commentBody(
        aiAssessment: CommentAIAssessment?,
        onInspectAI: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarImage(urlString: comment.member.avatar.httpsURL, size: 36)
                .contentShape(Circle())
                .onTapGesture { openProfile(comment.mid) }

            VStack(alignment: .leading, spacing: 3) {
                CommentAuthorHeader(
                    comment: comment,
                    upMid: upMid,
                    showsPinned: true,
                    actionState: actionState,
                    onDelete: onDelete,
                    aiAssessment: aiAssessment,
                    onInspectAI: onInspectAI
                )

                EmoteText(
                    message: comment.content.displayMessage,
                    emotes: Self.emoteMap(comment),
                    links: comment.content.resolvedLinks,
                    font: .app(AppTypeScale.style(.commentBody, isRegularWidth: isRegularWidth)),
                    collapsedLineLimit: 6,
                    detectTimestamps: true
                )
                .lineSpacing(2)
                .commentContextActions(comment, state: actionState, onReply: onReply, onDelete: onDelete)
                .modifier(TapToReply(action: onReply.map { act in { act(comment) } }))
                .padding(.top, 1)
                .padding(.bottom, 2)

                if comment.upAction?.like == true {
                    UPLikedTag()
                }

                if let vote = comment.content.vote, let voteId = vote.id {
                    VoteCardView(voteId: voteId, initialTitle: vote.title)
                }

                let media = Self.mediaItems(comment)
                if !media.isEmpty {
                    commentImages(media)
                }

                if let note = comment.content.richText?.note {
                    NoteLinkChip(note: note)
                }

                CommentVideoTitleChip(message: comment.content.displayMessage)

                actionRow

                if showsInlineReplies, comment.rcount > 0 {
                    let previews = CommentInlineRepliesSection.replyPreviews(for: comment, upMid: upMid)
                    if !previews.isEmpty || onViewThread != nil {
                        CommentInlineRepliesSection(
                            comment: comment,
                            previews: previews,
                            upMid: upMid,
                            isRegularWidth: isRegularWidth,
                            onViewThread: onViewThread,
                            onOpenReply: onOpenReply
                        )
                    }
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 20) {
            CommentLikeButton(comment: comment, state: actionState)
            CommentDislikeButton(comment: comment, state: actionState)
            if let onReply {
                CommentReplyActionButton {
                    onReply(comment)
                }
            }
            Spacer()
        }
    }

    private func commentImages(_ media: [MediaGridView.Media]) -> some View {
        let innerColumnWidth = envColumnWidth.flatMap { $0 > 48 ? $0 - 48 : nil }
        let gridMaxWidth = innerColumnWidth.map { min(CommentMediaMetrics.maxWidth, $0) }
            ?? CommentMediaMetrics.maxWidth
        return MediaGridView(
            media: media,
            layout: .comment,
            maxWidth: gridMaxWidth,
            sourceID: "comment:\(comment.rpid)"
        ) { item in
            onImageTap?(item)
        }
        .rowCardColumnWidth(innerColumnWidth)
        .padding(.top, 4)
    }

    static func mediaItems(_ comment: CommentResult.CommentItem) -> [MediaGridView.Media] {
        if let pictures = comment.content.pictures, !pictures.isEmpty {
            return pictures.compactMap { pic -> MediaGridView.Media? in
                guard !pic.imgSrc.isEmpty, let url = URL(string: pic.imgSrc.httpsURL) else { return nil }
                var size: CGSize?
                if let w = pic.imgWidth, let h = pic.imgHeight, w > 0, h > 0 {
                    size = CGSize(width: w, height: h)
                }
                return MediaGridView.Media(url: url, pixelSize: size)
            }
        }
        return (comment.content.richText?.note?.images ?? []).compactMap { src in
            guard !src.isEmpty else { return nil }
            return URL(string: src.httpsURL).map { MediaGridView.Media(url: $0) }
        }
    }

    static func subReplyFont(isRegularWidth: Bool) -> EmoteTextFont {
        .points(
            CommentMetrics.subReplyPointSize(isRegularWidth: isRegularWidth),
            relativeTo: AppTypeScale.style(.commentBody, isRegularWidth: isRegularWidth).uiTextStyle
        )
    }

    static func emoteMap(_ comment: CommentResult.CommentItem) -> [String: String] {
        comment.content.emoteURLs
    }
}
