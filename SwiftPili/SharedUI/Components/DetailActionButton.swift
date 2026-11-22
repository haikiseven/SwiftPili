import SwiftUI

// The detail pages' action row (like, coin, favourite, watch later, share),
// moved out of `VideoDetailView` so bangumi can draw the same controls.
// Bodies are unchanged from the VOD originals.

/// The shared native-capsule shell, so a share menu (a `Menu`, not a
/// `DetailActionButton`) draws the same shape and fill as its siblings.
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

/// One action in a detail page's action row: an icon, a count or caption,
/// and the toggle/count feedback of the app's control language.
struct DetailActionButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    /// The number behind `label`, when it is a count, so it rolls in place.
    var count: Int?
    /// A request this button started elsewhere (a dialog or sheet it opened).
    var externalActionInFlight = false
    var compact = false
    var showsCaption = true
    var accessibilityTitle: LocalizedStringKey?
    let action: () async -> Void
    /// This button's own request is running: only a turn-on during it plays
    /// the bounce/haptic, never a value the page loads later.
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
