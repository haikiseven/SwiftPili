import SwiftUI

struct ClipboardLinkBanner: View {
    let suggestion: ClipboardLinkSuggestion
    let accent: Color
    var showsSurface = true
    let open: () -> Void
    let dismiss: () -> Void

    private var describedTarget: String {
        switch suggestion.target {
        case .music: String(localized: "Music from your clipboard")
        case .video: String(localized: "Video from your clipboard")
        case .liveRoom: String(localized: "Live room from your clipboard")
        case .userSpace: String(localized: "Profile from your clipboard")
        case .moment: String(localized: "Moment from your clipboard")
        case .article: String(localized: "Article from your clipboard")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .foregroundStyle(accent)
            Text(describedTarget)
                .font(.footnote)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: open) {
                Text("Open")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.appControl)
            .foregroundStyle(accent)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingControlSurface(Capsule(), enabled: showsSurface)
    }
}
