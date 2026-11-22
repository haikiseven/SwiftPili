import SwiftUI

struct PlaybackEntryChip<Badge: View>: View {
    static var cornerRadius: CGFloat { AppRadius.control }
    static var width: CGFloat { 148 }

    let label: String
    var detail: String?
    let title: String
    let isSelected: Bool
    var indicator: Namespace.ID?
    let action: () -> Void
    @ViewBuilder var badge: () -> Badge
    @AppMotion private var motion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if isSelected {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    }
                    Text(label)
                        .appFont(.controlLabel)
                        .fontWeight(.semibold)
                    if let detail {
                        Text(detail)
                            .appFont(.messageMeta)
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                    }
                    badge()
                }
                Text(title.isEmpty ? " " : title)
                    .appFont(.messageMeta)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.biliAccent) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: Self.width, alignment: .leading)
            .frame(minHeight: 44)
            .background { fill(shape) }
            .foregroundStyle(isSelected ? AnyShapeStyle(.biliAccent) : AnyShapeStyle(.primary))
            .contentShape(.interaction, shape)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
        }
        .buttonStyle(.appControl)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func fill(_ shape: RoundedRectangle) -> some View {
        Group {
            if isSelected {
                if let indicator {
                    shape.fill(Color.biliAccent.opacity(0.14))
                        .matchedGeometryEffect(id: "selected", in: indicator)
                } else {
                    shape.fill(Color.biliAccent.opacity(0.14))
                }
            } else {
                shape.fill(AppFill.inset)
            }
        }
        .animation(motion.animation(normal: .snappy(duration: 0.24)), value: isSelected)
    }
}

extension PlaybackEntryChip where Badge == EmptyView {
    init(
        label: String, detail: String? = nil, title: String, isSelected: Bool,
        indicator: Namespace.ID? = nil, action: @escaping () -> Void
    ) {
        self.init(
            label: label, detail: detail, title: title, isSelected: isSelected,
            indicator: indicator, action: action, badge: { EmptyView() }
        )
    }
}
