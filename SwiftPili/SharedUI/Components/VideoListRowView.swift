import SwiftUI

struct CoverWatchProgressBar: View {
    let progress: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let clamped = progress.isFinite ? min(max(progress, 0), 1) : 0
        let safeWidth = width.isFinite ? max(0, width) : 0
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: safeWidth, height: 3)
            Rectangle()
                .fill(.biliAccent)
                .frame(width: safeWidth * clamped, height: 3)
        }
        .frame(width: safeWidth, height: max(0, height), alignment: .bottomLeading)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail))
    }
}

enum VideoListRowPresentation {
    case standard, favorites
}

struct VideoListRowView<Footer: View>: View {
    let sources: VideoCoverSources
    let title: String
    var subtitle: String?
    var durationText: String?
    var progress: Double?
    var presentation: VideoListRowPresentation = .standard
    var trailingTitleInset: CGFloat = 0
    @ViewBuilder var footer: () -> Footer

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.rowCardColumnWidth) private var columnWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var coverWidth: CGFloat {
        LibraryRowMetrics.coverWidth(
            columnWidth: columnWidth,
            isRegularWidth: sizeClass == .regular
        )
    }
    private var coverHeight: CGFloat {
        CoverPresentationStore.shared.presentation.height(forWidth: coverWidth)
    }

    private static var cardMargin: CGFloat { 8 }

    var body: some View {
        rowLayout {
            coverContent
            textContent
        }
        .padding(.horizontal, LibraryRowMetrics.horizontalInset - Self.cardMargin)
        .padding(.vertical, 8)
        .videoCardSurface()
        .padding(.horizontal, Self.cardMargin)
        .padding(.vertical, Self.cardMargin / 2)
    }

    private var rowLayout: AnyLayout {
        if presentation == .favorites, dynamicTypeSize.isAccessibilitySize {
            return AnyLayout(VStackLayout(alignment: .leading, spacing: RowGeometry.coverToTextSpacing))
        }
        return AnyLayout(HStackLayout(
            alignment: .top,
            spacing: RowGeometry.coverToTextSpacing
        ))
    }

    private var titleLineLimit: Int? {
        guard presentation == .favorites else { return 2 }
        return dynamicTypeSize.isAccessibilitySize ? nil : 2
    }

    private var coverContent: some View {
        ZStack(alignment: .bottomTrailing) {
            VideoCoverImage(sources: sources, width: coverWidth)
                .videoCoverFrame(cornerRadius: AppRadius.thumbnail)

            if let progress {
                CoverWatchProgressBar(
                    progress: progress,
                    width: coverWidth,
                    height: coverHeight
                )
            }

            if let durationText {
                Text(durationText)
                    .appFont(.overlayBadge, monospacedDigit: true)
                    .fontWeight(.medium)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous))
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .appFont(.libraryRowTitle)
                .fontWeight(.medium)
                .lineLimit(titleLineLimit)
                .foregroundStyle(.primary)
                .padding(.trailing, trailingTitleInset)

            Spacer(minLength: 2)

            if let subtitle {
                Text(subtitle)
                    .appFont(.libraryRowMeta)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            footer()
        }
        .frame(maxWidth: .infinity, minHeight: coverHeight, alignment: .leading)
    }
}
