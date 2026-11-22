import SwiftUI

// Chrome of the detail pages' comment surfaces (the compact overlay and the
// iPad stage panel), shared by the video and bangumi pages. Moved out of
// `VideoDetailView` unchanged.

/// A round glass control in a comment surface's header (close, back). Its
/// region is published to the comment Zoom so the native transition keeps the
/// control out of its interactive dismissal area.
struct CommentHeaderCircleButton: View {
    let systemName: String
    let accessibilityLabel: LocalizedStringKey
    let anchors: CommentZoomAnchors
    let role: CommentZoomRegion.Role
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background {
                    if !reduceTransparency, #available(iOS 26.0, *) {
                        Circle()
                            .fill(.clear)
                            .glassEffect(.regular.interactive(), in: Circle())
                    } else {
                        Circle()
                            .fill(AppFill.inset)
                            .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.appControl)
        .contentShape(.interaction, Circle().inset(by: -4))
        .background(
            CommentZoomRegion(anchors: anchors, role: role)
                .padding(-4)
        )
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// The header of an in-place reply thread: back to the list, the title, and —
/// on the compact overlay, which has a grabber — close for the whole surface.
struct CommentThreadHeader: View {
    let isWideLayout: Bool
    let anchors: CommentZoomAnchors
    let onBack: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isWideLayout {
                Capsule()
                    .fill(.secondary.opacity(0.6))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                CommentHeaderCircleButton(
                    systemName: "chevron.left",
                    accessibilityLabel: "Back",
                    anchors: anchors,
                    role: .backControl,
                    action: onBack
                )
                Text("Thread")
                    .appFont(.sectionTitle)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !isWideLayout {
                    CommentHeaderCircleButton(
                        systemName: "xmark",
                        accessibilityLabel: "Close comments",
                        anchors: anchors,
                        role: .closeControl,
                        action: onClose
                    )
                }
            }
            .padding(.horizontal, isWideLayout ? 18 : 16)
            .padding(.top, isWideLayout ? 10 : 0)
            .padding(.bottom, isWideLayout ? 8 : 6)
            Divider()
                .opacity(0.35)
        }
        .frame(minHeight: isWideLayout ? 52 : 54)
        .contentShape(Rectangle())
        .background(CommentZoomRegion(anchors: anchors, role: .header))
    }
}
