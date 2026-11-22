import SwiftUI

/// The single page-level section-switch style shared by Home, Live, Dynamics,
/// User Space and Search result types: text tabs with a short accent-colored
/// underline capsule that slides to the selected item (one
/// `matchedGeometryEffect` indicator per bar instance). This look was Home's
/// `HomeSectionPillBar` originally; every other page-level section switch now
/// renders through this component instead of its own capsule/segmented style.
///
/// Visual contract (do not vary silently): `.callout` text, bold when selected
/// / medium otherwise, primary/secondary foreground, an 18×3pt underline
/// filled with `AccentStore.shared.badgeFill`, animated with a snappy 0.2s
/// transition gated by `@AppMotion`/Reduce Motion. `itemSpacing` defaults to
/// Home's 20pt but stays overridable so an existing adopter with a different
/// measured gap (Live's 18pt) can reuse the component without a layout shift.
struct SectionTabBar<ID: Hashable>: View {
    /// A structural tab description. Selection is the caller's own state
    /// machine (equality, a derived mode, whatever) expressed as a bool per
    /// item — this is what lets a mode like Dynamics' "Following People"
    /// (selected for a whole family of underlying values, not one exact
    /// value) share this component instead of re-deriving its own tab row.
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
    /// Wrap the row in a horizontally scrolling container for item counts
    /// that can overflow the available width (Live's areas, User Space's up
    /// to 7 tabs, Dynamics' filters). Leave `false` for a small fixed set
    /// that should hug its content (Home, Search result types).
    var isScrollable = false
    /// Plays the selection haptic on a user pick only; a programmatic
    /// selection change (e.g. a reset back to a default tab) stays silent.
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

    /// Convenience for the common case: one item per `Hashable` value,
    /// selected by equality.
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
            // The visible text+underline assembly above keeps its own
            // measured size; this only grows the invisible tap zone around
            // it to the HIG-recommended 44pt minimum.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .id(item.id)
    }
}
