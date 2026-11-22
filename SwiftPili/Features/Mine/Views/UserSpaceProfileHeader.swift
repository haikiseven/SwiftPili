import SwiftUI

struct UserSpaceProfileHeader: View {
    let mid: Int
    let userInfo: UserInfo?
    let showsRelationControls: Bool
    let isBlockedUser: Bool
    let isFollowing: Bool
    let followInFlight: Bool
    let blockInFlight: Bool
    let accentColor: Color
    let following: Int?
    let followers: Int?
    let likes: Int?
    let views: Int?
    let isLoadingStats: Bool
    let onToggleFollow: () -> Void
    let onUnblock: () -> Void
    let openFollowing: () -> Void
    let openFollowers: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppMotion private var motion
    @State private var isDetailsExpanded = false

    private var avatarSize: CGFloat {
        sizeClass == .regular ? 80 : 72
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            identityRow

            bioAndMetadataSection

            if showsRelationControls, isBlockedUser {
                blockedBanner
            }

            UserSpaceStatsBar(
                following: following,
                followers: followers,
                likes: likes,
                views: views,
                isLoading: isLoadingStats,
                openFollowing: openFollowing,
                openFollowers: openFollowers
            )
        }
        .padding(.horizontal, AppSpacing.l)
        .padding(.top, AppSpacing.s)
        .padding(.bottom, AppSpacing.xs)
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: AppSpacing.l) {
            Group {
                if isProfilePlaceholder {
                    AvatarPlaceholder(size: avatarSize)
                } else {
                    AvatarImage(urlString: userInfo?.face ?? "", size: avatarSize)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                }
            }

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(profileName)
                        .appFont(.profileTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .redacted(reason: isProfilePlaceholder ? .placeholder : [])
                        .accessibilityLabel(
                            isProfilePlaceholder ? Text("Loading profile") : Text(verbatim: profileName)
                        )

                    if let tier = verificationTier {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.subheadline)
                            .foregroundStyle(tier == .personal ? Color.orange : Color.blue)
                            .accessibilityLabel(Text("Official Account"))
                    }
                }

                if let officialTitle {
                    Text(officialTitle)
                        .appFont(.cardMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: AppSpacing.s)

            if showsRelationControls, !isBlockedUser {
                followButton
            }
        }
    }

    private var followButton: some View {
        Button(action: onToggleFollow) {
            HStack(spacing: AppSpacing.xs) {
                if !isFollowing {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                }
                (isFollowing ? Text("Following") : Text("Follow"))
                    .appFont(.controlLabel)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .padding(.horizontal, AppSpacing.l)
            .padding(.vertical, AppSpacing.s)
            .background(isFollowing ? AppFill.inset : accentColor, in: Capsule())
            .foregroundStyle(isFollowing ? Color.secondary : Color.white)
            .appStateLabelFeedback(isOn: isFollowing, userActionInFlight: followInFlight)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .disabled(followInFlight)
    }

    @ViewBuilder
    private var bioAndMetadataSection: some View {
        if isProfilePlaceholder {
            ProfileSignPlaceholder()
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if let sign = trimmedSign {
                    Text(sign)
                        .appFont(.rowMeta)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(isDetailsExpanded ? nil : 2)
                }

                if isDetailsExpanded, let summary = secondaryMetadataSummary {
                    Text(verbatim: summary)
                        .appFont(.cardMeta, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }

                Button {
                    withAnimation(motion.animation(normal: .snappy(duration: 0.22, extraBounce: 0))) {
                        isDetailsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Text(isDetailsExpanded ? "Show Less" : "Show More")
                            .contentTransition(.interpolate)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .imageScale(.small)
                            .appDisclosureRotation(isExpanded: isDetailsExpanded)
                            .accessibilityHidden(true)
                    }
                    .appFont(.cardMeta)
                    .fontWeight(.medium)
                    .foregroundStyle(accentColor)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appControl)
                .padding(.vertical, -AppSpacing.s)
            }
            .clipped()
        }
    }

    private var blockedBanner: some View {
        HStack(spacing: AppSpacing.m) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                Text("You've blocked this user")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.red)

            Spacer(minLength: AppSpacing.s)

            Button(action: onUnblock) {
                Text("Unblock User")
                    .appFont(.controlLabel)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                    .padding(.horizontal, AppSpacing.m)
                    .padding(.vertical, 6)
                    .background(AppFill.inset, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
            .disabled(blockInFlight)
        }
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, AppSpacing.xs)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    private var isProfilePlaceholder: Bool { userInfo == nil }

    private var profileName: String {
        userInfo?.name ?? "Placeholder name"
    }

    private var verificationTier: OfficialVerificationTier? {
        userInfo?.official?.verificationTier
    }

    private var officialTitle: String? {
        userInfo?.official?.displayTitle
    }

    private var trimmedSign: String? {
        guard let sign = userInfo?.sign?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sign.isEmpty else { return nil }
        return sign
    }

    private var secondaryMetadataSummary: String? {
        var parts = ["UID \(mid)"]
        if let level = userInfo?.level {
            parts.append("Lv.\(level)")
        }
        if let vip = userInfo?.vip, vip.status == 1,
           let label = vip.label?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            parts.append(label)
        }
        if let ipLocation = userInfo?.ipLocation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ipLocation.isEmpty {
            parts.append("IP \(ipLocation)")
        }
        if let birthday = userInfo?.birthday?.trimmingCharacters(in: .whitespacesAndNewlines),
           !birthday.isEmpty, birthday != "0000-00-00" {
            parts.append(birthday)
        }
        return parts.joined(separator: "  ")
    }
}
