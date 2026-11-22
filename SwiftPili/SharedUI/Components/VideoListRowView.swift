import SwiftUI

/// The watched-fraction bar drawn across the bottom edge of a cover.
///
/// It exists because an offline resume point is otherwise invisible — two
/// covers look identical whether or not the user is forty minutes into one.
///
/// It was extracted when the downloads list drew its own copy of it; that list
/// now uses the row below instead, so there is exactly one drawer again. Kept
/// separate anyway: it is framed BY the caller's cover box rather than
/// measuring one, which is a distinct enough contract to state once.
///
/// It is FRAMED by the caller's cover box rather than measuring one: that box
/// comes from the Cover Aspect setting, and a bar sized from the resolved
/// artwork would detach from it the moment the setting is 4:3 (the same rule the
/// row below records for its own box).
struct CoverWatchProgressBar: View {
    /// Watched fraction, 0…1.
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

/// Compact video row for the account's saved lists — watch history,
/// favorite folders and Watch Later all render the same shape: a 110pt-wide
/// cover carrying an optional watch-progress bar and a duration badge,
/// the title and uploader beside it, and a caller-supplied footer line
/// (viewed-at, play/danmaku counts…).
///
/// Distinct from VideoCardView on purpose: that one is the FEED card
/// (size-class-adaptive cover, one fixed metadata line, no progress),
/// this one is the library row.
enum VideoListRowPresentation {
    case standard, favorites
}

struct VideoListRowView<Footer: View>: View {
    /// Both official covers the endpoint gave us; the row never picks one.
    let sources: VideoCoverSources
    let title: String
    /// Uploader line; nil hides it (an empty string still reserves it,
    /// matching the lists that always show an author).
    var subtitle: String?
    /// Pre-formatted length badge ("12:34"); nil hides the badge.
    var durationText: String?
    /// Watched fraction (0…1) drawn across the cover's bottom edge; nil
    /// hides the bar.
    var progress: Double?
    var presentation: VideoListRowPresentation = .standard
    var trailingTitleInset: CGFloat = 0
    @ViewBuilder var footer: () -> Footer

    /// The width is this row's own constant; the height belongs to the
    /// configured Cover Aspect. Both are INSTANCE properties now: the height
    /// is no longer a compile-time number, and the progress bar and badge have
    /// to be framed by the same derived box the cover is, or they detach from
    /// it the moment the setting is 4:3.
    ///
    /// The SETTING, not a per-row resolution against `sources`. A build took the
    /// box from the resolved cover so the chrome would follow a fallback asset's
    /// own official class; that is reverted. Every endpoint this row serves
    /// (history, favourites, watch-later) composes no mobile cover at all, so at
    /// a 4:3 Cover Aspect the artwork here IS a widescreen `pic` in a 4:3 box —
    /// and the progress bar belongs to the box, which is also the artwork's box
    /// because both come from this one number.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.rowCardColumnWidth) private var columnWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 110 on a phone, 140 on a wide window — through the shared metric,
    /// because the downloads screen's in-flight row has to line up with these
    /// and used to carry its own copy of the number.
    private var coverWidth: CGFloat {
        LibraryRowMetrics.coverWidth(
            columnWidth: columnWidth,
            isRegularWidth: sizeClass == .regular
        )
    }
    private var coverHeight: CGFloat {
        CoverPresentationStore.shared.presentation.height(forWidth: coverWidth)
    }

    /// The part of the row's 16pt side inset spent outside the card. Half of
    /// it goes above and below, so stacked bare rows sit one margin apart.
    private static var cardMargin: CGFloat { 8 }

    var body: some View {
        // The policy's gap, not a literal: `LibraryRowMetrics.textWidth`
        // subtracts it, so the invariant and the layout have to read the same
        // number or the test keeps passing while the row stops matching.
        rowLayout {
            coverContent
            textContent
        }
        // The value the invariant subtracts, not `.padding(.horizontal)`'s
        // system-determined amount — `LibraryRowMetrics.textWidth` takes 16 a
        // side, so the row has to spend exactly that: part inside the bare
        // card, the rest outside it as the margin that separates adjacent
        // rows (`LibraryRowLayout` has zero grid spacing; the cells carry it).
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
