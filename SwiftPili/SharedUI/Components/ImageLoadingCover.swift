import Kingfisher
import SwiftUI

/// App-wide image LOADING PRESENTATION: while an image has not arrived, its
/// whole area is COVERED and (past a short delay) carries a spinner; when it
/// arrives the cover disappears; when the load ends in failure the cover stays
/// but stops spinning and shows a static glyph.
///
/// Why this exists as one shared modifier rather than per-site placeholders:
/// every call site had invented its own answer, and the three that matter were
/// all wrong in the same direction. A bare `Rectangle().fill(ground)` says
/// "loading" and "permanently failed" with the same pixels; a bare
/// `ProgressView()` in `.placeholder` is an INFINITE spinner, because
/// Kingfisher renders the placeholder branch whenever `loadedImage == nil` —
/// which includes forever after a terminal failure (`ImagePreviewView` had
/// exactly that). `.onFailureView` takes priority inside that same branch and
/// is the only way to split the two states apart; before this file it was used
/// at zero sites.
///
/// The state machine is Kingfisher's, not ours. `KFImageProtocol.body` is
/// `KFImageRenderer(context:).id(context)` and `Context: Hashable` on
/// (source, processor identifier), so the load state is ALREADY keyed by
/// URL + decode box and resets itself on cell reuse. Nothing here mirrors it
/// into app-side `@State` — a mirror is what goes stale on recycle.
///
/// ⚠️ Two call points, not one, and the split is forced by the type system.
/// `placeholder`/`onFailureView` return `Self` (they only write into
/// `context`), so they can sit anywhere in a Kingfisher chain. `.background`
/// cannot: it is a SwiftUI modifier and returns `some View`. The ground has to
/// be a real background BEHIND the image view and not merely content inside
/// `.placeholder`, because `CacheManager.apply()` installs an app-wide fade
/// (`ImagePipelinePolicy.networkFadeSeconds`, 0.12s) and Kingfisher implements
/// it as `renderedImage().opacity(binder.loaded ? 1 : 0)` in the same ZStack
/// that drops the placeholder the instant `loadedImage != nil`
/// (KFImageRenderer.swift:45-57) — so for the length of that fade the image is
/// at opacity 0 with the placeholder already gone, and whatever sits behind the
/// KFImage shows through. That also rules out `contentConfigure`, which would
/// put the ground INSIDE that opacity and fade it in together with the image.
///
/// That window exists on a NETWORK arrival only. Kingfisher applies the
/// transition when `forceTransition || cacheType == .none`
/// (ImageContext.swift:115-117) and this app never passes `forceTransition`, so
/// a memory or disk hit is drawn at full opacity in the frame it lands and there
/// is no gap to cover — which is why the ground being a real background is
/// nevertheless load-bearing rather than belt-and-braces: the one case it exists
/// for is the one case that has a gap.
///
/// So `imageLoadingCover` returns `some View`: it is the LAST Kingfisher-chain
/// element at a call site. `.setProcessor`/`.imageFadePolicy`/`.resizable` (all
/// `-> Self`) go before it; `.scaledToFit`/`.frame`/`.clipShape` (plain SwiftUI)
/// go after.
enum ImageCoverShape: Equatable {
    case rect
    case roundedRect(CGFloat)
    case circle

    /// The cover must match the CLIP SHAPE of the site it covers, or it draws
    /// corners outside a rounded or circular image. `RoundedRectangle` is left
    /// at the default `.circular` style on purpose — that is what every clip in
    /// this app uses, and a `.continuous` cover under a `.circular` clip is a
    /// visible seam at the corners.
    @ViewBuilder
    func ground(_ color: Color) -> some View {
        switch self {
        case .rect:
            Rectangle().fill(color)
        case let .roundedRect(radius):
            RoundedRectangle(cornerRadius: radius).fill(color)
        case .circle:
            Circle().fill(color)
        }
    }
}

extension KFImageProtocol {
    /// Covers the image area until the image lands, then hands over.
    ///
    /// - Parameters:
    ///   - shape: must match the site's clip shape (see `ImageCoverShape`).
    ///   - ground: the backing, and it must be OPAQUE or `.clear` — never
    ///     translucent. It is painted TWICE by design (once as the cover leaf's
    ///     own fill, which is what covers the area, and once as the background
    ///     that spans the fade window), and stacking two 16%-alpha fills is a
    ///     visibly darker slab than one. Pass `.clear` at a site that already
    ///     paints a ground across the whole image area — a reserved box, a
    ///     letterbox, a black previewer backdrop — so the cover adds only the
    ///     indicator and the existing neutral stays the single source of the
    ///     shade (the "cover flashes a shade as it lands" bug that
    ///     `Color.imagePlaceholder`'s doc comment records).
    ///   - shorterSide: the shorter side of the image area in points, when the
    ///     call site knows it. Drives the spinner size gate and the failure
    ///     glyph size; `nil` means unknown, and unknown never gates.
    ///   - tint: an explicit colour for both the loading and failure indicators.
    ///
    ///     Ordinary sites leave this `nil`: loading follows `Color.biliAccent`
    ///     and its current theme/scope, while terminal failure stays `.secondary`.
    ///     The loading leaf reads the observable accent during view evaluation,
    ///     so settings changes need no per-image colour state or request restart.
    ///
    ///     `ImagePreviewView` explicitly passes `.white` for its fixed black
    ///     backdrop. That override reaches both `LoadingCover` and `FailedCover`,
    ///     preserving visibility in both states regardless of theme or appearance.
    ///   - isHidden: optional live presentation gate for a second image layer
    ///     that already supplies this area. Only placeholder/failure content is
    ///     hidden; a loaded image and the fade-window background stay mounted.
    ///     Both builders retain the binding so an earlier failure can observe
    ///     a later sibling success. Other callers keep the existing default.
    /// - Returns: a plain `View` — this is the last Kingfisher-chain element.
    @ViewBuilder
    func imageLoadingCover(
        shape: ImageCoverShape = .rect,
        ground: Color = .imagePlaceholderOpaque,
        shorterSide: CGFloat? = nil,
        tint: Color? = nil,
        showsIndicator: Bool? = nil,
        isHidden: Binding<Bool>? = nil
    ) -> some View {
        let resolvedShowsIndicator = showsIndicator ?? (isHidden != nil)
        if !resolvedShowsIndicator, ground == .clear, isHidden == nil {
            onFailureView {
                FailedCover(shape: shape, ground: ground, shorterSide: shorterSide, tint: tint)
            }
        } else {
            placeholder {
                if let isHidden {
                    ImageLoadingCoverGate(
                        isHidden: isHidden,
                        content: LoadingCover(
                            shape: shape,
                            ground: ground,
                            shorterSide: shorterSide,
                            tint: tint,
                            showsIndicator: resolvedShowsIndicator
                        )
                    )
                } else {
                    LoadingCover(
                        shape: shape,
                        ground: ground,
                        shorterSide: shorterSide,
                        tint: tint,
                        showsIndicator: resolvedShowsIndicator
                    )
                }
            }
            .onFailureView {
                if let isHidden {
                    ImageLoadingCoverGate(
                        isHidden: isHidden,
                        content: FailedCover(shape: shape, ground: ground, shorterSide: shorterSide, tint: tint)
                    )
                } else {
                    FailedCover(shape: shape, ground: ground, shorterSide: shorterSide, tint: tint)
                }
            }
            // Sized to the image view's own frame, and OUTSIDE the fade opacity —
            // see the file header for why neither `.placeholder` nor
            // `contentConfigure` can carry this. Skipped entirely for `.clear`,
            // where the site owns the ground and this would only add an empty
            // layer per cell to the app's hottest scroll.
            .background {
                if ground != .clear { shape.ground(ground) }
            }
        }
    }
}

/// Kingfisher may retain the failure builder from an older Context. Reading its
/// binding in this leaf keeps that builder responsive to current presentation.
private struct ImageLoadingCoverGate<Content: View>: View {
    @Binding var isHidden: Bool
    let content: Content

    var body: some View {
        if !isHidden { content }
    }
}

extension KFOptionSetter {
    /// The app's ONE appearance-transition decision, applied to this request.
    ///
    /// It exists as a seam because the decision needs one input no policy object
    /// can read for itself: `accessibilityReduceMotion`. That value is live and
    /// free from `@Environment` inside a view body and awkward everywhere else —
    /// `UIAccessibility` is main-actor state, `CacheManager.apply()` runs before
    /// any view exists, and a cached copy plus a notification observer would be a
    /// second source of truth to keep in sync for a value SwiftUI already tracks.
    /// So the site that is already reading the environment passes it in, and the
    /// duration itself is not the site's business.
    ///
    /// `nil` sets `.none` rather than `.fade(0)`, and the difference is real:
    /// `ImageBinder` takes `withAnimation(.linear(duration:)) {
    /// markLoaded(sendChangeEvent: true) }` for any non-nil duration and
    /// `markLoaded(sendChangeEvent: false)` for none (ImageBinder.swift:121-130),
    /// so a zero-second fade would still open an animation transaction and still
    /// publish one more change per arriving image. Reduce Motion means no
    /// transition, not an instant one.
    ///
    /// BOTH branches assign `options.transition`, and that is forced rather than
    /// stylistic. Kingfisher's `fade(duration:)` is declared on
    /// **`KFImageProtocol`** (KFImageOptions.swift:194-197) and on the concrete
    /// `KF.Builder` (KF.swift:381-384) — there is no `fade(duration:)` anywhere on
    /// `KFOptionSetter`, so inside this extension `Self` has no such member and
    /// calling it is `cannot find 'fade' in scope`. Writing the field directly is
    /// also the only way to express the `nil` case at all, since the builder
    /// cannot say `.none`; `options` is `{ get nonmutating set }` on
    /// `KFOptionSetter` (KFOptionsSetter.swift:38), which is what makes the write
    /// legal from a non-mutating method on a struct.
    ///
    /// The seam stays on `KFOptionSetter` rather than being narrowed to
    /// `KFImageProtocol`: `options` is the only thing it needs, this is where that
    /// requirement lives, and narrowing it would exclude the builder path for no
    /// reason. Cost is unchanged either way — `fade(duration:)` was itself one
    /// get/modify/set through the same property.
    func imageFadePolicy(reduceMotion: Bool) -> Self {
        guard let seconds = ImagePipelinePolicy.fadeSeconds(reduceMotion: reduceMotion) else {
            options.transition = .none
            return self
        }
        options.transition = .fade(seconds)
        return self
    }
}

/// Device A/B switch for the loading INDICATOR's animation, and nothing else.
///
/// The question it exists to answer cannot be answered off-device: a
/// `ProgressView(.circular)` is a `UIActivityIndicatorView` behind a
/// `UIViewRepresentable`, and its per-frame spin is CoreAnimation work on the
/// render server, not main-thread work — so it should NOT show up in
/// `UIHitchMonitor`'s main-thread display-link gaps, while the one-frame BURST
/// of creating up to 54 of them should. Only a phone can separate those.
///
/// Default OFF: the app ships the real spinner. Turning it ON keeps the cover,
/// the indicator slot and the layout identical and swaps the animated indicator
/// for a static glyph, so an A/B run varies exactly one thing.
///
/// Read as a plain static `Bool` on the same contract as
/// `ImageDiagnostics.isEnabled` — one relaxed load per `LoadingCover` body,
/// no observation registered, so an A/B toggle cannot itself become a
/// re-render source. It therefore applies to indicators created AFTER the
/// flip; scroll to a fresh region (or pull to refresh) to see it.
enum ImageLoadingIndicatorPolicy {
    static let staticIndicatorKey = "image_loading_indicator_static"

    nonisolated(unsafe) static var isStatic = false

    @MainActor
    static func applyExperimentalPolicy() {
        isStatic = ExperimentalSettingsPolicy.isAllowed(.diagnostics)
            && UserDefaults.standard.bool(forKey: staticIndicatorKey)
    }

    @MainActor
    static func setStatic(_ on: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        UserDefaults.standard.set(on, forKey: staticIndicatorKey)
        applyExperimentalPolicy()
    }
}

/// The covered, still-loading state: opaque ground from frame 0, spinner
/// behind two gates.
///
/// **Every piece of state in here is deliberately local to this leaf view.**
/// `CoverImage.body` opens with `UIHitchMonitor.count("img.body")` +
/// `ImageDiagnostics.noteBody()`, and `img.body` is the DENOMINATOR for every
/// other image counter in the diagnostics runbook. A spinner whose animation or
/// delay flag lived in `CoverImage`'s own `@State` would re-enter
/// `CoverImage.body` on every tick and inflate that denominator, quietly
/// invalidating the hit/miss/probe ratios it is read against. `@State` here
/// invalidates only this view.
struct LoadingCover: View {
    let shape: ImageCoverShape
    var ground: Color = .imagePlaceholderOpaque
    var shorterSide: CGFloat?
    var tint: Color?
    /// GATE 0 — is anything actually in flight behind this cover?
    ///
    /// `false` at the ONE site where the answer is no: `CoverImage`'s
    /// measure-then-load bootstrap frame, which is drawn *before* a box is
    /// known and therefore before any request exists. Two things follow from
    /// getting that wrong, and both were live:
    ///  - every flexible-box cover (grids, the comment media grid, the image
    ///    previewer) armed a `Task` and a 200ms timer per mount AND per
    ///    recycle, for a view SwiftUI destroys in the next layout pass;
    ///  - a call site whose geometry never lands rests in that branch forever,
    ///    so after 200ms it showed a spinner that could never end — an
    ///    infinite spinner for a load that was never started.
    var showsIndicator: Bool = true

    /// GATE 1 — size. A `ProgressView` circular indicator is ~20pt; inside a
    /// 22pt avatar circle it is edge-to-edge noise rather than an indicator, so
    /// small areas get ground only. Unknown size never gates: a site that does
    /// not state its box is assumed large.
    private static let spinnerMinSide: CGFloat = 28

    /// GATE 2 — delay. The spinner appears only after this much ACTUAL loading.
    ///
    /// This is a deliberate softening of "always show a spinner", and the reason
    /// is concrete: memory- and disk-cache hits resolve inside a frame or two,
    /// so without a delay a warm scroll would mint a spinner per cell and the
    /// Favorites grid would run up to ~60 concurrent CoreAnimation animations
    /// for indicators nobody is given time to read. The COVER is not softened —
    /// it is present from frame 0 regardless, so the requirement that an
    /// unloaded area is never see-through holds either way.
    ///
    /// ⚠️ **What it does NOT bound, and this was over-claimed once.** The delay
    /// bounds the WARM case only. Executed off-device against the real container
    /// definitions (Favorites = a non-lazy 10-card `HStack` per folder row,
    /// `UserAPI.getFavoriteContent(ps: 10)`, ~6 rows resident ⇒ 60 covers): a
    /// warm scroll shows 0 of 60, and a COLD one shows 54 of 60 — and because
    /// the whole non-lazy rail mounts in the frame that assigns its items, all
    /// 54 timers were armed together and fire in ONE frame, not staggered. So
    /// "many images loading" — the reported symptom — is precisely the case the
    /// gate does nothing about, and the cost that remains is the single-frame
    /// burst of creating them, not their steady-state spin (which is render-server
    /// work, not main-thread work). `ImageLoadingIndicatorPolicy` exists to
    /// settle that split on a device instead of by argument.
    ///
    /// ⚠️ That modelled "54 of 60" is a container count, not an observation, and
    /// `ImageLoadingIndicatorPolicy` cannot check it — the static glyph is
    /// created in the same numbers as the spinner, so the arm varies the
    /// animation and not the creation. The count itself is now recorded:
    /// `ImageDiagnostics.noteIndicatorShown` fires from the `.task` below at
    /// the one instant an indicator comes into existence, so `spinners=` in the
    /// image report is the real number and the worst-stall rows say whether any
    /// of them landed inside a frame gap.
    private static let spinnerDelay = Duration.milliseconds(200)

    @State private var spinnerVisible = false

    private var allowsSpinner: Bool {
        guard showsIndicator else { return false }
        guard let shorterSide else { return true }
        return shorterSide >= Self.spinnerMinSide
    }

    /// Two structurally different views, not one view with a dead `.task`.
    ///
    /// `allowsSpinner` is a constant for any given instance — it reads only
    /// `let`/`var` inputs, never state — so this branch never flips and costs
    /// no identity churn. Splitting it is what actually removes the work: a
    /// `.task` whose body guards and returns still allocates and schedules a
    /// child task on every appear, which is exactly what the bootstrap frame
    /// and every 22pt avatar were paying for.
    var body: some View {
        if allowsSpinner {
            gated
        } else {
            shape.ground(ground).accessibilityHidden(true)
        }
    }

    private var gated: some View {
        ZStack {
            shape.ground(ground)
            if spinnerVisible { indicator }
        }
        // Torn down with the placeholder branch the moment the image lands, so
        // the sleep is cancelled rather than firing into a dead view. `try?`
        // swallows that cancellation, hence the explicit re-check: without it a
        // cancelled sleep would still flip the flag.
        //
        // The line inside is also the ONE point where an indicator comes into
        // existence, so it is the only honest place to count them. The
        // suspicion it settles is "~54 `UIActivityIndicatorView`s minted in one
        // frame": no existing counter could see that, because `img.appear`
        // counts cover CELLS and a cell resolving inside the gate mints
        // nothing. Noted BEFORE the state write, so the event's timestamp
        // precedes the invalidation it causes and `ImageDiagnostics`
        // attributes it to the frame gap that paid for it.
        .task {
            try? await Task.sleep(for: Self.spinnerDelay)
            guard !Task.isCancelled else { return }
            ImageDiagnostics.noteIndicatorShown(shorterSide: shorterSide)
            spinnerVisible = true
        }
        // Decorative: the surrounding row/card carries the real label, and 60
        // cells each announcing "in progress" is noise, not information.
        .accessibilityHidden(true)
    }

    /// The shipping indicator, or — under the A/B switch only — a static glyph
    /// of the same weight in the same slot. See `ImageLoadingIndicatorPolicy`.
    @ViewBuilder
    private var indicator: some View {
        let indicatorTint = tint ?? Color.biliAccent
        if ImageLoadingIndicatorPolicy.isStatic {
            Image(systemName: "circle.dashed")
                .font(.title3.weight(.light))
                .foregroundStyle(indicatorTint)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(indicatorTint)
        }
    }
}

/// The terminal, non-spinning state. Reached via `.onFailureView`, which wins
/// over `.placeholder` inside Kingfisher's `loadedImage == nil` branch.
///
/// The most common way to get here is not a dead network: `DelayRetryStrategy`
/// retries only `.responseError`, so `.emptySource` — a `URL(string:)` that
/// came back nil, which many call sites produce by passing `?? ""` — fails
/// immediately and permanently. That case has to read as "no image", not as
/// "still working".
struct FailedCover: View {
    let shape: ImageCoverShape
    var ground: Color = .imagePlaceholderOpaque
    var shorterSide: CGFloat?
    /// Shares an explicit override with `LoadingCover.tint`, such as white over
    /// the previewer's black backdrop. Failure keeps `.secondary` when nil;
    /// only loading defaults to the app's semantic accent.
    var tint: Color?

    /// A circular slot is a face: reuse the `person.fill` idiom `AvatarImage`
    /// already used for its own failure box, so a failed avatar still reads as
    /// an avatar slot instead of a generic broken-image marker.
    private var glyph: String {
        if case .circle = shape { "person.fill" } else { "photo" }
    }

    /// Same 0.42 proportion `AvatarImage` used, clamped so a 24pt badge and a
    /// full-screen preview both get a legible, unobtrusive glyph. `nil` (box
    /// unknown) lands mid-range rather than assuming either extreme.
    private var glyphSize: CGFloat {
        min(26, max(9, (shorterSide ?? 56) * 0.42))
    }

    var body: some View {
        ZStack {
            shape.ground(ground)
            Image(systemName: glyph)
                .resizable()
                .scaledToFit()
                .frame(width: glyphSize, height: glyphSize)
                .foregroundStyle(tint ?? .secondary)
        }
        .accessibilityHidden(true)
    }
}
