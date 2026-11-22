import SwiftUI

/// User-selected video cover presentation aspect, owning both preferred official variant selection and card frame ratio.
/// Surfaces whose frame is not a cover card (e.g. `PortraitPagerCoverBackdrop`, 3:4 PGC posters, square media grids) opt out of both halves.
enum CoverAspect: String, CaseIterable, Identifiable, Sendable {
    /// Widescreen cover (`pic`) — default because every video endpoint supplies it.
    case sixteenByNine = "16_9"
    /// Mobile-composed 4:3 cover (`cover43` / `pic_4_3`) where available; frame remains 4:3 on fallback.
    case fourByThree = "4_3"

    static let storageKey = "cover_aspect"

    static var current: CoverAspect {
        get {
            let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
            return CoverAspect(rawValue: raw) ?? .sixteenByNine
        }
        // Nonisolated setter; settings callers invoke `CoverPresentationStore.shared.reload()`.
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    var id: String { rawValue }

    var ratio: CGFloat {
        switch self {
        case .sixteenByNine: 16.0 / 9.0
        case .fourByThree: 4.0 / 3.0
        }
    }

    /// Official ratio bounds used by `CoverRequestHeadroom` so aspect-fitted CDN responses cover the frame without client upscaling.
    static let narrowestOfficialRatio: CGFloat = allCases.map(\.ratio).min() ?? 1
    static let widestOfficialRatio: CGFloat = allCases.map(\.ratio).max() ?? 1

    var label: String {
        switch self {
        case .sixteenByNine: "16:9"
        case .fourByThree: "4:3"
        }
    }

    var icon: String {
        switch self {
        case .sixteenByNine: "rectangle.ratio.16.to.9"
        case .fourByThree: "rectangle.ratio.4.to.3"
        }
    }
}

/// Resolves mismatches when the delivered cover bitmap differs from the selected `CoverAspect` frame.
/// Never alters URL selection; when bitmap and frame match (`CoverFrameAgreement.match`), `.fill` and `.entire` render identically.
enum CoverDisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// Scales to fill the selected frame and clips excess on the client without requesting a CDN `_1c` crop.
    case fill
    /// Fits the entire bitmap inside the selected frame over a neutral letterbox ground.
    case entire

    static let storageKey = "cover_display_mode"

    static var current: CoverDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
            return CoverDisplayMode(rawValue: raw) ?? .fill
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fill: String(localized: "Fill")
        case .entire: String(localized: "Show Entire Image")
        }
    }

    var icon: String {
        switch self {
        case .fill: "arrow.up.left.and.arrow.down.right"
        case .entire: "arrow.down.right.and.arrow.up.left"
        }
    }
}

/// Enlarges `.fill` cover request boxes along one axis so BiliBili's aspect-fit `@<W>w_<H>h` CDN delivery covers the drawn frame at 1.0x scale.
enum CoverRequestHeadroom: Equatable, Sendable {
    /// Uses the drawn box directly (for non-cover surfaces such as square media tiles, 3:4 posters, and backdrops).
    case none
    /// Guarantees coverage across `CoverAspect.narrowestOfficialRatio...widestOfficialRatio`.
    case officialCoverAspects

    /// Returns a covering request box preserving `requested`'s resolution, rounded up so minimum pixel bounds are never rounded down.
    func box(_ requested: CGSize, drawnBox drawn: CGSize) -> CGSize {
        guard self == .officialCoverAspects,
              drawn.width > 1, drawn.height > 1,
              requested.width > 1, requested.height > 1,
              drawn.width.isFinite, drawn.height.isFinite,
              requested.width.isFinite, requested.height.isFinite
        else { return requested }
        let scale = max(1, requested.width / drawn.width, requested.height / drawn.height)
        let width = drawn.width * scale
        let height = drawn.height * scale
        return CGSize(
            width: max(width, height * CoverAspect.widestOfficialRatio).rounded(.up),
            height: max(height, width / CoverAspect.narrowestOfficialRatio).rounded(.up)
        )
    }
}

/// Classifies server-provided cover URLs by API field provenance without synthesizing variants or inspecting pixels.
enum VideoCoverSources: Equatable, Sendable {
    case officialPair(widescreen: String, fourByThree: String)
    case officialWidescreen(String)
    case officialFourByThree(String)
    /// Single asset with no declared aspect class (e.g. live room cover artwork).
    case officialUnclassified(String)
    case absent

    init(widescreen: String, fourByThree: String? = nil) {
        let wide = Self.usable(widescreen)
        let narrow = Self.usable(fourByThree)
        switch (wide, narrow) {
        case (let wide?, let narrow?): self = .officialPair(widescreen: wide, fourByThree: narrow)
        case (let wide?, nil): self = .officialWidescreen(wide)
        case (nil, let narrow?): self = .officialFourByThree(narrow)
        case (nil, nil): self = .absent
        }
    }

    static func singleUnclassified(_ url: String) -> Self {
        guard let url = usable(url) else { return .absent }
        return .officialUnclassified(url)
    }

    private static func usable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// Model-derived provenance relation between the selected cover URL and the target `CoverAspect` frame.
/// Reported alongside pixel-measured `CoverFrameAgreement` in diagnostics.
enum CoverSourceFrameRelation: String, Equatable, Sendable {
    case authored
    case officialFallback
    case unclassified
    case absent
}

/// Pixel-measured agreement between a delivered bitmap's aspect and its drawn frame (diagnostic report only, never a layout input).
enum CoverFrameAgreement: String, Equatable, Sendable {
    case match
    case mismatch
    /// Server-cropped (`_1c`) or degenerate boxes cannot reveal the underlying source aspect when they match the frame.
    case unmeasurable

    /// Absorbs whole-point frame rounding (`±0.5pt`) and pixel quantization (`±0.5px`) across 80–500pt cover widths.
    static let toleranceInPoints: CGFloat = 1

    static func measured(bitmap: CGSize, frame: CGSize, serverCropped: Bool) -> Self {
        guard bitmap.width > 0, bitmap.height > 0, frame.width > 0, frame.height > 0,
              bitmap.width.isFinite, bitmap.height.isFinite,
              frame.width.isFinite, frame.height.isFinite
        else { return .unmeasurable }
        let bitmapRatio = bitmap.width / bitmap.height
        let impliedHeight = frame.width / bitmapRatio
        let agrees = abs(frame.height - impliedHeight) <= toleranceInPoints
        if serverCropped { return agrees ? .unmeasurable : .mismatch }
        return agrees ? .match : .mismatch
    }
}

/// Single authoritative policy for video and live-grid cover source selection, frame aspect, and content mode.
/// Frame geometry always follows `aspect` unconditionally without layout-time fallback heuristics or CDN `_1c` crops.
struct CoverPresentation: Equatable, Sendable {
    var aspect: CoverAspect
    var display: CoverDisplayMode

    init(aspect: CoverAspect, display: CoverDisplayMode) {
        self.aspect = aspect
        self.display = display
    }

    func url(for sources: VideoCoverSources) -> String {
        switch sources {
        case .officialPair(let widescreen, let fourByThree):
            switch aspect {
            case .sixteenByNine: return widescreen
            case .fourByThree: return fourByThree
            }
        case .officialWidescreen(let url),
             .officialFourByThree(let url),
             .officialUnclassified(let url):
            return url
        case .absent:
            return ""
        }
    }

    func relation(for sources: VideoCoverSources) -> CoverSourceFrameRelation {
        switch sources {
        case .officialPair:
            return .authored
        case .officialWidescreen:
            return aspect == .sixteenByNine ? .authored : .officialFallback
        case .officialFourByThree:
            return aspect == .fourByThree ? .authored : .officialFallback
        case .officialUnclassified:
            return .unclassified
        case .absent:
            return .absent
        }
    }

    var contentMode: SwiftUI.ContentMode {
        switch display {
        case .fill: .fill
        case .entire: .fit
        }
    }

    /// Whole-point frame height for `width` so Kingfisher and CDN cache keys stay integer-sized.
    func height(forWidth width: CGFloat) -> CGFloat { (width / aspect.ratio).rounded() }

    func width(forHeight height: CGFloat) -> CGFloat { (height * aspect.ratio).rounded() }

    func size(width: CGFloat) -> CGSize {
        CGSize(width: width.rounded(), height: height(forWidth: width))
    }

    func size(height: CGFloat) -> CGSize {
        CGSize(width: width(forHeight: height), height: height.rounded())
    }
}

/// Observable singleton publishing live `CoverPresentation` changes across tabs, sheets, and fullscreen covers.
@Observable
@MainActor
final class CoverPresentationStore {
    static let shared = CoverPresentationStore()

    private(set) var presentation: CoverPresentation

    private init() {
        presentation = CoverPresentation(aspect: .current, display: .current)
    }

    func reload() {
        let next = CoverPresentation(aspect: .current, display: .current)
        if next != presentation { presentation = next }
    }
}

/// Renders a video or live cover under `CoverPresentationStore`.
/// Fixed-width rows pass `width:`; flexible grid cells omit `width` so `Color.clear.aspectRatio` bounds the column and overlays `CoverImage`.
struct VideoCoverImage: View {
    let sources: VideoCoverSources
    var width: CGFloat?
    /// Known column width for flexible grid cells so `CoverImage` skips a two-pass `GeometryReader` measurement during scroll.
    var columnWidth: CGFloat?
    /// Fixed aspect override for surfaces (such as the Home hero banner) that stay widescreen regardless of card settings.
    var aspectOverride: CoverAspect?
    var fillAlignment: Alignment = .center
    var groundColor: Color = .imagePlaceholder
    @Environment(\.redactionReasons) private var redactionReasons

    private var policy: CoverPresentation {
        let base = CoverPresentationStore.shared.presentation
        guard let aspectOverride else { return base }
        return CoverPresentation(aspect: aspectOverride, display: base.display)
    }

    var body: some View {
        if redactionReasons.contains(.placeholder) {
            placeholderBox
        } else {
            coverBody
        }
    }

    @ViewBuilder private var placeholderBox: some View {
        let presentation = policy
        if let width {
            let size = presentation.size(width: width)
            groundColor.frame(width: size.width.rounded(), height: size.height.rounded())
        } else {
            groundColor.aspectRatio(presentation.aspect.ratio, contentMode: .fit)
        }
    }

    @ViewBuilder private var coverBody: some View {
        let presentation = policy
        let url = presentation.url(for: sources)
        let relation = presentation.relation(for: sources)
        if let width {
            CoverImage(
                urlString: url,
                displaySize: presentation.size(width: width),
                contentMode: presentation.contentMode,
                fillAlignment: fillAlignment,
                requestHeadroom: .officialCoverAspects,
                groundColor: groundColor,
                sourceRelation: relation
            )
        } else {
            let knownDisplaySize: CGSize? = columnWidth.flatMap { col in
                col > 1 ? presentation.size(width: col) : nil
            }
            Color.clear
                .aspectRatio(presentation.aspect.ratio, contentMode: .fit)
                .overlay {
                    CoverImage(
                        urlString: url,
                        displaySize: knownDisplaySize,
                        contentMode: presentation.contentMode,
                        fillAlignment: fillAlignment,
                        requestHeadroom: .officialCoverAspects,
                        groundColor: groundColor,
                        sourceRelation: relation,
                        fillsOfferedBox: true
                    )
                }
        }
    }
}
