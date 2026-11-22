import SwiftUI

/// Layout-shaped placeholder for a moment card while the first page loads
/// (HIG Loading: show placeholder content, replace it as content arrives).
///
/// Mirrors `DynamicCardView`'s chrome — the 16pt inset, the 22pt grouped
/// background — and `DynamicAuthorRow`'s 40pt avatar, semibold body name and
/// footnote timestamp, so the first real cards land where these sat. Static on
/// purpose: no shimmer or loop, nothing hit-testable, and no image request (the
/// avatar is a plain circle). `.redacted(reason: .placeholder)` masks the text
/// at its original size and shape.
struct DynamicCardPlaceholder: View {
    var showsCardBackground = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color.imagePlaceholder)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Placeholder name")
                        .font(.body.weight(.semibold))
                    Text(verbatim: "Placeholder")
                        .font(.footnote)
                }
            }
            Text(verbatim: "Placeholder text for a moment that is still loading from the server, "
                + "long enough to wrap onto a third line on a phone.")
                .font(.body)
                .lineLimit(3, reservesSpace: true)
            // Every real feed card ends in its repost/comment/like row: three
            // 44pt-tall subheadline buttons with 2pt above (`DynamicCardView`).
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    Text(verbatim: "000")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if showsCardBackground {
                Color.clear
                    .appCardSurface(in: RoundedRectangle(cornerRadius: AppRadius.panel))
            }
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}

/// A few placeholder cards as one VoiceOver element.
struct DynamicFeedPlaceholder: View {
    var count = 3
    var spacing: CGFloat = 12
    var showsCardBackground = true

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { _ in
                DynamicCardPlaceholder(showsCardBackground: showsCardBackground)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading moments"))
    }
}

/// Lightweight geometric placeholder rows matching `VideoCardView` height without
/// compiling 6 `.redacted(reason: .placeholder)` shader masks on mount.
struct VideoCardPlaceholderList: View {
    var count = 6
    var spacing: CGFloat = 12
    let accessibilityLabel: String

    private var coverWidth: CGFloat { RowCardMetrics.compactCoverWidth }
    private var coverHeight: CGFloat {
        CoverPresentationStore.shared.presentation.height(forWidth: coverWidth)
    }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: RowGeometry.coverToTextSpacing) {
                    RoundedRectangle(cornerRadius: VideoCardMetrics.cornerRadius, style: .continuous)
                        .fill(Color.imagePlaceholder)
                        .frame(width: coverWidth, height: coverHeight)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                            .fill(Color.imagePlaceholder)
                            .frame(height: 15)
                        RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                            .fill(Color.imagePlaceholder)
                            .frame(width: 140, height: 15)
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                            .fill(Color.imagePlaceholder.opacity(0.65))
                            .frame(width: 96, height: 12)
                    }
                    .padding(.vertical, 6)
                    Spacer(minLength: 0)
                }
                .frame(height: coverHeight)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }
}

/// Lightweight geometric placeholder cells matching `GridVideoCardView` inside a `LazyVGrid`.
struct VideoCardPlaceholderGrid: View {
    var count = 6
    let accessibilityLabel: String

    private var aspectRatio: CGFloat {
        CoverPresentationStore.shared.presentation.aspect.ratio
    }

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                RoundedRectangle(cornerRadius: VideoCardMetrics.cornerRadius, style: .continuous)
                    .fill(Color.imagePlaceholder)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                    .fill(Color.imagePlaceholder)
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                    .fill(Color.imagePlaceholder.opacity(0.65))
                    .frame(width: 96, height: 12)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityLabel))
            .accessibilityHidden(index > 0)
        }
    }
}

/// Lightweight geometric placeholder cells matching `LiveCardView` inside a `LazyVGrid`.
struct LiveCardPlaceholderGrid: View {
    var count: Int
    let accessibilityLabel: String

    init(count: Int = 8, accessibilityLabel: String) {
        self.count = count
        self.accessibilityLabel = accessibilityLabel
    }

    private var aspectRatio: CGFloat {
        CoverPresentationStore.shared.presentation.aspect.ratio
    }

    var body: some View {
        ForEach(0..<max(0, count), id: \.self) { index in
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: VideoCardMetrics.cornerRadius, style: .continuous)
                    .fill(Color.imagePlaceholder)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                        .fill(Color.imagePlaceholder)
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                        .fill(Color.imagePlaceholder.opacity(0.65))
                        .frame(width: 110, height: 12)
                }
                .padding(.top, 6)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityLabel))
            .accessibilityHidden(index > 0)
        }
    }
}

/// Lightweight static placeholder rows for user, following, and simple list states.
struct SimpleRowPlaceholderList: View {
    var count: Int
    var spacing: CGFloat
    var showsAvatar: Bool
    var avatarSize: CGFloat
    var avatarCornerRadius: CGFloat?
    var cardBackground: Bool
    let accessibilityLabel: String

    init(
        count: Int = 6,
        spacing: CGFloat = 12,
        showsAvatar: Bool = true,
        avatarSize: CGFloat = 44,
        avatarCornerRadius: CGFloat? = nil,
        cardBackground: Bool = false,
        accessibilityLabel: String
    ) {
        self.count = count
        self.spacing = spacing
        self.showsAvatar = showsAvatar
        self.avatarSize = avatarSize
        self.avatarCornerRadius = avatarCornerRadius
        self.cardBackground = cardBackground
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<max(0, count), id: \.self) { _ in
                row
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private var row: some View {
        HStack(spacing: AppSpacing.m) {
            if showsAvatar {
                avatarShape
                    .frame(width: avatarSize, height: avatarSize)
            }
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                    .fill(Color.imagePlaceholder)
                    .frame(maxWidth: 180)
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                    .fill(Color.imagePlaceholder.opacity(0.65))
                    .frame(maxWidth: 96)
                    .frame(height: 12)
            }
            Spacer(minLength: 0)
        }
        .padding(cardBackground ? AppSpacing.m : 0)
        .background {
            if cardBackground {
                Color.clear
                    .appCardSurface(in: RoundedRectangle(cornerRadius: AppRadius.card))
            }
        }
    }

    @ViewBuilder
    private var avatarShape: some View {
        if let avatarCornerRadius {
            RoundedRectangle(cornerRadius: avatarCornerRadius, style: .continuous)
                .fill(Color.imagePlaceholder)
        } else {
            Circle()
                .fill(Color.imagePlaceholder)
        }
    }
}

/// One redacted line where a profile's signature will sit, matching
/// `UserSpaceView`'s sign text role and leading alignment. Hidden from VoiceOver; the name
/// placeholder announces the loading profile.
struct ProfileSignPlaceholder: View {
    var body: some View {
        Text(verbatim: "Placeholder signature line")
            .appFont(.rowMeta)
            .foregroundStyle(.secondary)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
    }
}

/// The avatar's circle while there is no URL yet: no image request, no
/// loading indicator, same size as the `AvatarImage` it stands in for.
struct AvatarPlaceholder: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color.imagePlaceholder)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
