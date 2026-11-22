import SwiftUI

/// Moment card header: avatar, author name, timestamp, and optional content-type capsule.
/// The profile tap target covers only the avatar and author identity so the trailing region stays inert.
struct DynamicAuthorRow: View {
    let author: DynamicFeedResult.DynamicItem.DynamicModules.ModuleAuthor
    let contentType: LocalizedStringKey?
    let openProfile: (Int) -> Void

    private let avatarSize: CGFloat = 40
    private let identitySpacing: CGFloat = 10

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedRow
        } else {
            horizontalRow
        }
    }

    private var horizontalRow: some View {
        HStack(alignment: .center, spacing: identitySpacing) {
            profileButton
            Spacer(minLength: 8)
            if let contentType {
                Text(contentType)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppFill.inset, in: Capsule())
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stackedRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            profileButton
            if let contentType {
                Text(contentType)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppFill.inset, in: Capsule())
                    .padding(.leading, author.face == nil ? 0 : avatarSize + identitySpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var profileButton: some View {
        if let mid = author.mid, mid > 0 {
            Button {
                openProfile(mid)
            } label: {
                identity
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(String(format: String(localized: "View profile: %@"), author.name ?? ""))
            )
        } else {
            identity
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: identitySpacing) {
            if let face = author.face {
                AvatarImage(urlString: face, size: avatarSize)
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(author.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let publishedAt = author.pubTs {
                    Text(FormatUtils.timeAgo(from: publishedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(minWidth: 44, minHeight: 40, alignment: .leading)
        .contentShape(Rectangle())
    }
}
