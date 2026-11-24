import SwiftUI

enum UserSpaceTab: String, CaseIterable {
    case home = "Home"
    case dynamic = "Moments"
    case video = "Submissions"
    case favorite = "Favorites"
    case coins = "Recent Coins"
    case likes = "Recent Likes"
    case bangumi = "Anime"
}

struct UserSpaceTabSelector: View {
    let tabs: [UserSpaceTab]
    @Binding var selection: UserSpaceTab
    var horizontalPadding: CGFloat = AppSpacing.l

    var body: some View {
        VStack(spacing: 0) {
            SectionTabBar(
                values: tabs,
                selection: selection,
                isScrollable: true,
                enablesSelectionHaptic: true,
                label: { Text(LocalizedStringKey($0.rawValue)) },
                onSelect: { selection = $0 }
            )
            .padding(.horizontal, horizontalPadding)

            Divider()
                .opacity(0.28)
        }
    }
}

struct UserSpaceSubmissionFilter: View {
    @Binding var showsArticles: Bool

    @AppMotion private var motion
    @State private var userPicks = 0
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: AppSpacing.s) {
            chip(Text("Videos"), isArticles: false, active: !showsArticles) { select(articles: false) }
            chip(Text("Articles"), isArticles: true, active: showsArticles) { select(articles: true) }
            Spacer()
        }
        .background {
            Capsule()
                .fill(Color.biliAccent.opacity(0.14))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.biliAccent.opacity(0.24), lineWidth: AppStroke.hairlineWidth)
                )
                .matchedGeometryEffect(id: showsArticles, in: indicator, isSource: false)
                .animation(motion.animation(normal: .snappy(duration: 0.2, extraBounce: 0)), value: showsArticles)
        }
        .appSelectionHaptic(userPicks: userPicks)
    }

    private func chip(_ label: Text, isArticles: Bool, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .hidden()
                .overlay {
                    label
                        .font(.footnote.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? AnyShapeStyle(.biliAccent) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .padding(.horizontal, AppSpacing.m)
                .padding(.vertical, 6)
                .matchedGeometryEffect(id: isArticles, in: indicator)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func select(articles: Bool) {
        guard showsArticles != articles else { return }
        userPicks &+= 1
        showsArticles = articles
    }
}
