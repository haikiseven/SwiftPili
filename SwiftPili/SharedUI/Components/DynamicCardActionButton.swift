import SwiftUI

struct DynamicCardActionButton: View {
    let icon: String
    let name: LocalizedStringKey
    let count: Int
    var isActive = false
    let action: (() -> Void)?

    @State private var taps = 0

    var body: some View {
        Button {
            taps &+= 1
            action?()
        } label: {
            HStack(spacing: 5) {
                glyph
                title.appCountFeedback(value: count)
            }
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(isActive ? Color.biliAccent : Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                isActive ? Color.biliAccent.opacity(0.14) : AppFill.nested,
                in: Capsule()
            )
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .appToggleHaptic(isOn: isActive, userTaps: taps)
        .disabled(action == nil)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(FormatUtils.viewCount(count)))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var glyph: some View {
        Image(systemName: icon)
            .appToggleFeedback(isOn: isActive, userTaps: taps, playsHaptic: false)
    }

    private var title: Text {
        if count >= 1 {
            return Text(verbatim: FormatUtils.viewCount(count))
        }
        return Text(name)
    }
}

struct DynamicActionBar: View {
    let item: DynamicFeedResult.DynamicItem
    let fallbackLikeState: (liked: Bool, count: Int)
    let interactionStore: MomentInteractionStore?
    let onRepost, onComment, onLike: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            DynamicCardActionButton(
                icon: "arrow.2.squarepath", name: "Repost",
                count: item.modules?.moduleStat?.forward?.count ?? 0, action: onRepost
            )
            DynamicCardActionButton(
                icon: "bubble.right", name: "Comment",
                count: item.modules?.moduleStat?.comment?.count ?? 0, action: onComment
            )
            DynamicLikeActionButton(
                item: item, fallbackLikeState: fallbackLikeState,
                interactionStore: interactionStore, onLike: onLike
            )
        }
    }
}

private struct DynamicLikeActionButton: View {
    let item: DynamicFeedResult.DynamicItem
    let fallbackLikeState: (liked: Bool, count: Int)
    let interactionStore: MomentInteractionStore?
    let onLike: (() -> Void)?

    var body: some View {
        let state = interactionStore?.likeState(for: item) ?? fallbackLikeState
        let action = onLike ?? interactionStore.map { store in { Task { await store.toggleLike(for: item) } } }
        DynamicCardActionButton(
            icon: state.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
            name: "Like", count: state.count, isActive: state.liked, action: action
        )
    }
}
