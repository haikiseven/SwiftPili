import SwiftUI

struct SectionTabBar<ID: Hashable>: View {
    struct Item {
        let id: ID
        let label: Text
        let isSelected: Bool
        let action: () -> Void

        init(id: ID, label: Text, isSelected: Bool, action: @escaping () -> Void) {
            self.id = id
            self.label = label
            self.isSelected = isSelected
            self.action = action
        }
    }

    let items: [Item]
    var isScrollable = false
    var enablesSelectionHaptic = false
    var itemSpacing: CGFloat = 20

    @AppMotion private var motion
    @State private var userPicks = 0
    @Namespace private var indicator

    init(
        items: [Item],
        isScrollable: Bool = false,
        enablesSelectionHaptic: Bool = false,
        itemSpacing: CGFloat = 20
    ) {
        self.items = items
        self.isScrollable = isScrollable
        self.enablesSelectionHaptic = enablesSelectionHaptic
        self.itemSpacing = itemSpacing
    }

    init(
        values: [ID],
        selection: ID,
        isScrollable: Bool = false,
        enablesSelectionHaptic: Bool = false,
        itemSpacing: CGFloat = 20,
        label: @escaping (ID) -> Text,
        onSelect: @escaping (ID) -> Void
    ) {
        self.items = values.map { value in
            Item(
                id: value,
                label: label(value),
                isSelected: value == selection,
                action: { onSelect(value) }
            )
        }
        self.isScrollable = isScrollable
        self.enablesSelectionHaptic = enablesSelectionHaptic
        self.itemSpacing = itemSpacing
    }

    private var activeID: ID? {
        items.first(where: \.isSelected)?.id
    }

    var body: some View {
        Group {
            if isScrollable {
                ScrollView(.horizontal, showsIndicators: false) {
                    row
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else {
                row
            }
        }
        .appSelectionHaptic(userPicks: userPicks)
    }

    private var row: some View {
        HStack(spacing: itemSpacing) {
            ForEach(items, id: \.id) { item in
                tabButton(item)
            }
        }
        .background {
            if let activeID {
                Capsule()
                    .fill(AccentStore.shared.badgeFill)
                    .matchedGeometryEffect(id: activeID, in: indicator, isSource: false)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .animation(motion.animation(normal: .snappy(duration: 0.2, extraBounce: 0)), value: activeID)
            }
        }
        .padding(.horizontal, 4)
    }

    private func tabButton(_ item: Item) -> some View {
        Button {
            guard !item.isSelected else { return }
            if enablesSelectionHaptic { userPicks &+= 1 }
            item.action()
        } label: {
            VStack(spacing: 5) {
                item.label
                    .font(.callout.weight(.bold))
                    .lineLimit(1)
                    .hidden()
                    .overlay {
                        item.label
                            .font(.callout.weight(item.isSelected ? .bold : .medium))
                            .foregroundStyle(item.isSelected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                Color.clear
                    .frame(width: 18, height: 3)
                    .matchedGeometryEffect(id: item.id, in: indicator)
            }
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .id(item.id)
    }
}
