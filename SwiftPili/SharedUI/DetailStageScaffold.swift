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
    var minimumHeroBarReserveHeight: CGFloat = DetailStageLayout.defaultHeroBarHeight

    init(initialPresentation: DetailStagePresentation = DetailStagePreferences.initialPresentation) {
        state = DetailStageState(initialPresentation: initialPresentation)
    }

    var presentation: DetailStagePresentation { state.presentation }

    private var effectiveHeroBarHeight: CGFloat {
        heroBarHeight > 0 ? heroBarHeight : minimumHeroBarReserveHeight
    }

    func showsHeroBar(isWideLayout: Bool) -> Bool {
        isWideLayout && presentation == .hero
    }

    func geometry(
        containerWidth: CGFloat,
        containerHeight: CGFloat
    ) -> DetailStageLayout.Geometry {
        let reservedBarHeight = effectiveHeroBarHeight
        return DetailStageLayout.geometry(
            for: presentation,
            containerSize: CGSize(width: containerWidth, height: containerHeight),
            heroReserve: reservedBarHeight > 0 ? reservedBarHeight + DetailStageLayout.heroContentGap : 0
        )
    }

    static var heroBarHeightSpring: Animation {
        .spring(duration: 0.34, bounce: 0.08)
    }

    func updateHeroBarHeight(
        _ height: CGFloat,
        motion: AppMotionPreferences? = nil
    ) {
        guard height.isFinite, height > 0, abs(height - heroBarHeight) >= 1 else { return }
        let previousEffective = effectiveHeroBarHeight
        let effectiveMotion = motion ?? AppMotionPreferences.current
        if abs(height - previousEffective) >= 1,
           let animation = effectiveMotion.animation(normal: Self.heroBarHeightSpring) {
            withAnimation(animation) {
                heroBarHeight = height
            }
        } else {
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
    @AppMotion private var motion
    let topInset: CGFloat
    let fadeGap: CGFloat
    let bottomSpacer: CGFloat
    let scrollToTopTrigger: Int
    let onOffset: (CGFloat) -> Void
    let content: () -> Content

    init(
        topInset: CGFloat,
        fadeGap: CGFloat,
        bottomSpacer: CGFloat,
        scrollToTopTrigger: Int = 0,
        onOffset: @escaping (CGFloat) -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.topInset = topInset
        self.fadeGap = fadeGap
        self.bottomSpacer = bottomSpacer
        self.scrollToTopTrigger = scrollToTopTrigger
        self.onOffset = onOffset
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("detail-stage-column-top")
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
            .onChange(of: scrollToTopTrigger) { _, _ in
                withAnimation(motion.animation(normal: .easeInOut(duration: 0.28))) {
                    proxy.scrollTo("detail-stage-column-top", anchor: .top)
                }
            }
            .mask { DetailPinnedFadeMask(topInset: topInset, gap: fadeGap) }
        }
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
