import SwiftUI

/// The width a feed lays out in, measured from the feed itself.
///
/// `FeedColumnPolicy` answers in terms of the width INSIDE a feed's own
/// padding, and the only honest way to get that number is to ask the view that
/// has it. Subtracting a padding constant at the call site would reintroduce
/// exactly what the policy was extracted to remove: a second copy of a layout
/// number, kept in sync by hand, silently wrong the first time someone changes
/// `.padding()` to `.padding(20)`.
///
/// `measuringContentWidth` therefore goes on the grid or stack **before** its
/// padding modifier, so what it reports is the content width by construction:
///
/// ```swift
/// LazyVGrid(columns: columns, spacing: 16) { … }
///     .measuringContentWidth(into: $contentWidth)
///     .padding()
/// ```
///
/// This does not feed back on itself. A `LazyVGrid` takes the width it is
/// proposed whatever its column count is, so the measurement that chooses the
/// count is not changed by the count it chooses.
extension View {
    func measuringContentWidth(into width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { measured in
            guard measured > 0, abs(width.wrappedValue - measured) > 0.5 else { return }
            width.wrappedValue = measured
        }
    }
}

/// The surfaces a settings screen can sit on, because capping a list means
/// painting what shows up beside it.
enum FormSurface {
    /// `List` / `Form` in their default grouped presentation.
    case grouped
    /// An explicit `.listStyle(.plain)` screen.
    case plain
    /// A tab-level browsing page (Mine, Settings) on the shared ambient browse
    /// backdrop: the list's own background is hidden and the backdrop runs
    /// under the whole page, so the gutters cannot show a different colour.
    case ambientBrowse
}

extension View {
    /// Hold a settings list to a readable column and centre it.
    ///
    /// The gutters are not empty space: a capped `List` keeps drawing its own
    /// background, so without painting the same colour behind the full width
    /// the page would show two vertical stripes of the WRONG system colour
    /// either side of the list — which is why this takes the surface rather
    /// than defaulting to one. The background ignores the safe area so the
    /// colour runs under the navigation bar and the home indicator, where the
    /// list's own background already does.
    ///
    /// The width cap is inert on every iPhone and on an iPad form sheet, both
    /// of which are narrower than it; `.ambientBrowse` still paints its
    /// backdrop there.
    @ViewBuilder
    func readableFormWidth(_ surface: FormSurface = .ambientBrowse) -> some View {
        switch surface {
        case .grouped:
            readableFormColumn()
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
        case .plain:
            readableFormColumn()
                .background(Color(.systemBackground).ignoresSafeArea())
        case .ambientBrowse:
            scrollContentBackground(.hidden)
                .readableFormColumn()
                .appAmbientBrowseBackground()
                // `scrollContentBackground(.hidden)` opts the list out of the
                // system grouped-table chrome that would otherwise carry its
                // own bottom content inset, and the floating/minimised iOS 26
                // tab bar (`glassTabBarBehaviour()` in `RootView`) sits ABOVE
                // this page's own safe area rather than shrinking it — so the
                // last row of every settings-style list drew underneath the
                // pill/circles at full scroll. A plain spacer in the list's
                // own safe-area inset (rather than a hard-coded trailing
                // padding on List content, which would show inside the
                // scrollable area instead of past it) reserves exactly the
                // room the floating bar occupies, regardless of which
                // settings screen is scrolled to its end.
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: SettingsScaffoldingMetrics.floatingTabBarClearance)
                }
        }
    }

    private func readableFormColumn() -> some View {
        frame(maxWidth: ReadableWidth.form)
            .frame(maxWidth: .infinity)
    }
}

/// Extra clearance an `.ambientBrowse` list reserves below its last row, past
/// what the system's own safe area already accounts for.
enum SettingsScaffoldingMetrics {
    /// Sized to clear the iOS 26 floating tab bar in both its full and
    /// minimised (scrolled-down) states, with the same margin
    /// `appBottomChrome`'s pre-26 fallback uses for the plain tab bar (58pt) —
    /// generous rather than exact, since under-reserving is the visible bug
    /// (the last row drawing under the pill) and a few extra points of empty
    /// space at the end of a settings list is not.
    static let floatingTabBarClearance: CGFloat = 58
}

enum FeedWidth {
    /// The horizontal padding the feeds use, counted on both sides.
    ///
    /// Used ONLY to seed the first frame — the measurement replaces it. It is
    /// `.padding()`'s 16 a side, and if a feed ever uses something else the
    /// seed is a few points off for one frame and correct thereafter, which is
    /// the whole reason the real number is measured instead of declared.
    private static let nominalPadding: CGFloat = 32

    /// What to start a feed's `contentWidth` at, before geometry has been read.
    ///
    /// Zero would be honest and unusable: `FeedColumnPolicy` answers 1 column
    /// for a degenerate width, so an iPhone would draw one column for the first
    /// frame and reflow to two. The app's own window — not `UIScreen`, which
    /// reports the display and not the Split View or Stage Manager window the
    /// app was given — is right for every full-width feed, which is all of them
    /// today, and wrong by a bounded amount for one frame otherwise.
    @MainActor
    static var seed: CGFloat {
        max(0, windowWidth - nominalPadding)
    }

    /// The seed for a measurer that spans its CONTAINER rather than sitting
    /// inside a feed's padding — `LibraryRowLayout` and the downloads screen
    /// both measure the full width, because the insets they care about belong
    /// to the rows rather than to the list.
    ///
    /// Seeding those with `seed` put the two 32pt apart, which is invisible
    /// until a breakpoint falls in the gap: a 700pt window seeded 668 (one
    /// column) and measured 700 (two), so the screen laid out once and then
    /// relaid on appear — and on the downloads screen, where the count also
    /// picks the container, that first frame was a whole different tree.
    @MainActor
    static var fullContainerSeed: CGFloat {
        windowWidth
    }

    /// The container-width seed for a component inside a CAPPED column.
    ///
    /// Same convention as `fullContainerSeed` — the container, not the width
    /// inside a feed's padding — because that is what a component converting
    /// with its own insets expects. Handing it `seed`'s content convention
    /// instead made the seed 32pt short, which is a card-size step inside the
    /// bands where a breakpoint falls in that gap.
    ///
    /// ⚠️ Only a caller that IS inside the cap may use it, and that rule cost a
    /// regression to learn: a component that capped its own seed fixed the
    /// profile page by breaking Mine → Favourites, whose list has no cap, so
    /// the row seeded 728, measured 1334, and the skeleton jump simply moved.
    /// A component cannot know whether its container is capped — the container
    /// knows, so the container passes it.
    @MainActor
    static func fullContainerSeed(cappedTo limit: CGFloat) -> CGFloat {
        min(fullContainerSeed, max(0, limit))
    }

    /// The window, read live.
    ///
    /// A process-lifetime cache was tried here and reverted the same day: it
    /// removed a `connectedScenes` walk per view init and paid for it with a
    /// value that is WRONG after the first resize, which is worse — a screen
    /// that picks its container from this number would then build the launch
    /// window's tree on every navigation for the rest of the process. The walk
    /// stays; what went away instead is calling it per ROW (see
    /// `FavoriteFolderPreviewRow`, which now takes its seed from the list that
    /// contains it and knows whether that list is capped).
    ///
    /// One read, not two: the probe is the expensive part, so it is bound
    /// rather than tested and then repeated.
    @MainActor
    private static var windowWidth: CGFloat {
        if let frame = AppWindowMetrics.frameInScreen { return frame.width }
        // No window yet (previews, early launch, a scene being torn down). The
        // SCREEN is not the window on iPad, so this is a last resort and is
        // deliberately not remembered.
        return UIScreen.main.bounds.width
    }
}

/// A library list — history, favourites, Watch Later, downloads — laid into as
/// many columns as its width affords.
///
/// The four screens were four copies of `LazyVStack(spacing: 0) { ForEach … }`
/// and on iPad they failed in two opposite directions at once: favourites and
/// downloads were capped at `ReadableWidth.feed` and drew a 760pt ribbon down
/// the middle of a 1366pt window, while history and Watch Later were capped at
/// nothing and stretched a single 110pt cover across the whole of it. A reading
/// measure is the right answer for a column of TEXT; these rows are a cover
/// with text beside it, so the answer is the one the home feed already uses —
/// more columns, not more stretch.
///
/// `.videoRow` is that table, unchanged: one column below 680pt, two below
/// 1250, three above. An iPhone therefore renders exactly what it rendered
/// before — one column, zero row spacing, each row carrying its own insets.
///
/// One `LazyVGrid` rather than a grid/stack branch, deliberately: changing the
/// column count is a layout change, whereas swapping the container type is an
/// identity change, and a window dragged across a breakpoint would throw the
/// list back to the top.
///
/// The measurement is the grid's own width, which INCLUDES the 16pt a side
/// `VideoListRowView` carries internally — the feed grids measure inside their
/// own `.padding()` instead, so the two read the same policy 32pt apart. That
/// gap applies at EVERY breakpoint, not just the first: the bands where the two
/// conventions disagree are [680, 712) and [1250, 1282). No real device width
/// lands in either, and only Stage Manager can produce one at all — but the
/// rule is "32pt at every step", not "one band near 680".
struct LibraryRowLayout<Content: View>: View {
    @State private var contentWidth: CGFloat = FeedWidth.fullContainerSeed
    @ViewBuilder var content: () -> Content

    /// Zero, and the cells carry their own insets — `VideoListRowView` has
    /// 16pt a side. Named so `columnWidth` can be told rather than assume.
    ///
    /// Computed, not `static let`: this type is generic, and Swift rejects a
    /// static STORED property in a generic type outright. `swiftc -parse` does
    /// not see it — the diagnostic is Sema's — so the file parsed clean while
    /// the app target would not have built at all.
    private static var columnSpacing: CGFloat { 0 }

    private var columns: [GridItem] {
        let count = FeedColumnPolicy.columnCount(.videoRow, availableWidth: contentWidth)
        return Array(
            repeating: GridItem(.flexible(), spacing: Self.columnSpacing, alignment: .top),
            count: count
        )
    }

    /// What one cell gets. Through the shared derivation, which takes the
    /// spacing rather than assuming it: this grid uses zero, and the version
    /// that hard-coded `contentWidth / count` was right only by that accident
    /// while its doc claimed to account for the gaps.
    private var columnWidth: CGFloat {
        FeedColumnPolicy.columnWidth(
            availableWidth: contentWidth,
            count: columns.count,
            spacing: Self.columnSpacing
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            content()
        }
        .measuringContentWidth(into: $contentWidth)
        .rowCardColumnWidth(columnWidth)
    }
}

/// The width of the column a row card is being laid out in, published by the
/// container that knows it.
///
/// An environment value and not a parameter: fourteen call sites build these
/// cards across eight files, and only the handful of CONTAINERS can answer the
/// question. `nil` — every call site that has not been taught — resolves to the
/// constant the cards used before, so an un-taught site renders exactly as it
/// did rather than guessing.
private struct RowCardColumnWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var rowCardColumnWidth: CGFloat? {
        get { self[RowCardColumnWidthKey.self] }
        set { self[RowCardColumnWidthKey.self] = newValue }
    }
}

/// Resolves the published column width AT THE ROW'S OWN POSITION.
///
/// `@Environment` belongs to the view struct that declares it, so a screen-level
/// property reads the value where the SCREEN sits — above the container that
/// publishes it — and gets nil. That is not theoretical: the downloads screen's
/// in-flight row computed its cover from a screen-level property and drew it
/// 17pt wider than the completed rows beneath it, which is the exact stepping
/// at the section break the shared metric exists to prevent.
struct RowCardColumnWidthReader<Content: View>: View {
    @Environment(\.rowCardColumnWidth) private var columnWidth
    @ViewBuilder var content: (CGFloat?) -> Content

    var body: some View {
        content(columnWidth)
    }
}

extension View {
    /// Tell the row cards inside this container how wide their column is.
    ///
    /// The width INSIDE the container's own padding and net of the grid's
    /// inter-column spacing — the number a single card actually gets — because
    /// that is what the cover has to fit into beside its text.
    func rowCardColumnWidth(_ width: CGFloat?) -> some View {
        environment(\.rowCardColumnWidth, width)
    }
}

/// The bridge from `AppTextStyle` to a real font. The only place SwiftUI and
/// the type table meet.
extension Font {
    static func app(_ style: AppTextStyle) -> Font {
        switch style {
        case .title1: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let role: AppTextRole
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = Font.app(AppTypeScale.style(role, isRegularWidth: sizeClass == .regular))
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// Size this text by what it LABELS rather than by a style name, so a wide
    /// window can give it the room the artwork beside it already took.
    ///
    /// It sets a `Font`, so `.fontWeight()` and `.foregroundStyle()` still
    /// apply after it exactly as they did after `.font(.subheadline)`. What it
    /// does NOT return is a `Text`, so a call site that concatenates with `+`
    /// has to keep its own `.font`.
    ///
    /// `monospacedDigit` is a parameter rather than a modifier the call site
    /// chains afterwards, and that is not a convenience. `.appFont()` sets the
    /// font INSIDE itself, so a `.monospacedDigit()` written after it lands
    /// outside and is overwritten by the font it is meant to vary — a duration
    /// badge would silently lose its fixed-width digits and jitter as the clock
    /// ticks. Taken here, it varies the `Font` before the modifier applies it.
    func appFont(_ role: AppTextRole, monospacedDigit: Bool = false) -> some View {
        modifier(AppFontModifier(role: role, monospacedDigit: monospacedDigit))
    }
}
