import Observation
import QuartzCore
import SwiftUI

enum DetailStagePreferences {
    static let startsInStageKey = "ipad_detail_starts_in_stage"

    static var startsInStage: Bool {
        UserDefaults.standard.bool(forKey: startsInStageKey)
    }

    static var initialPresentation: DetailStagePresentation {
        startsInStage ? .stage : .hero
    }
}

struct DetailStageState: Equatable, Sendable {
    private(set) var presentation: DetailStagePresentation
    private var lastFlipAt: CFTimeInterval = 0

    init(initialPresentation: DetailStagePresentation = DetailStagePreferences.initialPresentation) {
        presentation = initialPresentation
    }

    @discardableResult
    mutating func set(_ next: DetailStagePresentation) -> Bool {
        guard presentation != next else { return false }
        lastFlipAt = CACurrentMediaTime()
        presentation = next
        return true
    }

    func target(forScrollOffset offset: CGFloat) -> DetailStagePresentation? {
        guard CACurrentMediaTime() - lastFlipAt > DetailStageSwitchPolicy.cooldown else { return nil }
        return DetailStageSwitchPolicy.next(current: presentation, offset: offset)
    }
}

@MainActor
@Observable
final class DetailStageController {
    private(set) var state: DetailStageState
    var heroBarHeight: CGFloat = 0

    init(initialPresentation: DetailStagePresentation = DetailStagePreferences.initialPresentation) {
        state = DetailStageState(initialPresentation: initialPresentation)
    }

    var presentation: DetailStagePresentation { state.presentation }

    func showsHeroBar(isWideLayout: Bool) -> Bool {
        isWideLayout && presentation == .hero
    }

    func geometry(
        containerWidth: CGFloat,
        containerHeight: CGFloat
    ) -> DetailStageLayout.Geometry {
        DetailStageLayout.geometry(
            for: presentation,
            containerSize: CGSize(width: containerWidth, height: containerHeight),
            heroReserve: heroBarHeight > 0 ? heroBarHeight + DetailStageLayout.heroContentGap : 0
        )
    }

    func updateHeroBarHeight(_ height: CGFloat) {
        if height.isFinite, height > 0, abs(height - heroBarHeight) >= 1 {
            heroBarHeight = height
        }
    }

    static var transitionSpring: Animation {
        .spring(duration: 0.45, bounce: 0.12)
    }

    func transition(
        to next: DetailStagePresentation,
        isWideLayout: Bool,
        motion: AppMotionPreferences
    ) {
        guard isWideLayout, state.presentation != next else { return }
        withAnimation(motion.animation(normal: Self.transitionSpring)) {
            _ = state.set(next)
        }
    }

    func handleScroll(
        offset: CGFloat,
        isWideLayout: Bool,
        motion: AppMotionPreferences,
        logTag: String = "Stage"
    ) {
        guard isWideLayout, let next = state.target(forScrollOffset: offset) else { return }
        PlayerLog.log("[\(logTag)] \(state.presentation) → \(next) offset=\(Int(offset))")
        transition(to: next, isWideLayout: isWideLayout, motion: motion)
    }
}

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

struct CinematicStageColumn<Content: View>: View {
    let topInset: CGFloat
    let fadeGap: CGFloat
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
    func detailStagePlayerPlacement(
        isActive: Bool,
        geometry: DetailStageLayout.Geometry,
        presentation: DetailStagePresentation
    ) -> some View {
        padding(.leading, isActive ? geometry.playerOriginX : 0)
            .padding(.top, isActive ? DetailStageLayout.topMargin(for: presentation) : 0)
    }
}
