import Foundation

// The type scale, out of `AdaptiveLayoutPolicy.swift` and into its own file.
//
// That file had grown to hold two subjects — how wide things are, and how big
// their words are — and crossed SwiftLint's 500-line warning saying so. They
// are read at different times and change for different reasons: a column count
// answers to the window, a text style answers to what the text LABELS.
//
// `import Foundation` only, exactly as the other half is, because that is what
// lets both tables be executed off-device rather than read.

/// What a piece of text LABELS, so the size it takes can differ by context.
///
/// The defect these name: a grid card's cover is the column, so it grew from
/// 173pt on an iPhone to between 229 and 330 on an iPad, while its title stayed
/// at the system's 15pt and its metadata at 12 — the type scale is the same on
/// both devices. The image nearly doubled and the words did not, which reads as
/// "the font is too small" even though no font changed.
///
/// A role rather than a remapped style, because the answer is not one ladder.
/// A grid card's title has the whole column to wrap in, so it can afford 20pt.
/// A ROW card's title shares its line with the cover and has 180–330pt to work
/// with, where the same 20pt would cost a line of title before it bought any
/// legibility. Two surfaces, two answers, one table.
enum AppTextRole: CaseIterable {
    /// Title under a cover that fills its column — `GridVideoCardView`.
    case cardTitle
    /// Uploader and play count under that title.
    case cardMeta
    /// Title under a cover that fills a NARROWER column — `LiveCardView`, whose
    /// grid is denser than the video one (four columns where video gets three,
    /// so ~239pt a card against ~322) and whose title is one line with no
    /// second to absorb an overflow. The step a grid card can afford would
    /// strictly remove characters here.
    case narrowCardTitle
    /// Streamer and category on that card, which share one line.
    case narrowCardMeta
    /// Title beside a cover — `VideoCardView`, the feed's row layout.
    case rowTitle
    /// The one metadata line that card carries.
    case rowMeta
    /// Title beside the library's smaller cover — `VideoListRowView`, which
    /// history, favourites, Watch Later and downloads all draw.
    case libraryRowTitle
    /// Uploader, or the quality/size pair, on that row.
    case libraryRowMeta
    /// The tertiary line at the bottom of a library row — watched-at, play and
    /// danmaku counts. It is the least important text in the row and stays the
    /// smallest, but it stops being 11pt beside a 17pt title.
    case libraryRowFooter
    /// Title under a SHELF card, which is 128–176pt rather than a whole column
    /// — `FavoritesView`'s folder previews. It grows because the card does, and
    /// by less than a grid card's, because it has a sixth of the width to wrap
    /// in.
    case shelfCardTitle
    /// The title of the video a screen is ABOUT — `VideoDetailView`'s own
    /// heading, not a card pointing at it.
    case screenTitle
    /// The same title on the cinematic iPad landscape detail page, where it is
    /// set as an editorial headline under a large player rather than as a row
    /// heading.
    case editorialTitle
    /// That video's uploader, beside the follow button.
    case screenOwner
    /// Its description: secondary, collapsed to two lines until tapped.
    case screenSummary
    /// Plays, danmaku, when it was posted.
    case screenStat
    /// The name above a comment.
    case commentAuthor
    /// The comment itself — the densest text in the app, and the one place
    /// where the picture beside the words is an inline emote cut from the
    /// font's own metrics, so growing the type grows the stickers with it.
    case commentBody
    /// IP location and timestamp on a comment's name line.
    case commentMeta
    /// Like, and "view all N replies".
    case commentAction
    /// Drawn ON the artwork: duration, viewer count. It is chrome on an image
    /// and grows the least — it has to stay out of the picture's way.
    case overlayBadge
    /// A section heading inside a list or settings-like surface.
    case sectionTitle
    /// A profile or user-space identity heading.
    case profileTitle
    /// A conversation, notification, or message-row title.
    case messageTitle
    /// A message preview or chat body.
    case messageBody
    /// Timestamp, count, and secondary message metadata.
    case messageMeta
    /// A user-facing control label that is not a screen title.
    case controlLabel
}

/// The system text styles this app uses, mirrored so the table below can live
/// in a Foundation-only file and be executed rather than read.
///
/// Deliberately NOT `Font.TextStyle`: importing SwiftUI here would cost the
/// executable test, and the mapping to a real font is one switch in
/// `FeedWidth.swift`.
enum AppTextStyle {
    case title1, title2, title3, headline, body, callout, subheadline, footnote, caption, caption2

    /// The size iOS draws this style at with Dynamic Type at its default (Large).
    ///
    /// The BASE size, which is what a `UIFontMetrics` scaler is handed and
    /// what `EmoteTextFont` already stores — so building a font from it is the
    /// intended use. Framing anything from it is not: Dynamic Type moves every
    /// one of these, and a box cut from the number would stay put while the
    /// text inside it grew.
    ///
    /// It is also what lets the table assert "regular is never smaller than
    /// compact" as a statement about sizes rather than about enum cases.
    var nominalPointSize: CGFloat {
        switch self {
        case .title1: 28
        case .title2: 22
        case .title3: 20
        // Semibold at the same size as `.body`, which is why a screen heading
        // can sit at 17 on a phone and still read as the heading.
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        }
    }
}

/// The type scale, by role and by how much room the window has.
enum AppTypeScale {
    /// The style a role takes.
    ///
    /// The compact column reproduces, exactly, the style each component already
    /// declared — that is the regression gate, and `everyRoleKeepsItsCompactStyle`
    /// holds it. Only the regular column is new.
    ///
    /// 2026-09-28: the regular column was stepped down one notch across the
    /// board at the user's request ("字号给小一点") — on an iPad the first
    /// ladder read as oversized. Its floor is the phone's size, so a role whose
    /// phone style was already one step below its iPad one now matches the
    /// phone; the hierarchy inside each surface is unchanged.
    ///
    /// ⚠️ The input is the SIZE CLASS, not a measured width, and that is a
    /// departure from `FeedColumnPolicy` on purpose. Columns needed width
    /// because `.regular` spans 678 to 1366pt, where the right count differs.
    /// Type does not have that problem: every `.regular` width draws covers of
    /// 229pt and up, and every `.compact` one draws 200 and under, so one
    /// answer per class fits. The known consequence is a Max/Plus iPhone in
    /// LANDSCAPE, which reports `.regular` at 956pt — it takes the larger type,
    /// and it is also already taking the larger cover (`VideoCardView` has
    /// keyed its 220pt cover off the same class since before this table). The
    /// two agreeing is the point; a phone drawing 300pt covers under 15pt
    /// titles has the same defect an iPad does.
    static func style(_ role: AppTextRole, isRegularWidth: Bool) -> AppTextStyle {
        switch role {
        case .cardTitle:
            // The full column to wrap in, under a cover of 229–330pt.
            isRegularWidth ? .body : .subheadline
        case .cardMeta:
            isRegularWidth ? .footnote : .caption
        case .narrowCardTitle:
            isRegularWidth ? .subheadline : .subheadline
        case .narrowCardMeta:
            isRegularWidth ? .caption : .caption
        case .rowTitle:
            // One gentle step. The cover takes 220 of the row and the title
            // gets what is left, so the size that helps a grid card would cost
            // this one a line of title.
            isRegularWidth ? .callout : .callout
        case .rowMeta:
            isRegularWidth ? .footnote : .footnote
        case .libraryRowTitle:
            isRegularWidth ? .callout : .subheadline
        case .libraryRowMeta:
            isRegularWidth ? .caption : .caption
        case .libraryRowFooter:
            isRegularWidth ? .caption2 : .caption2
        case .shelfCardTitle:
            isRegularWidth ? .caption : .caption2
        case .screenTitle:
            // The top of the scale. Everything that points AT this video —
            // a feed card's title, a comment under it — has to stay below it,
            // and on a wide window it did not: the card that opened the screen
            // drew its title at 20 while the screen itself drew 17.
            isRegularWidth ? .title3 : .headline
        case .editorialTitle:
            isRegularWidth ? .title1 : .title2
        case .screenOwner:
            isRegularWidth ? .callout : .subheadline
        case .screenSummary:
            isRegularWidth ? .footnote : .caption
        case .screenStat:
            isRegularWidth ? .caption : .caption
        case .commentAuthor:
            isRegularWidth ? .callout : .subheadline
        case .commentBody:
            isRegularWidth ? .callout : .subheadline
        case .commentMeta:
            isRegularWidth ? .caption2 : .caption2
        case .commentAction:
            isRegularWidth ? .footnote : .footnote
        case .overlayBadge:
            isRegularWidth ? .caption2 : .caption2
        case .sectionTitle:
            isRegularWidth ? .headline : .headline
        case .profileTitle:
            isRegularWidth ? .title3 : .title3
        case .messageTitle:
            isRegularWidth ? .callout : .subheadline
        case .messageBody:
            isRegularWidth ? .callout : .subheadline
        case .messageMeta:
            isRegularWidth ? .caption2 : .caption2
        case .controlLabel:
            isRegularWidth ? .subheadline : .footnote
        }
    }
}

/// The one comment size that is not a system text style.
///
/// A sub-reply preview is drawn one point below the comment body it hangs
/// under — 14 against the body's 15 — which no system style expresses. Keeping
/// it here rather than as a literal in the view is what makes the RELATIONSHIP
/// testable: whatever the body does at a given width, the sub-reply stays one
/// point under it, so the two can never drift apart by a step.
enum CommentMetrics {
    static func subReplyPointSize(isRegularWidth: Bool) -> CGFloat {
        AppTypeScale.style(.commentBody, isRegularWidth: isRegularWidth).nominalPointSize - 1
    }
}
