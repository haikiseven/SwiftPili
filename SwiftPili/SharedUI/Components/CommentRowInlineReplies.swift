import SwiftUI

struct CommentInlineRepliesSection: View {
    let comment: CommentResult.CommentItem
    let previews: ArraySlice<CommentResult.CommentItem>
    let upMid: Int?
    let isRegularWidth: Bool
    var onViewThread: ((CommentResult.CommentItem) -> Void)?
    var onOpenReply: ((CommentResult.CommentItem, Int) -> Void)?

    @MainActor
    static func replyPreviews(
        for comment: CommentResult.CommentItem,
        upMid: Int?
    ) -> ArraySlice<CommentResult.CommentItem> {
        let replies = comment.replies ?? []
        let engine = CommentAIFilterEngine.shared
        guard engine.isEnabled, engine.config.mode == .hideCompletely else {
            return replies.prefix(3)
        }
        var visible: [CommentResult.CommentItem] = []
        visible.reserveCapacity(min(3, replies.count))
        for sub in replies where !engine.shouldHide(sub, upMid: upMid) {
            visible.append(sub)
            if visible.count == 3 { break }
        }
        return visible[...]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(previews) { sub in
                subReplyRow(sub)
            }

            if let onViewThread {
                Button {
                    onViewThread(comment)
                } label: {
                    HStack(spacing: 3) {
                        if comment.rcount == 1 {
                            Text("1 reply")
                        } else {
                            Text("\(comment.rcount) replies")
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .imageScale(.small)
                            .fontWeight(.semibold)
                    }
                    .appFont(.commentAction)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.biliAccent)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appControl)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            shape
                .fill(AppFill.nested)
                .contentShape(shape)
                .onTapGesture {
                    onViewThread?(comment)
                }
        }
        .padding(.top, 5)
    }

    @ViewBuilder
    private func subReplyRow(_ sub: CommentResult.CommentItem) -> some View {
        if BlocklistManager.shared.isBlocked(sub.mid) {
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                Text("Comment from a blocked user")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else if CommentAIFilterEngine.shared.config.mode == .autoCollapse,
                  let assessment = CommentAIFilterEngine.shared.assessment(for: sub, upMid: upMid),
                  assessment.matches(CommentAIFilterEngine.shared.config) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                Text("Suspected AI reply collapsed")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpenReply?(comment, sub.rpid) }
        } else {
            subReplyBody(sub)
        }
    }

    private func subReplyBody(_ sub: CommentResult.CommentItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            EmoteText(
                message: sub.content.displayMessage,
                emotes: CommentRowView.emoteMap(sub),
                links: sub.content.resolvedLinks,
                font: CommentRowView.subReplyFont(isRegularWidth: isRegularWidth),
                detectTimestamps: true,
                leadingText: subReplyAuthorPrefix(sub)
            )
            .lineSpacing(1.5)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .linkAwareTap(isEnabled: onOpenReply != nil) {
                onOpenReply?(comment, sub.rpid)
            }

            if let vote = sub.content.vote, let voteId = vote.id {
                VoteCardView(voteId: voteId, initialTitle: vote.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subReplyAuthorPrefix(_ sub: CommentResult.CommentItem) -> Text {
        let authorFont = CommentRowView.subReplyFont(isRegularWidth: isRegularWidth).weighted(.medium).swiftUIFont
        let name = Text(sub.member.uname)
            .font(authorFont)
            .foregroundStyle(Color.primary.opacity(0.88))
        let colon = Text("：")
            .font(authorFont)
            .foregroundStyle(.secondary)
        let base = sub.mid == upMid ? name + UPBadge.inlineText : name
        let engine = CommentAIFilterEngine.shared
        if engine.config.mode == .badgeOnly,
           let assessment = engine.assessment(for: sub, upMid: upMid),
           assessment.matches(engine.config) {
            let aiTag = Text(verbatim: " [AI]")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            return base + aiTag + colon
        }
        return base + colon
    }
}
