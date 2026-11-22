import SwiftUI

struct HotCommentsPreviewCard: View {
    let comments: [CommentResult.CommentItem]
    let total: Int
    let isLoading: Bool
    let isRegularWidth: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
        let previewComments = Array(comments.prefix(2))
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Top Comments").font(.headline)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Text(FormatUtils.viewCount(total))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .appFont(.cardMeta)
                    .foregroundStyle(.secondary)
                }
                if previewComments.isEmpty {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                            Text("Loading comments…")
                        } else {
                            Text("No Comments Yet")
                        }
                    }
                    .appFont(.cardMeta)
                    .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(previewComments.enumerated()), id: \.element.id) { index, comment in
                            if index > 0 {
                                Divider()
                                    .opacity(0.35)
                                    .padding(.leading, 38)
                            }
                            HStack(alignment: .top, spacing: 10) {
                                AvatarImage(urlString: comment.member.avatar.httpsURL, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(comment.member.uname)
                                        .appFont(.cardMeta)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.primary.opacity(0.90))
                                        .lineLimit(1)
                                    EmoteText(
                                        message: comment.content.displayMessage
                                            .replacingOccurrences(of: "\n", with: " "),
                                        emotes: CommentRowView.emoteMap(comment),
                                        font: .app(AppTypeScale.style(.cardMeta, isRegularWidth: isRegularWidth))
                                    )
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .appCardSurface(in: shape)
    }
}
