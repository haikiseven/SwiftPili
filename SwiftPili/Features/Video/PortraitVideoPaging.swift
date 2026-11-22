import CoreGraphics
import Foundation

/// Presentation routes that may eventually own the tokenized portrait pager.
/// Ordinary VOD detail and offline playback deliberately stay on the standard
/// player gesture path. The Shorts case is an explicit seam for a future
/// dedicated feed, but remains disabled until that screen owns the route.
enum PortraitPagingRoute: Equatable, Sendable {
    case onlineDetail
    case offlinePlayback
    case shorts
}

enum PortraitPagingPolicy {
    /// The dedicated Shorts surface is not shipped yet. Keeping this switch
    /// separate makes the future route's opt-in explicit instead of making a
    /// portrait aspect a hidden feed trigger.
    static let shortsFeedEnabled = false

    /// Vertical feed paging is currently deferred for every route. Keeping the
    /// decision here makes it impossible for a normal screen to re-enable a
    /// hidden sink by accident, while leaving the reducer/routes reusable for
    /// the future Shorts owner.
    static func allowsVerticalPaging(on route: PortraitPagingRoute) -> Bool {
        switch route {
        case .onlineDetail, .offlinePlayback:
            return false
        case .shorts:
            return shortsFeedEnabled
        }
    }
}

/// Pure policy for the ordinary portrait VOD window. Scrolling can make an
/// expanded window smaller once, but it cannot restore the larger window. The
/// visible portrait-window button is the only restore path.
enum PortraitVODCondensationPolicy {
    static let collapseThreshold: CGFloat = -60

    static func shouldAutoCollapse(
        offset: CGFloat,
        isCondensed: Bool,
        hasManualChoice: Bool
    ) -> Bool {
        guard offset.isFinite, !isCondensed, !hasManualChoice else { return false }
        return offset < collapseThreshold
    }
}

/// WHICH cover a portrait page shows. Deliberately not how big it is, and not
/// what shape it is.
///
/// The version this replaced carried an `IntendedAspect` derived from the field
/// the URL came out of — 4:3 for the mobile variant, 16:9 for the desktop one —
/// and computed both the drawn box and the requested box from it. Measured
/// against the live CDN on 2026-08-25, that assumption is wrong in three
/// independent ways:
///
///  1. **The ratios are approximate.** Sampled `cover43` assets came back
///     1200×900 (1.333), 1794×1345 (1.334) and 687×519 (**1.324**); sampled
///     `pic` assets 1920×1080 (1.778) and 1076×608 (**1.771**). A box computed
///     from the nominal fraction is letterboxed against the real artwork.
///  2. **Some sources are smaller than the box.** That 687×519 cover is
///     narrower than a phone page's request, and `i*.hdslb.com` does not
///     upscale — it answered 687×519 to an `@896w` request. A `displaySize`
///     asserting 896×672 for it claims resolution that does not exist.
///  3. **A wrong aspect can violate `CoverImage.requestSize`'s contract** —
///     "must be >= `displaySize` in BOTH dimensions" — because the requested
///     height came from the assumed ratio while the drawn height came from the
///     real one. Shorter on an axis is real resolution lost, then upscaled.
///
/// So geometry comes from the image: the artwork layer is DRAWN into the page
/// box under `.fit`, where the bitmap's own aspect governs, and it is REQUESTED
/// at the pager's quantized page box (`PortraitPagingReducer`). The CDN's
/// `@{w}w_{h}h` suffix fits inside that box preserving aspect, so an
/// aspect-agnostic box costs nothing: for the 1200×900 cover above,
/// `@896w_1920h` and `@896w_672h` returned byte-identical 896×672 WebP.
///
/// `Kind` survives as provenance — which field the URL came from — and carries
/// no geometry. On device, which source actually arrived is readable from
/// `CoverImage`'s own `[cover]` line under Diagnostic Logging: it prints
/// `returned=WxH(ratio)`, and ~1.33 against ~1.78 is the two sources apart.
///
/// ⚠️ This reasoning is about a FULL-PAGE preview, whose frame is the screen and
/// therefore cannot be either of BiliBili's cover ratios. It is not a licence to
/// derive a CARD's frame from a bitmap: on card surfaces the frame comes from
/// the user's `CoverAspect`, and which official variant is preferred comes from
/// the same setting (`CoverPresentation`).
///
/// This page owes that setting NOTHING — not the frame, not the content mode,
/// and not the source preference. It read the source half for one release, which
/// was the same category error as the display half in a quieter form: half of a
/// two-part choice is a different, unstated policy wearing the setting's name.
/// `PortraitPagerCoverBackdrop.coverURL` carries the reason it prefers the
/// narrow-page variant unconditionally, which is a fact about a ~1:2 page under
/// `.fit`, not a fact about anything the user configured.
struct PortraitPagingCoverSource: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A cover the API composed for a narrow page (`cover43` / `pic_4_3`).
        case mobileVariant
        /// The standard cover (`pic`), which is all most endpoints return.
        case desktop
    }

    /// BOTH official candidates are carried, and neither is resolved here.
    ///
    /// The reason is NOT the one an earlier revision of this comment gave. It
    /// said that storing one already-chosen url made the choice "unreachable by
    /// the Cover Aspect setting", and that selection had moved to the backdrop
    /// because that is "the only place that knows the setting". Neither half
    /// survives: the backdrop no longer reads the setting at all, and what it
    /// resolves — the mobile variant when one exists — is precisely the rule the
    /// old already-chosen value used. Reachability by a user preference is not a
    /// requirement this page has.
    ///
    /// What carrying both is for now: the resolution belongs to the surface that
    /// owns the geometry it depends on, so the page's ~1:2 box decides it and a
    /// navigation boundary that knows nothing about the page does not. It also
    /// keeps `kind(preferring:)` answerable, i.e. keeps WHICH asset was drawn a
    /// fact rather than an inference from the URL.
    let desktopURL: String
    let mobileVariantURL: String?

    init(desktopURL: String, mobileVariantURL: String? = nil) {
        self.desktopURL = desktopURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mobileVariantURL = mobileVariantURL
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func portraitPreview(desktopURL: String, mobileVariantURL: String?) -> Self {
        Self(desktopURL: desktopURL, mobileVariantURL: mobileVariantURL)
    }

    static func desktop(url: String) -> Self {
        Self(desktopURL: url)
    }

    /// The URL for a stated preference, falling back to the other official
    /// asset when this endpoint composed only one. A fallback never changes
    /// what the caller asked for — it is the same preference, served by the
    /// only asset that exists.
    func url(preferring preferred: Kind) -> String {
        switch preferred {
        case .mobileVariant:
            return mobileVariantURL ?? desktopURL
        case .desktop:
            return desktopURL.isEmpty ? (mobileVariantURL ?? desktopURL) : desktopURL
        }
    }

    /// Which asset `url(preferring:)` actually returned — provenance, never
    /// geometry.
    ///
    /// No production call site reads this yet; the `[cover]` line an earlier
    /// version of this comment named it for takes its provenance from
    /// `CoverPresentation.relation(for:)` on the card surfaces and prints
    /// `role=decorative` for the two pager layers instead. Kept because the
    /// question it answers — which of the two assets a page actually drew — is
    /// not recoverable from the URL alone once both are plausible.
    func kind(preferring preferred: Kind) -> Kind {
        switch preferred {
        case .mobileVariant:
            return mobileVariantURL == nil ? .desktop : .mobileVariant
        case .desktop:
            return desktopURL.isEmpty && mobileVariantURL != nil ? .mobileVariant : .desktop
        }
    }

    /// True when neither official asset exists, so the page draws no artwork at
    /// all rather than building a request on an empty URL.
    var isEmpty: Bool { desktopURL.isEmpty && mobileVariantURL == nil }
}

/// Immutable navigation data for an inert neighbouring preview. It never owns
/// API models, player state, or a render attachment.
struct PortraitPagingPreview: Hashable, Sendable {
    let title: String
    let coverSource: PortraitPagingCoverSource
    let ownerName: String
    let durationSeconds: Int

    init(
        title: String,
        coverURL: String = "",
        ownerName: String = "",
        durationSeconds: Int = 0
    ) {
        self.title = title
        coverSource = .desktop(url: coverURL)
        self.ownerName = ownerName
        self.durationSeconds = durationSeconds
    }

    init(
        title: String,
        coverSource: PortraitPagingCoverSource,
        ownerName: String = "",
        durationSeconds: Int = 0
    ) {
        self.title = title
        self.coverSource = coverSource
        self.ownerName = ownerName
        self.durationSeconds = durationSeconds
    }
}

/// The one video a route names. Identity is the `VideoID` alone; preview and
/// Zoom source are presentation payload, so neither participates in equality
/// or hashing and a route comparison stays O(1).
struct VideoRouteTarget: Hashable, Sendable, Identifiable {
    let videoID: VideoID
    let preview: PortraitPagingPreview
    let zoomSourceID: UUID?

    var id: VideoID { videoID }

    init(
        videoID: VideoID,
        preview: PortraitPagingPreview = .init(title: ""),
        zoomSourceID: UUID? = nil
    ) {
        self.videoID = videoID
        self.preview = preview
        self.zoomSourceID = zoomSourceID
    }

    func opening(from sourceID: UUID) -> Self {
        Self(videoID: videoID, preview: preview, zoomSourceID: sourceID)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.videoID == rhs.videoID }

    func hash(into hasher: inout Hasher) { hasher.combine(videoID) }

    /// Normalize heterogeneous list DTOs at the navigation boundary. bvid is
    /// preferred because it remains stable across the API surfaces we use.
    static func make(
        bvid: String?,
        aid: Int?,
        title: String,
        coverURL: String = "",
        /// The API's narrow-page cover for this item, when the endpoint returns
        /// one — `MobileCoverSelection` already resolved which key that is and
        /// whether it holds a usable value. Endpoints with no variant field pass
        /// nothing and are drawn from `coverURL`; that is not a degraded path,
        /// because the drawn geometry no longer assumes either source's shape.
        mobileCoverURL: String? = nil,
        ownerName: String = "",
        durationSeconds: Int = 0
    ) -> Self? {
        let videoID: VideoID
        if let bvid = bvid?.trimmingCharacters(in: .whitespacesAndNewlines), !bvid.isEmpty {
            videoID = .bvid(bvid)
        } else if let aid, aid > 0 {
            videoID = .aid(aid)
        } else {
            return nil
        }
        return Self(
            videoID: videoID,
            preview: .init(
                title: title,
                coverSource: .portraitPreview(
                    desktopURL: coverURL,
                    mobileVariantURL: mobileCoverURL
                ),
                ownerName: ownerName,
                durationSeconds: max(0, durationSeconds)
            )
        )
    }
}

/// Immutable offline navigation data. The persistent download identifier is
/// resolved back to a validated local asset only after the settlement token
/// commits; neither SwiftData models nor file URLs cross the route boundary.
struct OfflinePortraitPagingItem: Hashable, Sendable, Identifiable {
    let downloadID: String
    let preview: PortraitPagingPreview

    var id: String { downloadID }
}

/// The ordered, validated-download sequence captured at the navigation
/// boundary. It deliberately contains values only, keeping local-file
/// validation and player admission at the committed page boundary.
struct OfflinePortraitPagingContext: Hashable, Sendable {
    let items: [OfflinePortraitPagingItem]
    let initialIndex: Int

    init?(items: [OfflinePortraitPagingItem], selectedID: String) {
        var seen: Set<String> = []
        let stable = items.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        guard let initialIndex = stable.firstIndex(where: { $0.id == selectedID }) else { return nil }
        self.items = stable
        self.initialIndex = initialIndex
    }

    static func single(_ id: String) -> Self {
        Self(
            items: [.init(downloadID: id, preview: .init(title: ""))],
            selectedID: id
        )!
    }
}

struct PortraitPagingToken: Hashable, Sendable {
    let rawValue: UInt64
}

/// Pure sign-based pager. Dragging affects only presentation offset; index
/// mutation is delayed until the matching animation completion is consumed.
struct PortraitPagingReducer: Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        var distanceFraction: CGFloat = 0.22
        var predictedFraction: CGFloat = 0.42
        var boundaryDamping: CGFloat = 0.28
    }

    enum SettlementKind: Equatable, Sendable {
        case rebound
        case switchPage(targetIndex: Int)
    }

    struct Settlement: Equatable, Sendable {
        let token: PortraitPagingToken
        let kind: SettlementKind
    }

    enum Phase: Equatable, Sendable {
        case idle
        case dragging
        case settling(Settlement)
    }

    struct Commit: Equatable, Sendable {
        let token: PortraitPagingToken
        let index: Int
    }

    private(set) var currentIndex: Int
    private(set) var offset: CGFloat = 0
    private(set) var phase: Phase = .idle
    private(set) var containerHeight: CGFloat = 0
    /// The box neighbour artwork is REQUESTED at — both axes, because the
    /// artwork is drawn fitted into the page and its real aspect is not known
    /// until the bitmap arrives (`PortraitPagingCoverSource`). It is a quantized
    /// high-water mark rather than a live value, which is the whole reason it is
    /// not just `pageSize`: `containerHeight` moves with the nav bar, the tab bar
    /// and every fullscreen transition, and each distinct box is a fresh
    /// Kingfisher cache key AND a fresh CDN transcode of the same cover.
    private(set) var coverResolutionBudget: CGSize = .zero

    /// Coarse enough that chrome-sized changes collapse onto one box, fine
    /// enough that the over-request is a few percent of one cover.
    static let coverBoxQuantum: CGFloat = 32

    private(set) var itemCount: Int
    private var tokenCounter: UInt64 = 0
    let configuration: Configuration

    init(itemCount: Int, initialIndex: Int, configuration: Configuration = .init()) {
        self.itemCount = max(0, itemCount)
        currentIndex = itemCount > 0 ? min(max(0, initialIndex), itemCount - 1) : 0
        self.configuration = configuration
    }

    var acceptsTouch: Bool { phase == .idle && itemCount > 0 }
    var previousIndex: Int? { currentIndex > 0 ? currentIndex - 1 : nil }
    var nextIndex: Int? { currentIndex + 1 < itemCount ? currentIndex + 1 : nil }

    mutating func updateContainerHeight(_ height: CGFloat) {
        let normalized = height.isFinite && height > 0 ? height : 0
        guard normalized != containerHeight else { return }
        containerHeight = normalized
        guard phase != .idle else { return }
        phase = .idle
        offset = 0
        tokenCounter &+= 1
    }

    /// Feed this the page reader's WHOLE box. Both axes are quantized up, so the
    /// result is never shorter than what is drawn — the invariant
    /// `CoverImage.requestSize` states and the assumed-aspect version could
    /// break.
    mutating func noteCoverResolution(width: CGFloat, height: CGFloat) {
        guard width.isFinite, width > 0, height.isFinite, height > 0 else { return }
        let quantizedWidth = Self.quantizedCoverSide(width)
        let quantizedHeight = Self.quantizedCoverSide(height)
        guard quantizedWidth == coverResolutionBudget.width else {
            // A different width bucket is a different WINDOW (rotation, Split
            // View, Stage Manager). Restart the height mark instead of carrying
            // the previous layout's tallest page into it, which would over-request
            // every cover for the rest of the session.
            coverResolutionBudget = CGSize(width: quantizedWidth, height: quantizedHeight)
            return
        }
        // Same window, moving chrome: keep the tallest box this width has needed,
        // so a nav bar or tab bar appearing cannot mint a second cache key for a
        // cover that is already loaded.
        guard quantizedHeight > coverResolutionBudget.height else { return }
        coverResolutionBudget.height = quantizedHeight
    }

    private static func quantizedCoverSide(_ side: CGFloat) -> CGFloat {
        (side / coverBoxQuantum).rounded(.up) * coverBoxQuantum
    }

    @discardableResult
    mutating func beginDrag() -> Bool {
        guard acceptsTouch else { return false }
        phase = .dragging
        offset = 0
        return true
    }

    /// The offset a translation should paint, WITHOUT mutating anything.
    ///
    /// This is the per-touch-sample value, and it is deliberately not a
    /// `mutating` call: the reducer lives in `@State`, and writing `@State`
    /// once per drag sample invalidates the entire detail view — player,
    /// comment list, composer and all — sixty to a hundred and twenty times a
    /// second. That re-render, not the gesture, was the drag jitter. The live
    /// value belongs in `PortraitDragOffsetBox`, which only the offset modifier
    /// reads; the reducer keeps the discrete state.
    func dragOffset(for translation: CGFloat) -> CGFloat {
        guard phase == .dragging, translation.isFinite else { return offset }
        return targetIndex(for: translation) == nil
            ? translation * configuration.boundaryDamping
            : translation
    }

    /// Mutating form, retained for the reducer's own unit tests, which drive it
    /// as a pure state machine with no view attached. The shipping drag path
    /// uses `dragOffset(for:)` and must not call this.
    @discardableResult
    mutating func drag(translation: CGFloat) -> CGFloat {
        guard phase == .dragging, translation.isFinite else { return offset }
        offset = dragOffset(for: translation)
        return offset
    }

    @discardableResult
    mutating func endDrag(translation: CGFloat, predictedEndTranslation: CGFloat) -> Settlement? {
        guard phase == .dragging else { return nil }
        let actual = translation.isFinite ? translation : 0
        let predicted = predictedEndTranslation.isFinite ? predictedEndTranslation : actual
        let directionSample = abs(actual) > 0.5 ? actual : predicted
        let sameDirection = actual == 0 || predicted == 0 || actual * predicted >= 0
        let crossesThreshold = containerHeight > 0 && (
            abs(actual) >= containerHeight * configuration.distanceFraction ||
                (sameDirection && abs(predicted) >= containerHeight * configuration.predictedFraction)
        )

        let kind: SettlementKind
        if let target = targetIndex(for: directionSample), crossesThreshold {
            kind = .switchPage(targetIndex: target)
            offset = directionSample < 0 ? -containerHeight : containerHeight
        } else {
            kind = .rebound
            offset = 0
        }
        let settlement = nextSettlement(kind)
        phase = .settling(settlement)
        return settlement
    }

    @discardableResult
    mutating func cancelDrag() -> Settlement? {
        guard phase == .dragging else { return nil }
        offset = 0
        let settlement = nextSettlement(.rebound)
        phase = .settling(settlement)
        return settlement
    }

    /// Inspects the animation completion that is currently authorized to
    /// settle without consuming it. The production dispatcher uses this to
    /// validate the target and screen lease before it silences playback.
    func settlement(for token: PortraitPagingToken) -> Settlement? {
        guard case .settling(let settlement) = phase, settlement.token == token else { return nil }
        return settlement
    }

    /// Returns to the committed page when the target or its screen lease is
    /// no longer valid at animation completion. This deliberately does not
    /// mutate the committed index.
    @discardableResult
    mutating func abandonSettlement(token: PortraitPagingToken) -> Bool {
        guard settlement(for: token) != nil else { return false }
        phase = .idle
        offset = 0
        return true
    }

    @discardableResult
    mutating func completeSettlement(token: PortraitPagingToken) -> Commit? {
        guard let settlement = settlement(for: token) else { return nil }
        phase = .idle
        offset = 0
        guard case .switchPage(let target) = settlement.kind else { return nil }
        currentIndex = target
        return Commit(token: token, index: target)
    }

    private func targetIndex(for translation: CGFloat) -> Int? {
        guard translation != 0 else { return nil }
        let target = currentIndex + (translation < 0 ? 1 : -1)
        return (0..<itemCount).contains(target) ? target : nil
    }

    private mutating func nextSettlement(_ kind: SettlementKind) -> Settlement {
        tokenCounter &+= 1
        return .init(token: .init(rawValue: tokenCounter), kind: kind)
    }
}

/// Production-only bridge from the tokenized reducer to playback effects.
/// Rebounds, stale completions, and failed handoff admission stay side-effect
/// free.
enum PortraitPagingSettlementDispatcher {
    @discardableResult
    static func complete<ItemID>(
        token: PortraitPagingToken,
        reducer: inout PortraitPagingReducer,
        itemIDAtIndex: (Int) -> ItemID?,
        handoff: () -> Bool,
        activate: (PortraitPagingReducer.Commit, ItemID) -> Void
    ) -> Bool {
        guard let settlement = reducer.settlement(for: token) else { return false }
        guard case .switchPage(let targetIndex) = settlement.kind else {
            _ = reducer.completeSettlement(token: token)
            return false
        }
        // The animation token is still current, but the route snapshot or
        // screen lease can disappear while the animation is running. In that
        // case return to the already committed page without changing media or
        // the reducer's index.
        guard let itemID = itemIDAtIndex(targetIndex), handoff() else {
            _ = reducer.abandonSettlement(token: token)
            return false
        }
        guard let commit = reducer.completeSettlement(token: token) else { return false }
        activate(commit, itemID)
        return true
    }
}
