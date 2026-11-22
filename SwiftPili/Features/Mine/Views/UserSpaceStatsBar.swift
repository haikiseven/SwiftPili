import SwiftUI

/// Borderless creator statistics row (following / followers / total likes / views).
///
/// Counts mask at their rendered size only while `isLoading` is true; once settled,
/// an absent count reads `"0"` so a failed or missing stat never stays redacted.
struct UserSpaceStatsBar: View {
    let following: Int?
    let followers: Int?
    let likes: Int?
    var views: Int?
    let isLoading: Bool
    let openFollowing: () -> Void
    let openFollowers: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            statsRow(spacing: AppSpacing.xl)
            statsRow(spacing: AppSpacing.l)
            statsRow(spacing: AppSpacing.m)
        }
    }

    private func statsRow(spacing: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            statItem(count: following, label: "FollowingStat", action: openFollowing)
            statItem(count: followers, label: "Followers", action: openFollowers)
            statItem(count: likes, label: "Total Likes")
            if let views, views > 0 {
                statItem(count: views, label: "Views")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statItem(count: Int?, label: LocalizedStringKey, action: (() -> Void)? = nil) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(FormatUtils.viewCount(count ?? 0))
                .appFont(.messageTitle, monospacedDigit: true)
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .redacted(reason: count == nil && isLoading ? .placeholder : [])
            Text(label)
                .appFont(.cardMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)

        if let action {
            Button(action: action) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
        } else {
            content
        }
    }
}

/// Apple Music / Podcasts style section header (`Title ›`) for Creator Home shelves in `UserSpaceView`.
struct UserSpaceSectionHeader: View {
    let title: LocalizedStringKey
    var count: Int?
    let onSeeMore: () -> Void

    var body: some View {
        Button(action: onSeeMore) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text(title)
                    .appFont(.sectionTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.primary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer(minLength: AppSpacing.s)
                if let count, count > 0 {
                    Text(FormatUtils.viewCount(count))
                        .appFont(.cardMeta, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
    }
}
