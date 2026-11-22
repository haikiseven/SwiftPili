import SwiftUI

struct DetailActionButtonLabel<Icon: View, Caption: View>: View {
    var compact = false
    var compactIconOnly = false
    var isActive = false
    @ViewBuilder let icon: Icon
    @ViewBuilder let caption: Caption

    var body: some View {
        Group {
            if compact && compactIconOnly {
                icon
                    .padding(.horizontal, 10)
                    .frame(minWidth: 38, minHeight: 34)
                    .fixedSize(horizontal: true, vertical: false)
            } else if compact {
                HStack(spacing: 4) {
                    icon
                    caption
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 34)
            } else {
                HStack(spacing: 6) { icon; caption }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
            }
        }
        .background(
            isActive
                ? AnyShapeStyle(Color.biliAccent.opacity(0.14))
                : AnyShapeStyle(AppFill.inset),
            in: Capsule()
        )
        .contentShape(Capsule())
    }
}

struct DetailActionButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    var count: Int?
    var externalActionInFlight = false
    var compact = false
    var showsCaption = true
    var accessibilityTitle: LocalizedStringKey?
    let action: () async -> Void
    @State private var actionInFlight = false

    var body: some View {
        Button {
            Task {
                actionInFlight = true
                await action()
                actionInFlight = false
            }
        } label: {
            DetailActionButtonLabel(
                compact: compact,
                compactIconOnly: !showsCaption,
                isActive: isActive
            ) {
                Image(systemName: icon)
                    .font(compact ? .subheadline : .body)
                    .foregroundStyle(isActive ? .biliAccent : .primary)
                    .appToggleFeedback(isOn: isActive, userActionInFlight: actionInFlight || externalActionInFlight)
            } caption: {
                if showsCaption {
                    Text(label)
                        .font(compact ? .footnote : .subheadline)
                        .fontWeight(.medium)
                        .appCountFeedback(value: count ?? 0)
                }
            }
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text(accessibilityTitle ?? LocalizedStringKey(label)))
        .accessibilityValue(count.map { Text($0, format: .number) } ?? Text(""))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
