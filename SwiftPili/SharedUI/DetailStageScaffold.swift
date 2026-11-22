import QuartzCore
import SwiftUI

// The iPad landscape detail stage, shared by the video and bangumi pages:
// the hero/stage state and its scroll switch, the content column that scrolls
// under the pinned player, the floating comment panel, and the player's
// placement. Moved out of `VideoDetailView` unchanged; geometry stays in
// `DetailStageLayout`.

/// The user's choice of how an iPad landscape detail page opens. Single owner of
/// the stored key; Settings and the setup wizard bind to `startsInStageKey`.
enum DetailStagePreferences {
    static let startsInStageKey = "ipad_detail_starts_in_stage"

    /// `false` (default) opens in the hero; `true` opens directly in the stage.
    static var startsInStage: Bool {
        UserDefaults.standard.bool(forKey: startsInStageKey)
    }

    static var initialPresentation: DetailStagePresentation {
        startsInStage ? .stage : .hero
    }
}

/// Hero or stage for one page visit, and the clock that rate-limits switching.
///
/// A value held in the page's `@State`. The caller wraps `set` in its own
/// `withAnimation`, so each page keeps the hero ↔ stage spring it chooses.
struct DetailStageState: Equatable {
    private(set) var presentation: DetailStagePresentation
    /// Wall clock of the last switch: a switch moves the content column's top
    /// inset, which perturbs the very offset sample that decides the next one.
    private var lastFlipAt: CFTimeInterval = 0

    init(initialPresentation: DetailStagePresentation = DetailStagePreferences.initialPresentation) {
        presentation = initialPresentation
    }

    /// Switches and returns true, or returns false when already there.
    @discardableResult
    mutating func set(_ next: DetailStagePresentation) -> Bool {
        guard presentation != next else { return false }
        lastFlipAt = CACurrentMediaTime()
        presentation = next
        return true
    }

    /// The presentation a column scroll offset asks for, outside the cooldown.
    func target(forScrollOffset offset: CGFloat) -> DetailStagePresentation? {
        guard CACurrentMediaTime() - lastFlipAt > DetailStageSwitchPolicy.cooldown else { return nil }
        return DetailStageSwitchPolicy.next(current: presentation, offset: offset)
    }
}

/// The gradient fade where scrolled content meets the pinned player: a clear
/// gap down to `topInset - gap`, a short vertical gradient, then opaque.
struct DetailPinnedFadeMask: View {
    let topInset: CGFloat
    var gap: CGFloat = DetailStageLayout.columnGap

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(0, topInset - gap))
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: gap)
            Color.black
        }
    }
}

/// The content column that scrolls UNDER the pinned player and fades out at
/// the player's bottom edge, so nothing shows in the margin around the rounded
/// player. Only its top inset follows the hero/stage switch; the scroll view's
/// frame never changes. Reports the offset relative to the resting top.
struct CinematicStageColumn<Content: View>: View {
    let topInset: CGFloat
    let fadeGap: CGFloat
    /// Space under the content: the home-indicator clearance, plus the room
    /// the hero needs to scroll up into the stage even when its content fits.
    let bottomSpacer: CGFloat
    let onOffset: (CGFloat) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
                Color.clear.frame(height: bottomSpacer)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaPadding(.top, topInset)
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            onOffset(offset)
        }
        .mask { DetailPinnedFadeMask(topInset: topInset, gap: fadeGap) }
    }
}

/// The floating glass comment panel of the stage. Hidden in the hero (slid out
/// past the trailing edge, not hit-testable) but mounted, so a comment-target
/// navigation can scroll it the moment it appears.
struct CinematicStagePanel<Content: View>: View {
    let geometry: DetailStageLayout.Geometry
    let isStage: Bool
    var isKeyboardDocked = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DetailStageLayout.panelCornerRadius, style: .continuous)
        content()
            .frame(width: geometry.panelWidth)
            .frame(maxHeight: .infinity)
            .clipShape(shape)
            .background {
                // Keep the native Zoom host on a quiet content surface rather
                // than wrapping the comment list in decorative glass.
                Color.clear
                    .appCardSurface(in: shape)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.top, DetailStageLayout.outerMargin)
            .padding(.bottom, isKeyboardDocked ? AppSpacing.s : DetailStageLayout.outerMargin)
            .padding(.trailing, DetailStageLayout.outerMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .offset(x: isStage ? 0 : geometry.panelWidth + DetailStageLayout.outerMargin * 2)
            .opacity(isStage ? 1 : 0)
            .allowsHitTesting(isStage)
            .accessibilityHidden(!isStage)
    }
}

extension View {
    /// The stage player's box at its geometry's origin and the presentation's
    /// top margin. Corner rounding lives inside `PlayerView` (before
    /// `PlayerSeekStrip`) so the scrubber thumb is never clipped at the bottom
    /// edge in either compact or stage layout.
    func detailStagePlayerPlacement(
        isActive: Bool,
        geometry: DetailStageLayout.Geometry,
        presentation: DetailStagePresentation
    ) -> some View {
        padding(.leading, isActive ? geometry.playerOriginX : 0)
            .padding(.top, isActive ? DetailStageLayout.topMargin(for: presentation) : 0)
    }
}
