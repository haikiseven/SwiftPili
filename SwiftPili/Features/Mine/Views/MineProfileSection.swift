import SwiftUI

/// Reads profile publications locally, leaving the retained Mine list stable.
struct MineProfileSection: View {
    let viewModel: MineViewModel
    let isLoggedIn: Bool
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Centered Apple Account–style grouped card over the neutral canvas:
    /// 72pt avatar, centered name with subtle inline chevron, typographic meta,
    /// generous whitespace, and strictly equal-width 3-column centered stats.
    var body: some View {
        Section {
            Group {
                if let user = viewModel.userInfo {
                    Button {
                        coordinator.navigate(to: .userSpace(user.mid))
                    } label: {
                        signedInHeader(for: user)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(user.name))
                    .accessibilityHint(Text("View Personal Space"))
                } else if isLoggedIn {
                    HStack {
                        Spacer()
                        ProgressView()
                            .accessibilityLabel(Text("Loading profile"))
                        Spacer()
                    }
                    .padding(.vertical, AppSpacing.xl)
                } else {
                    NavigationLink {
                        LoginView()
                    } label: {
                        signedOutHeader
                    }
                }
            }
            .id(ScrollTopAnchor.id)
            .listRowBackground(AppFill.card)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: AppSpacing.l, leading: AppSpacing.l, bottom: AppSpacing.s, trailing: AppSpacing.l
            ))

            if isLoggedIn {
                MineStatsRow(viewModel: viewModel)
                    .listRowBackground(AppFill.card)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: AppSpacing.xs, leading: AppSpacing.m, bottom: AppSpacing.m, trailing: AppSpacing.m
                    ))
            }
        }
        .listRowBackground(AppFill.card)
    }

    private func signedInHeader(for user: UserInfo) -> some View {
        VStack(alignment: .center, spacing: AppSpacing.m) {
            AvatarImage(urlString: user.face, size: 72)
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }

            VStack(alignment: .center, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(user.name)
                        .appFont(.profileTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .multilineTextAlignment(.center)

                accountBadgesRow(for: user)
                    .padding(.top, 2)

                if let sign = user.sign?.trimmingCharacters(in: .whitespacesAndNewlines), !sign.isEmpty {
                    Text(sign)
                        .appFont(.messageMeta)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .padding(.vertical, AppSpacing.xs)
    }

    @ViewBuilder
    private func accountBadgesRow(for user: UserInfo) -> some View {
        let rawVipLabel = user.vip?.status == 1 ? user.vip?.label?.text : nil
        let vipLabel = rawVipLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVip = vipLabel.map { !$0.isEmpty } ?? false
        if user.level != nil || hasVip || user.coins != nil {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .center, spacing: 6) {
                    badgeItems(level: user.level, vipLabel: vipLabel, coins: user.coins)
                }
            } else {
                HStack(spacing: 8) {
                    badgeItems(level: user.level, vipLabel: vipLabel, coins: user.coins)
                }
            }
        }
    }

    @ViewBuilder
    private func badgeItems(level: Int?, vipLabel: String?, coins: Double?) -> some View {
        if let level {
            Text("LV\(level)")
                .appFont(.overlayBadge, monospacedDigit: true)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppFill.inset, in: Capsule())
        }
        if let vipLabel, !vipLabel.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "crown.fill")
                    .font(.caption2)
                Text(vipLabel)
            }
            .appFont(.overlayBadge)
            .fontWeight(.semibold)
            .foregroundStyle(Color.biliAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.biliAccent.opacity(0.12), in: Capsule())
        }
        if let coins {
            HStack(spacing: 3) {
                Image(systemName: "b.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(verbatim: MineView.coinText(coins))
                    .appFont(.cardMeta, monospacedDigit: true)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 2)
        }
    }

    private var signedOutHeader: some View {
        HStack(spacing: AppSpacing.l) {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Log In")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Access history, favorites, and more.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .padding(.vertical, AppSpacing.xs)
    }

}

struct MineStatsRow: View {
    let viewModel: MineViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            statItem(count: viewModel.userStat?.following, label: "Following") {
                coordinator.navigate(to: .following(mid: nil))
            }
            statItem(count: viewModel.userStat?.follower, label: "Followers") {
                coordinator.navigate(to: .followers(mid: nil))
            }
            statItem(count: viewModel.userStat?.dynamicCount, label: "Moments")
        }
    }

    @ViewBuilder
    private func statItem(
        count: Int?,
        label: LocalizedStringKey,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = VStack(alignment: .center, spacing: 2) {
            Text(FormatUtils.viewCount(count ?? 0))
                .appFont(.messageTitle, monospacedDigit: true)
                .fontWeight(.semibold)
                // Concrete Color.primary, NOT the hierarchical .primary:
                // inside the tinted Button below the hierarchical style
                // resolves against the tint and stays blue.
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Text(label)
                .appFont(.cardMeta)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44, alignment: .center)

        if let action {
            // .borderless is load-bearing inside a List row: a plain
            // Button makes the WHOLE row the tap target and every button
            // in it fires together.
            Button(action: action) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // Belt and suspenders with Color.primary above: kill the blue
            // tint at the source so the caption's .secondary can't shade
            // toward it either.
            .tint(Color.primary)
            .frame(minWidth: 0, maxWidth: .infinity)
        } else {
            content
        }
    }

}

struct MineQuickAccessSection: View {
    let isLoggedIn: Bool
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let items = MineQuickAccessPolicy.items(isLoggedIn: isLoggedIn)
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: AppSpacing.xs),
            count: max(1, items.count)
        )

        Section {
            if items.count == 1, let item = items.first {
                quickAccessRow(item)
            } else if dynamicTypeSize.isAccessibilitySize || items.count > 4 {
                ForEach(items, id: \.self) { item in
                    quickAccessRow(item)
                }
            } else {
                LazyVGrid(columns: columns, spacing: AppSpacing.s) {
                    ForEach(items, id: \.self) { item in
                        quickButton(icon: item.icon, label: item.label) {
                            coordinator.navigate(to: item.route)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listRowBackground(AppFill.card)
    }

    private func quickAccessRow(_ item: MineQuickAccessItem) -> some View {
        Button {
            coordinator.navigate(to: item.route)
        } label: {
            HStack {
                Label {
                    Text(item.label)
                } icon: {
                    Image(systemName: item.icon)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
    }

    private func quickButton(
        icon: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.biliAccent)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(Color.primary)
        .accessibilityLabel(label)
    }
}
