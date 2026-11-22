import SwiftUI

/// Comment ordering: BiliBili's classic sort param (verified live —
/// sort=1 returns like-descending; sort=0 is time, login-gated).
enum CommentSort: String, CaseIterable {
    case top, latest

    var apiValue: Int { self == .top ? 1 : 0 }
    var label: String {
        self == .top ? String(localized: "Top") : String(localized: "Latest")
    }
}

/// Top is like-ranked and Latest is time-ranked; both are server-side sorts.
/// Callers use the two-segment `CommentSortPill` at normal text sizes and fall
/// back to a menu `Picker` at accessibility Dynamic Type sizes.
struct CommentSortBar: View {
    let selection: CommentSort
    let onSelect: (CommentSort) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// User picks only: a sort restored after a failed request stays silent.
    @State private var userPicks = 0

    var body: some View {
        content.appSelectionHaptic(userPicks: userPicks)
    }

    @ViewBuilder
    private var content: some View {
        if dynamicTypeSize.isAccessibilitySize {
            picker
                .pickerStyle(.menu)
        } else {
            CommentSortPill(selection: selection, onSelect: onSelect)
        }
    }

    private var picker: some View {
        Picker("Comment Sort", selection: Binding(
            get: { selection },
            set: { sort in
                if sort != selection { userPicks &+= 1 }
                onSelect(sort)
            }
        )) {
            ForEach(CommentSort.allCases, id: \.self) { sort in
                Text(sort.label).tag(sort)
            }
        }
    }
}

/// Two-segment capsule ("Top | Latest") with both options visible at once.
/// Uses a single `matchedGeometryEffect` indicator per namespace so the active
/// capsule slides smoothly between options.
struct CommentSortPill: View {
    let selection: CommentSort
    let onSelect: (CommentSort) -> Void

    /// The page's surface decides the look: glass over a cinematic page, a
    /// filled capsule on a standard one.
    @Environment(\.appSurface) private var surface
    @AppMotion private var motion
    @State private var userPicks = 0
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CommentSort.allCases, id: \.self) { sort in
                segment(for: sort)
            }
        }
        .background {
            Capsule()
                .fill(
                    isCinematic
                        ? AnyShapeStyle(Color.white.opacity(0.18))
                        : AnyShapeStyle(Color(.secondarySystemGroupedBackground))
                )
                .matchedGeometryEffect(id: selection, in: indicator, isSource: false)
                .animation(motion.animation(normal: .snappy(duration: 0.2, extraBounce: 0)), value: selection)
        }
        .padding(2.5)
        .frame(minHeight: 30)
        .background {
            Capsule()
                .fill(
                    isCinematic
                        ? AnyShapeStyle(Color.white.opacity(0.08))
                        : AnyShapeStyle(Color(.quaternarySystemFill))
                )
        }
        .appSelectionHaptic(userPicks: userPicks)
    }

    private var isCinematic: Bool { surface == .cinematic }

    private func segment(for sort: CommentSort) -> some View {
        let isSelected = selection == sort
        return Button {
            guard sort != selection else { return }
            userPicks &+= 1
            onSelect(sort)
        } label: {
            Text(sort.label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .hidden()
                .overlay {
                    Text(sort.label)
                        .font(.footnote.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 26)
                .matchedGeometryEffect(id: sort, in: indicator)
                .contentShape(Capsule())
        }
        .buttonStyle(.appControl)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
