import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import SwiftPili

@Suite("Dynamic Aspect Geometry & Portrait Mode", .serialized)
struct DynamicAspectAndPortraitModeTests {
    @discardableResult
    private static func approxEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.01) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    // MARK: - DetailPlayerGeometry.expandedVideoHeight

    @Test("expandedVideoHeight fills width cleanly from 21:9 through 3:4 and protects 136pt peek on 9:16")
    func expandedHeightAcrossAspectSpectrum() {
        let width: CGFloat = 390
        let screenHeight: CGFloat = 844
        let topSafe: CGFloat = 47

        // 21:9 cinema widescreen shrinks below 16:9 to eliminate top/bottom letterboxing
        let h21x9 = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 2.39
        )
        #expect(Self.approxEqual(h21x9, width / 2.39))
        #expect(h21x9 < width / (16.0 / 9.0))

        // Extreme ultrawide (> 2.4) clamps at maxUltrawideAspect
        let hUltra = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 3.2
        )
        #expect(Self.approxEqual(hUltra, width / DetailPlayerGeometry.maxUltrawideAspect))

        // 16:9 standard widescreen
        let h16x9 = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 16.0 / 9.0
        )
        #expect(Self.approxEqual(h16x9, width / (16.0 / 9.0)))

        // 4:3 classic anime / retro video fills full width with zero side bars
        let h4x3 = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 4.0 / 3.0
        )
        #expect(Self.approxEqual(h4x3, width / (4.0 / 3.0)))

        // 1:1 square
        let h1x1 = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 1.0
        )
        #expect(Self.approxEqual(h1x1, width))

        // 3:4 light portrait fills full width
        let h3x4 = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 0.75
        )
        #expect(Self.approxEqual(h3x4, width / 0.75))

        // 9:16 portrait respects 136pt bottom peek protection on iPhone (390x844, safeTop 47)
        let h9x16 = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 9.0 / 16.0
        )
        let expectedPeekCap = screenHeight - topSafe - DetailPlayerGeometry.minPeekHeight
        #expect(Self.approxEqual(h9x16, expectedPeekCap))
        #expect(screenHeight - topSafe - h9x16 >= DetailPlayerGeometry.minPeekHeight - 0.01)

        // Tall screen where natural 9:16 fits with > 136pt remaining uses natural height
        let tallScreenHeight: CGFloat = 1000
        let h9x16Tall = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: tallScreenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 9.0 / 16.0
        )
        #expect(Self.approxEqual(h9x16Tall, width / (9.0 / 16.0)))

        // Missing aspect falls back cleanly to 16:9 or 9:16 depending on isPortraitFallback
        let fallbackLandscape = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: nil,
            isPortraitFallback: false
        )
        #expect(Self.approxEqual(fallbackLandscape, h16x9))
        let fallbackPortrait = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: nil,
            isPortraitFallback: true
        )
        #expect(Self.approxEqual(fallbackPortrait, h9x16))
    }

    // MARK: - DetailPlayerGeometry.dynamicInlineVideoHeight

    @Test("dynamicInlineVideoHeight interpolates continuously and bidirectionally and respects manual lock")
    func dynamicInlineHeightContinuousInterpolationAndManualLock() {
        let width: CGFloat = 390
        let screenHeight: CGFloat = 844
        let topSafe: CGFloat = 47
        let aspect: CGFloat = 9.0 / 16.0

        let expanded = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: aspect
        )
        let compact = width / (16.0 / 9.0)
        let delta = expanded - compact
        #expect(delta > 200)

        // At top (scrollOffset == 0) -> fully expanded
        let atTop = DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: aspect,
            scrollOffset: 0
        )
        #expect(Self.approxEqual(atTop, expanded))

        // Midpoint scroll (scrollOffset == -delta / 2) -> exact midpoint
        let atMid = DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: aspect,
            scrollOffset: -delta / 2
        )
        #expect(Self.approxEqual(atMid, (expanded + compact) / 2))

        // Fully condensed (scrollOffset == -delta and beyond) -> compact 16:9
        let atEnd = DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: aspect,
            scrollOffset: -delta
        )
        #expect(Self.approxEqual(atEnd, compact))

        let beyondEnd = DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: aspect,
            scrollOffset: -delta * 2
        )
        #expect(Self.approxEqual(beyondEnd, compact))

        // Scrolling back to top restores expanded height seamlessly
        let backToTop = DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: aspect,
            scrollOffset: 0
        )
        #expect(Self.approxEqual(backToTop, expanded))

        // Overscrolling positive at top stays expanded (does not shrink)
        let overscrolled = DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: aspect,
            scrollOffset: 64
        )
        #expect(Self.approxEqual(overscrolled, expanded))

        // Manual lock condensed stays compact even at scrollOffset == 0
        let manualCondensed = DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: aspect,
            scrollOffset: 0,
            isManuallyCondensed: true,
            isManualLockActive: true
        )
        #expect(Self.approxEqual(manualCondensed, compact))

        // Manual lock expanded stays expanded even when scrolled deep down
        let manualExpanded = DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: aspect,
            scrollOffset: -delta * 2,
            isManuallyCondensed: false,
            isManualLockActive: true
        )
        #expect(Self.approxEqual(manualExpanded, expanded))

        // 21:9 video never grows when scrolled or when manual condensed lock is active
        let cinemaExpanded = DetailPlayerGeometry.expandedVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 2.39
        )
        let cinemaLockedCondensed = DetailPlayerGeometry.dynamicInlineVideoHeight(
            containerWidth: width,
            containerHeight: screenHeight,
            topSafeArea: topSafe,
            videoAspectRatio: 2.39,
            scrollOffset: -120,
            isManuallyCondensed: true,
            isManualLockActive: true
        )
        #expect(Self.approxEqual(cinemaLockedCondensed, cinemaExpanded))
    }

    @Test("DetailPlayerGeometry portrait classification uses 0.85 threshold with safe normalization")
    func portraitAspectClassification() {
        #expect(DetailPlayerGeometry.normalizedAspect(nil) == nil)
        #expect(DetailPlayerGeometry.normalizedAspect(.nan) == nil)
        #expect(DetailPlayerGeometry.normalizedAspect(0.1) == nil)
        #expect(DetailPlayerGeometry.normalizedAspect(5.5) == nil)
        #expect(DetailPlayerGeometry.normalizedAspect(4.0 / 3.0) != nil)

        #expect(DetailPlayerGeometry.isPortraitAspect(9.0 / 16.0) == true)
        #expect(DetailPlayerGeometry.isPortraitAspect(3.0 / 4.0) == true)
        #expect(DetailPlayerGeometry.isPortraitAspect(0.84) == true)
        #expect(DetailPlayerGeometry.isPortraitAspect(0.85) == false)
        #expect(DetailPlayerGeometry.isPortraitAspect(1.0) == false)
        #expect(DetailPlayerGeometry.isPortraitAspect(16.0 / 9.0) == false)
        #expect(DetailPlayerGeometry.isPortraitAspect(nil, fallback: true) == true)
        #expect(DetailPlayerGeometry.isPortraitAspect(nil, fallback: false) == false)
    }

    // MARK: - BiliAspectRatioURIParser & Model Hints

    @Test("BiliAspectRatioURIParser parses player_width/player_height/player_rotate and story fallback")
    func uriAspectRatioParsing() {
        let landscapeURI = "bilibili://video/123456?player_width=1920&player_height=1080&player_rotate=0"
        let landscapeRatio = BiliAspectRatioURIParser.parseAspectRatio(from: landscapeURI)
        #expect(landscapeRatio != nil)
        #expect(Self.approxEqual(landscapeRatio ?? 0, 16.0 / 9.0))

        // player_rotate=1 swaps width and height
        let rotatedURI = "bilibili://video/123456?player_width=1920&player_height=1080&player_rotate=1"
        let rotatedRatio = BiliAspectRatioURIParser.parseAspectRatio(from: rotatedURI)
        #expect(rotatedRatio != nil)
        #expect(Self.approxEqual(rotatedRatio ?? 0, 9.0 / 16.0))

        // 4:3 query dimensions
        let fourByThreeURI = "bilibili://video/789?player_width=1440&player_height=1080"
        let fourByThreeRatio = BiliAspectRatioURIParser.parseAspectRatio(from: fourByThreeURI)
        #expect(fourByThreeRatio != nil)
        #expect(Self.approxEqual(fourByThreeRatio ?? 0, 4.0 / 3.0))

        // Story URI without explicit dimensions falls back to 9:16
        let storyURI = "bilibili://story/999888?from=feed"
        let storyRatio = BiliAspectRatioURIParser.parseAspectRatio(from: storyURI)
        #expect(storyRatio != nil)
        #expect(Self.approxEqual(storyRatio ?? 0, 9.0 / 16.0))

        // Story URI with explicit dimensions uses the parsed dimensions
        let squareStoryURI = "bilibili://story/999888?player_width=1080&player_height=1080"
        let squareStoryRatio = BiliAspectRatioURIParser.parseAspectRatio(from: squareStoryURI)
        #expect(squareStoryRatio != nil)
        #expect(Self.approxEqual(squareStoryRatio ?? 0, 1.0))

        // Out-of-bounds or invalid URIs return nil
        #expect(BiliAspectRatioURIParser.parseAspectRatio(from: nil) == nil)
        #expect(BiliAspectRatioURIParser.parseAspectRatio(from: "   ") == nil)
        #expect(BiliAspectRatioURIParser.parseAspectRatio(from: "bilibili://video/1?player_width=0&player_height=1080") == nil)
        #expect(BiliAspectRatioURIParser.parseAspectRatio(from: "bilibili://video/1?player_width=10000&player_height=100") == nil)
        #expect(BiliAspectRatioURIParser.parseAspectRatio(from: "bilibili://video/1") == nil)
    }

    @Test("VideoInfo.Dimension effectiveAspectRatio handles rotation and PortraitPagingPreview derives portrait hint")
    func dimensionAndPreviewAspectDerivation() {
        let normal = VideoInfo.Dimension(width: 1440, height: 1080, rotate: 0)
        #expect(Self.approxEqual(normal.effectiveAspectRatio ?? 0, 4.0 / 3.0))

        let rotated = VideoInfo.Dimension(width: 1920, height: 1080, rotate: 1)
        #expect(Self.approxEqual(rotated.effectiveAspectRatio ?? 0, 9.0 / 16.0))
        #expect(rotated.isPortrait == true)

        let invalid = VideoInfo.Dimension(width: 0, height: 1080, rotate: 0)
        #expect(invalid.effectiveAspectRatio == nil)

        let portraitPreview = PortraitPagingPreview(title: "Vertical", aspectRatioHint: 9.0 / 16.0)
        #expect(Self.approxEqual(portraitPreview.aspectRatioHint ?? 0, 9.0 / 16.0))
        #expect(portraitPreview.isPortraitHint == true)

        let landscapePreview = PortraitPagingPreview(title: "Wide", aspectRatioHint: 4.0 / 3.0)
        #expect(Self.approxEqual(landscapePreview.aspectRatioHint ?? 0, 4.0 / 3.0))
        #expect(landscapePreview.isPortraitHint == false)

        let outOfRangePreview = PortraitPagingPreview(title: "Invalid", aspectRatioHint: 0.05)
        #expect(outOfRangePreview.aspectRatioHint == nil)
        #expect(outOfRangePreview.isPortraitHint == nil)

        let route = VideoRouteTarget.make(
            bvid: "BV1test123",
            aid: nil,
            title: "Story",
            aspectRatioHint: 9.0 / 16.0
        )
        #expect(route?.preview.isPortraitHint == true)
        #expect(Self.approxEqual(route?.preview.aspectRatioHint ?? 0, 9.0 / 16.0))
    }

    @Test("PortraitVODCondensationPolicy condensation progress calculation and edge guards")
    func condensationPolicyProgressCalculation() {
        #expect(PortraitVODCondensationPolicy.condensationProgress(scrollOffset: 0, expandedHeight: 600, compactHeight: 220) == 0)
        #expect(PortraitVODCondensationPolicy.condensationProgress(scrollOffset: 80, expandedHeight: 600, compactHeight: 220) == 0)
        #expect(Self.approxEqual(
            PortraitVODCondensationPolicy.condensationProgress(scrollOffset: -190, expandedHeight: 600, compactHeight: 220),
            0.5
        ))
        #expect(PortraitVODCondensationPolicy.condensationProgress(scrollOffset: -500, expandedHeight: 600, compactHeight: 220) == 1)
        #expect(PortraitVODCondensationPolicy.condensationProgress(scrollOffset: -100, expandedHeight: 220, compactHeight: 220) == 0)
        #expect(PortraitVODCondensationPolicy.condensationProgress(scrollOffset: .nan, expandedHeight: 600, compactHeight: 220) == 0)
        #expect(PortraitVODCondensationPolicy.condensationProgress(scrollOffset: -100, expandedHeight: .infinity, compactHeight: 220) == 0)
    }

    // MARK: - PortraitVideoPresentationMode Persistence

    @Test("PortraitVideoPresentationMode persists cleanly in UserDefaults and defaults to inlineExpandable")
    func portraitVideoModePersistence() {
        let suiteName = "DynamicAspectAndPortraitModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PlayerPlaybackPreferences.portraitVideoMode(from: defaults) == .inlineExpandable)

        PlayerPlaybackPreferences.setPortraitVideoMode(.immersiveFullscreen, in: defaults)
        #expect(defaults.string(forKey: PlayerPlaybackPreferences.portraitVideoModeKey) == "immersive_fullscreen")
        #expect(PlayerPlaybackPreferences.portraitVideoMode(from: defaults) == .immersiveFullscreen)

        PlayerPlaybackPreferences.setPortraitVideoMode(.inlineExpandable, in: defaults)
        #expect(defaults.string(forKey: PlayerPlaybackPreferences.portraitVideoModeKey) == "inline_expandable")
        #expect(PlayerPlaybackPreferences.portraitVideoMode(from: defaults) == .inlineExpandable)

        // Unknown raw value falls back safely to .inlineExpandable
        defaults.set("legacy_unknown_mode", forKey: PlayerPlaybackPreferences.portraitVideoModeKey)
        #expect(PlayerPlaybackPreferences.portraitVideoMode(from: defaults) == .inlineExpandable)
    }

    // MARK: - InAppMiniPlayerLayoutPolicy Dynamic Aspect

    @Test("InAppMiniPlayerLayoutPolicy.cardSize adapts to 4:3, 1:1, 9:16, and 21:9 with aspect clamping")
    func miniPlayerDynamicAspectClamping() {
        let phoneContainer = CGSize(width: 402, height: 874)

        // Legacy nil aspect keeps exact baseline sizes
        #expect(
            InAppMiniPlayerLayoutPolicy.cardSize(
                isPortrait: false,
                isPad: false,
                containerSize: phoneContainer,
                videoAspectRatio: nil
            ) == InAppMiniPlayerLayoutPolicy.phoneHorizontalSize
        )

        // 4:3 card tracks 4:3 ratio cleanly (avoiding 16:9 side black bars)
        let card4x3 = InAppMiniPlayerLayoutPolicy.cardSize(
            isPortrait: false,
            isPad: false,
            containerSize: phoneContainer,
            videoAspectRatio: 4.0 / 3.0
        )
        #expect(Self.approxEqual(card4x3.width / card4x3.height, 4.0 / 3.0, tolerance: 0.03))

        // 1:1 square card is square
        let card1x1 = InAppMiniPlayerLayoutPolicy.cardSize(
            isPortrait: false,
            isPad: false,
            containerSize: phoneContainer,
            videoAspectRatio: 1.0
        )
        #expect(Self.approxEqual(card1x1.width / card1x1.height, 1.0, tolerance: 0.02))

        // 9:16 portrait card matches 9:16
        let card9x16 = InAppMiniPlayerLayoutPolicy.cardSize(
            isPortrait: true,
            isPad: false,
            containerSize: phoneContainer,
            videoAspectRatio: 9.0 / 16.0
        )
        #expect(Self.approxEqual(card9x16.width / card9x16.height, 9.0 / 16.0, tolerance: 0.03))
        #expect(card9x16.height > card9x16.width)

        // Ultra-tall 9:24 (0.375) clamps to minCardAspect (9/16)
        let cardUltraTall = InAppMiniPlayerLayoutPolicy.cardSize(
            isPortrait: true,
            isPad: false,
            containerSize: phoneContainer,
            videoAspectRatio: 9.0 / 24.0
        )
        #expect(Self.approxEqual(cardUltraTall.width / cardUltraTall.height, InAppMiniPlayerLayoutPolicy.minCardAspect, tolerance: 0.03))

        // Ultrawide 2.8:1 clamps to maxCardAspect (2.2)
        let cardUltraWide = InAppMiniPlayerLayoutPolicy.cardSize(
            isPortrait: false,
            isPad: false,
            containerSize: phoneContainer,
            videoAspectRatio: 2.8
        )
        #expect(Self.approxEqual(cardUltraWide.width / cardUltraWide.height, InAppMiniPlayerLayoutPolicy.maxCardAspect, tolerance: 0.03))
    }

    // MARK: - PlayerPortraitFullscreenContext & PlayerViewModel Geometry

    @Test("PlayerViewModel applyAspectRatioHint and applyVideoGeometry keep videoAspectRatio synchronized")
    @MainActor
    func playerViewModelAspectHintAndDecodedGeometry() {
        let vm = PlayerViewModel.shared
        let savedAspect = vm.videoAspectRatio
        let savedPortrait = vm.isPortraitContent
        let savedPropagation = vm.portraitPropagation
        let savedPureView = vm.portraitPureViewEnabled
        let savedContext = vm.portraitFullscreenContext
        defer {
            vm.videoAspectRatio = savedAspect
            vm.isPortraitContent = savedPortrait
            vm.portraitPropagation = savedPropagation
            vm.portraitPureViewEnabled = savedPureView
            vm.portraitFullscreenContext = savedContext
        }

        vm.videoAspectRatio = nil
        vm.isPortraitContent = false
        vm.portraitPropagation = PlayerPortraitPropagationState(
            mode: .vod,
            apiHint: nil,
            initialIsPortrait: false
        )

        vm.applyAspectRatioHint(4.0 / 3.0)
        #expect(Self.approxEqual(vm.videoAspectRatio ?? 0, 4.0 / 3.0))

        // Decoded video geometry overrides pre-hint cleanly
        vm.applyVideoGeometry(CGSize(width: 1080, height: 1920))
        #expect(Self.approxEqual(vm.videoAspectRatio ?? 0, 9.0 / 16.0))

        // Subsequent stale hint does not overwrite already-decoded geometry
        vm.applyAspectRatioHint(16.0 / 9.0)
        #expect(Self.approxEqual(vm.videoAspectRatio ?? 0, 9.0 / 16.0))

        let lease = PlayerOwnerLease(owner: "vod-BV1test", generation: 1)
        let context = PlayerPortraitFullscreenContext(ownerLease: lease)
        context.title = "Portrait Demo"
        context.upName = "Creator"
        var loginRequested = false
        context.onRequestLogin = { loginRequested = true }
        vm.portraitFullscreenContext = context
        #expect(vm.portraitFullscreenContext?.ownerLease == lease)
        #expect(vm.portraitFullscreenContext?.title == "Portrait Demo")
        vm.portraitFullscreenContext?.onRequestLogin?()
        #expect(loginRequested == true)
    }

    // MARK: - Stage 2 Integration: OfflinePlayerLayout Dynamic Aspect

    @Test("OfflinePlayerLayout compact height adapts to 21:9, 16:9, 4:3, and 9:16 with 136pt peek and nil 16:9 fallback")
    func offlinePlayerLayoutDynamicAspectAndPeekProtection() {
        let container = CGSize(width: 390, height: 844)
        let topSafe: CGFloat = 47

        let layoutNil = OfflinePlayerLayout(
            containerSize: container,
            layoutContainerSize: container,
            isRegularWidth: false,
            supportsPadSplit: false,
            isPortraitContent: false,
            isCondensed: false,
            videoAspectRatio: nil,
            topSafeArea: topSafe
        )
        #expect(!layoutNil.isSplit)
        #expect(Self.approxEqual(layoutNil.playerSize.width, container.width))
        #expect(Self.approxEqual(layoutNil.playerSize.height, container.width / (16.0 / 9.0)))

        let layout21x9 = OfflinePlayerLayout(
            containerSize: container,
            layoutContainerSize: container,
            isRegularWidth: false,
            supportsPadSplit: false,
            isPortraitContent: false,
            isCondensed: false,
            videoAspectRatio: 21.0 / 9.0,
            topSafeArea: topSafe
        )
        #expect(Self.approxEqual(layout21x9.playerSize.height, container.width / (21.0 / 9.0)))
        #expect(layout21x9.playerSize.height < layoutNil.playerSize.height)

        let layout16x9 = OfflinePlayerLayout(
            containerSize: container,
            layoutContainerSize: container,
            isRegularWidth: false,
            supportsPadSplit: false,
            isPortraitContent: false,
            isCondensed: false,
            videoAspectRatio: 16.0 / 9.0,
            topSafeArea: topSafe
        )
        #expect(Self.approxEqual(layout16x9.playerSize.height, container.width / (16.0 / 9.0)))

        let layout4x3 = OfflinePlayerLayout(
            containerSize: container,
            layoutContainerSize: container,
            isRegularWidth: false,
            supportsPadSplit: false,
            isPortraitContent: false,
            isCondensed: false,
            videoAspectRatio: 4.0 / 3.0,
            topSafeArea: topSafe
        )
        #expect(Self.approxEqual(layout4x3.playerSize.height, container.width / (4.0 / 3.0)))
        #expect(layout4x3.playerSize.height > layout16x9.playerSize.height)

        let layout9x16 = OfflinePlayerLayout(
            containerSize: container,
            layoutContainerSize: container,
            isRegularWidth: false,
            supportsPadSplit: false,
            isPortraitContent: true,
            isCondensed: false,
            videoAspectRatio: 9.0 / 16.0,
            topSafeArea: topSafe
        )
        let expectedPeekCap = container.height - topSafe - DetailPlayerGeometry.minPeekHeight
        #expect(Self.approxEqual(layout9x16.playerSize.height, expectedPeekCap))
        #expect(container.height - topSafe - layout9x16.playerSize.height >= DetailPlayerGeometry.minPeekHeight - 0.01)

        // Nil aspect with isPortraitContent fallback matches 9:16 peek-protected height
        let layoutNilPortrait = OfflinePlayerLayout(
            containerSize: container,
            layoutContainerSize: container,
            isRegularWidth: false,
            supportsPadSplit: false,
            isPortraitContent: true,
            isCondensed: false,
            videoAspectRatio: nil,
            topSafeArea: topSafe
        )
        #expect(Self.approxEqual(layoutNilPortrait.playerSize.height, expectedPeekCap))

        // Condensed lock collapses 9:16 back to 16:9 while leaving 21:9 cinema unchanged
        let layout9x16Condensed = OfflinePlayerLayout(
            containerSize: container,
            layoutContainerSize: container,
            isRegularWidth: false,
            supportsPadSplit: false,
            isPortraitContent: true,
            isCondensed: true,
            videoAspectRatio: 9.0 / 16.0,
            topSafeArea: topSafe
        )
        #expect(Self.approxEqual(layout9x16Condensed.playerSize.height, layout16x9.playerSize.height))

        let layout21x9Condensed = OfflinePlayerLayout(
            containerSize: container,
            layoutContainerSize: container,
            isRegularWidth: false,
            supportsPadSplit: false,
            isPortraitContent: false,
            isCondensed: true,
            videoAspectRatio: 21.0 / 9.0,
            topSafeArea: topSafe
        )
        #expect(Self.approxEqual(layout21x9Condensed.playerSize.height, layout21x9.playerSize.height))
    }

    // MARK: - Stage 2 Integration: Context Lease Matching & ViewModel Reset Lifecycle

    @Test("PlayerPortraitFullscreenContext lease matching, portraitPureViewEnabled default/reset, and geometry lifecycle")
    @MainActor
    func portraitFullscreenContextLeaseAndResetLifecycle() {
        let vm = PlayerViewModel.shared
        let savedOwner = vm.ownerKey
        let savedAspect = vm.videoAspectRatio
        let savedPortrait = vm.isPortraitContent
        let savedPropagation = vm.portraitPropagation
        let savedPureView = vm.portraitPureViewEnabled
        let savedContext = vm.portraitFullscreenContext
        let savedFullscreen = vm.isFullscreen
        defer {
            vm.endCurrentOwnerPlayback()
            vm.ownerKey = savedOwner
            vm.videoAspectRatio = savedAspect
            vm.isPortraitContent = savedPortrait
            vm.portraitPropagation = savedPropagation
            vm.portraitPureViewEnabled = savedPureView
            vm.portraitFullscreenContext = savedContext
            vm.isFullscreen = savedFullscreen
        }

        // Default chrome state starts with Pure View disabled
        let freshChrome = PlayerChromeState()
        #expect(freshChrome.portraitPureViewEnabled == false)
        #expect(freshChrome.portraitFullscreenContext == nil)
        #expect(freshChrome.videoAspectRatio == nil)

        // Claim lease A, attach portrait context, enable Pure View, apply portrait aspect hint
        let leaseA = vm.claimOwnerLease(owner: "vod-BV1portraitA")
        let contextA = PlayerPortraitFullscreenContext(ownerLease: leaseA)
        contextA.title = "Vertical Clip A"
        vm.portraitFullscreenContext = contextA
        vm.portraitPureViewEnabled = true
        vm.portraitPropagation = PlayerPortraitPropagationState(
            mode: .vod,
            apiHint: nil,
            initialIsPortrait: false
        )
        vm.applyAspectRatioHint(9.0 / 16.0)

        #expect(PlayerPortraitChromePolicy.matchedContext(vm.portraitFullscreenContext, screenLease: leaseA) === contextA)
        #expect(PlayerPortraitChromePolicy.matchedContext(vm.portraitFullscreenContext, screenLease: nil) == nil)
        let staleLease = PlayerOwnerLease(owner: leaseA.owner, generation: leaseA.generation + 99)
        #expect(PlayerPortraitChromePolicy.matchedContext(vm.portraitFullscreenContext, screenLease: staleLease) == nil)
        #expect(Self.approxEqual(vm.videoAspectRatio ?? 0, 9.0 / 16.0))
        #expect(vm.isPortraitContent == DeviceCapability.usesCompactPortraitVideoFraming)

        // Invalid or tiny-delta aspect hints are ignored
        vm.applyAspectRatioHint(.nan)
        vm.applyAspectRatioHint(0.05)
        vm.applyAspectRatioHint((9.0 / 16.0) + 0.001)
        #expect(Self.approxEqual(vm.videoAspectRatio ?? 0, 9.0 / 16.0))

        // Decoded landscape geometry overrides pre-hint and sets isPortraitContent false
        vm.applyVideoGeometry(CGSize(width: 1920, height: 1080))
        #expect(Self.approxEqual(vm.videoAspectRatio ?? 0, 16.0 / 9.0))
        #expect(vm.isPortraitContent == false)

        // Subsequent stale portrait hint does not override decoded geometry
        vm.applyAspectRatioHint(9.0 / 16.0)
        #expect(Self.approxEqual(vm.videoAspectRatio ?? 0, 16.0 / 9.0))
        #expect(vm.isPortraitContent == false)

        // Stale lease exit must NOT wipe active lease A state
        _ = vm.endOwnerPlayback(lease: staleLease)
        #expect(vm.portraitFullscreenContext === contextA)
        #expect(vm.portraitPureViewEnabled == true)

        // Switching to a different owner resets videoAspectRatio, portraitPureViewEnabled, and portraitFullscreenContext
        let leaseB = vm.claimOwnerLease(owner: "vod-BV1portraitB")
        #expect(vm.videoAspectRatio == nil)
        #expect(vm.portraitPureViewEnabled == false)
        #expect(vm.portraitFullscreenContext == nil)
        #expect(PlayerPortraitChromePolicy.matchedContext(vm.portraitFullscreenContext, screenLease: leaseA) == nil)

        // Attaching lease B context + Pure View and exiting fullscreen resets Pure View cleanly
        let contextB = PlayerPortraitFullscreenContext(ownerLease: leaseB)
        vm.portraitFullscreenContext = contextB
        vm.portraitPureViewEnabled = true
        vm.isFullscreen = true
        vm.exitFullscreen()
        #expect(vm.isFullscreen == false)
        #expect(vm.portraitPureViewEnabled == false)
        #expect(PlayerPortraitChromePolicy.matchedContext(vm.portraitFullscreenContext, screenLease: leaseB) === contextB)

        // Ending owner B clears aspect, Pure View, and portrait context
        vm.portraitPureViewEnabled = true
        vm.videoAspectRatio = 0.75
        _ = vm.endOwnerPlayback(lease: leaseB)
        #expect(vm.videoAspectRatio == nil)
        #expect(vm.portraitPureViewEnabled == false)
        #expect(vm.portraitFullscreenContext == nil)
    }

    // MARK: - Stage 2 Integration: Chrome & Subtitle Overlay Policies

    @Test("PlayerPortraitChromePolicy handles Pure View guards, interaction opacity, and burst clamping")
    @MainActor
    func portraitChromeHelperPolicies() {
        #expect(PlayerPortraitChromePolicy.isPureViewActive(
            pureViewEnabled: true,
            isPlaybackUnavailable: false,
            isPlaybackEnded: false
        ) == true)
        #expect(PlayerPortraitChromePolicy.isPureViewActive(
            pureViewEnabled: true,
            isPlaybackUnavailable: true,
            isPlaybackEnded: false
        ) == false)
        #expect(PlayerPortraitChromePolicy.isPureViewActive(
            pureViewEnabled: true,
            isPlaybackUnavailable: false,
            isPlaybackEnded: true
        ) == false)
        #expect(PlayerPortraitChromePolicy.isPureViewActive(
            pureViewEnabled: false,
            isPlaybackUnavailable: false,
            isPlaybackEnded: false
        ) == false)

        #expect(PlayerPortraitChromePolicy.chromeOpacity(isInteracting: false) == 1.0)
        #expect(PlayerPortraitChromePolicy.chromeOpacity(isInteracting: true) == 0.14)

        let screen = CGSize(width: 390, height: 844)
        // Corner tap clamps within safe horizontal/vertical margins
        let topLeft = PlayerPortraitChromePolicy.clampedBurstPosition(CGPoint(x: 4, y: 10), in: screen)
        #expect(topLeft == CGPoint(x: PlayerPortraitChromePolicy.burstMarginX, y: PlayerPortraitChromePolicy.burstMarginY))
        let bottomRight = PlayerPortraitChromePolicy.clampedBurstPosition(CGPoint(x: 388, y: 840), in: screen)
        #expect(bottomRight == CGPoint(
            x: screen.width - PlayerPortraitChromePolicy.burstMarginX,
            y: screen.height - PlayerPortraitChromePolicy.burstMarginY
        ))
        // Interior point passes through unchanged
        let interior = PlayerPortraitChromePolicy.clampedBurstPosition(CGPoint(x: 180, y: 400), in: screen)
        #expect(interior == CGPoint(x: 180, y: 400))
        // Nil or non-finite location falls back to viewport center
        let fallbackNil = PlayerPortraitChromePolicy.clampedBurstPosition(nil, in: screen)
        #expect(fallbackNil == CGPoint(x: 195, y: 422))
        let fallbackNaN = PlayerPortraitChromePolicy.clampedBurstPosition(CGPoint(x: CGFloat.nan, y: 200), in: screen)
        #expect(fallbackNaN == CGPoint(x: 195, y: 422))

        // Portrait Story ergonomic layout constants & rounded-bezel safe-area clearance
        #expect(PlayerPortraitChromePolicy.rightRailExtraBottomLift == 18)
        #expect(PlayerPortraitChromePolicy.rightRailItemSpacing == 13)
        #expect(PlayerPortraitChromePolicy.bottomDockHeight == 44)
        #expect(PlayerPortraitChromePolicy.bottomDockHorizontalPadding == 20)
        #expect(PlayerPortraitChromePolicy.seekBarHorizontalInset == 16)
        #expect(PlayerPortraitChromePolicy.bottomGradientBaseHeight == 240)
        #expect(PlayerPortraitChromePolicy.bottomDockBottomPadding(bottomSafeArea: 34) == 34)
        #expect(PlayerPortraitChromePolicy.bottomDockBottomPadding(bottomSafeArea: 20) == 20)
        #expect(PlayerPortraitChromePolicy.bottomDockBottomPadding(bottomSafeArea: 12) == 14)
        #expect(PlayerPortraitChromePolicy.bottomDockBottomPadding(bottomSafeArea: 4) == 14)
        #expect(PlayerPortraitChromePolicy.bottomDockBottomPadding(bottomSafeArea: 0) == 14)

        // Verify modern Pro/Pro Max 55pt physical display corner radius never clips bottom dock or comment composer
        let cornerRadius: CGFloat = 55
        for safeBottom: CGFloat in [34, 20, 12, 0] {
            let bottomPad = PlayerPortraitChromePolicy.bottomDockBottomPadding(bottomSafeArea: safeBottom)
            let dx = cornerRadius - PlayerPortraitChromePolicy.bottomDockHorizontalPadding
            let dy = cornerRadius - bottomPad
            #expect(hypot(dx, dy) < cornerRadius)
        }

        let restingCommentBottom = CommentComposerMorphContainer<EmptyView>.resolvedBottomPadding(
            ignoresContainerBottomSafeArea: true,
            physicalBottomSafeArea: 34,
            keyboardEffectiveBottomInset: 34
        )
        #expect(restingCommentBottom == 40)
        #expect(
            hypot(
                cornerRadius - CommentComposerMorphContainer<EmptyView>.bezelAwareHorizontalPadding,
                cornerRadius - restingCommentBottom
            ) < cornerRadius
        )

        let keyboardActiveCommentBottom = CommentComposerMorphContainer<EmptyView>.resolvedBottomPadding(
            ignoresContainerBottomSafeArea: true,
            physicalBottomSafeArea: 34,
            keyboardEffectiveBottomInset: 336
        )
        #expect(keyboardActiveCommentBottom == IPadKeyboardComposerLayout.keyboardBottomSpacing)

        let standardContainerCommentBottom = CommentComposerMorphContainer<EmptyView>.resolvedBottomPadding(
            ignoresContainerBottomSafeArea: false,
            physicalBottomSafeArea: 34,
            keyboardEffectiveBottomInset: 34
        )
        #expect(standardContainerCommentBottom == IPadKeyboardComposerLayout.keyboardBottomSpacing)

        let portraitChromeInsets = PlayerChromeInsets.resolve(
            presentation: .fullscreen,
            windowTop: 59,
            windowBottom: 34,
            windowLeft: 0,
            windowRight: 0,
            isPortraitViewport: true
        )
        #expect(portraitChromeInsets.top == 59)
        #expect(portraitChromeInsets.bottom == 34)
        #expect(portraitChromeInsets.horizontal == 16)

        let landscapeChromeInsets = PlayerChromeInsets.resolve(
            presentation: .fullscreen,
            windowTop: 0,
            windowBottom: 21,
            windowLeft: 0,
            windowRight: 0,
            isPortraitViewport: false
        )
        #expect(landscapeChromeInsets.horizontal == 24)

        #expect(PlayerDanmakuOverlay.topInsetViewportHeight(totalHeight: 852, topSafeInset: 59) == 793)
        #expect(PlayerPortraitFullscreenContext.normalizedDescriptionPreview("  第一行\n\n  第二行  ") == "第一行 第二行")
        #expect(PlayerPortraitFullscreenContext.normalizedDescriptionPreview("-") == nil)
        #expect(PlayerPortraitFullscreenContext.normalizedDescriptionPreview("   \n ") == nil)
        #expect(DanmakuSymbolIcon.activeSymbolName == "bubble.left.and.text.bubble.right.fill")
        #expect(DanmakuSymbolIcon.inactiveSymbolName == "bubble.left.and.text.bubble.right")
    }

    @Test("PlayerSubtitleLayoutPadding avoids portrait chrome rail/metadata and reverts in Pure View, live, landscape, and inline")
    func subtitleOverlayPortraitChromeAvoidance() {
        #expect(PlayerSubtitleLayoutPadding.portraitAvoidanceBaseBottom == 158)

        // Portrait VOD fullscreen with home indicator (34pt > 12pt floor -> +22pt extra safe area)
        let portraitVOD = PlayerSubtitleLayoutPadding.resolve(
            isFullscreenHost: true,
            isPlayerFullscreen: true,
            isPortraitContent: true,
            mode: .vod,
            portraitPureViewEnabled: false,
            portraitChromeBottomInset: 34,
            styleBottomOffset: 8
        )
        #expect(portraitVOD.avoidsPortraitAlwaysOnChrome == true)
        #expect(portraitVOD.leading == 20)
        #expect(portraitVOD.trailing == 64)
        #expect(Self.approxEqual(
            portraitVOD.bottom,
            PlayerSubtitleLayoutPadding.portraitAvoidanceBaseBottom
                + (34 - PlayerChromeInsets.fullscreenBottomFloor) + 8
        ))

        // Portrait offline fullscreen also avoids portrait chrome (bottom inset at floor adds 0 extra)
        let portraitOffline = PlayerSubtitleLayoutPadding.resolve(
            isFullscreenHost: true,
            isPlayerFullscreen: true,
            isPortraitContent: true,
            mode: .offline,
            portraitPureViewEnabled: false,
            portraitChromeBottomInset: PlayerChromeInsets.fullscreenBottomFloor,
            styleBottomOffset: 0
        )
        #expect(portraitOffline.avoidsPortraitAlwaysOnChrome == true)
        #expect(portraitOffline.leading == 20)
        #expect(portraitOffline.trailing == 64)
        #expect(Self.approxEqual(portraitOffline.bottom, PlayerSubtitleLayoutPadding.portraitAvoidanceBaseBottom))

        // Pure View turns off portrait avoidance and restores centered fullscreen padding
        let pureView = PlayerSubtitleLayoutPadding.resolve(
            isFullscreenHost: true,
            isPlayerFullscreen: true,
            isPortraitContent: true,
            mode: .vod,
            portraitPureViewEnabled: true,
            portraitChromeBottomInset: 34,
            styleBottomOffset: 8
        )
        #expect(pureView.avoidsPortraitAlwaysOnChrome == false)
        #expect(pureView.leading == 24)
        #expect(pureView.trailing == 24)
        #expect(Self.approxEqual(pureView.bottom, 52 + 8))

        // Live mode does not use portrait VOD chrome avoidance
        let portraitLive = PlayerSubtitleLayoutPadding.resolve(
            isFullscreenHost: true,
            isPlayerFullscreen: true,
            isPortraitContent: true,
            mode: .live,
            portraitPureViewEnabled: false,
            portraitChromeBottomInset: 34,
            styleBottomOffset: 0
        )
        #expect(portraitLive.avoidsPortraitAlwaysOnChrome == false)
        #expect(portraitLive.leading == 24)
        #expect(portraitLive.trailing == 24)
        #expect(Self.approxEqual(portraitLive.bottom, 52))

        // Inline portrait uses standard inline padding
        let inlinePortrait = PlayerSubtitleLayoutPadding.resolve(
            isFullscreenHost: false,
            isPlayerFullscreen: false,
            isPortraitContent: true,
            mode: .vod,
            portraitPureViewEnabled: false,
            portraitChromeBottomInset: 0,
            styleBottomOffset: 4
        )
        #expect(inlinePortrait.avoidsPortraitAlwaysOnChrome == false)
        #expect(inlinePortrait.leading == 24)
        #expect(inlinePortrait.trailing == 24)
        #expect(Self.approxEqual(inlinePortrait.bottom, 28 + 4))
    }

    @Test("PortraitPagingPolicy, PortraitVideoPresentationMode, and PortraitVODCondensationPolicy auto-collapse guards")
    func portraitPagingAndPresentationPolicies() {
        #expect(PortraitPagingPolicy.allowsVerticalPaging(on: .onlineDetail) == false)
        #expect(PortraitPagingPolicy.allowsVerticalPaging(on: .offlinePlayback) == false)
        #expect(PortraitPagingPolicy.allowsVerticalPaging(on: .shorts) == PortraitPagingPolicy.shortsFeedEnabled)

        #expect(PortraitVideoPresentationMode.allCases == [.inlineExpandable, .immersiveFullscreen])
        #expect(!PortraitVideoPresentationMode.inlineExpandable.label.isEmpty)
        #expect(!PortraitVideoPresentationMode.immersiveFullscreen.label.isEmpty)

        #expect(PortraitVODCondensationPolicy.shouldAutoCollapse(offset: -61, isCondensed: false, hasManualChoice: false) == true)
        #expect(PortraitVODCondensationPolicy.shouldAutoCollapse(offset: -60, isCondensed: false, hasManualChoice: false) == false)
        #expect(PortraitVODCondensationPolicy.shouldAutoCollapse(offset: -90, isCondensed: true, hasManualChoice: false) == false)
        #expect(PortraitVODCondensationPolicy.shouldAutoCollapse(offset: -90, isCondensed: false, hasManualChoice: true) == false)
        #expect(PortraitVODCondensationPolicy.shouldAutoCollapse(offset: .nan, isCondensed: false, hasManualChoice: false) == false)
    }

    // MARK: - Stage 3 Integration: Immersive Stage, Vertical Paging & Feed Session

    private struct IsolatedFilterEnv {
        let store: LocalContentFilterStore
        let url: URL
        let suiteName: String
        let defaults: UserDefaults

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    @MainActor
    private final class StubPortraitBlocklist: PortraitImmersiveBlocklistChecking {
        var blockedMIDs: Set<Int>

        init(blockedMIDs: Set<Int> = []) {
            self.blockedMIDs = blockedMIDs
        }

        func isBlocked(_ mid: Int) -> Bool {
            blockedMIDs.contains(mid)
        }
    }

    private actor FetchRecorder {
        private(set) var indices: [Int] = []

        func record(_ idx: Int) {
            indices.append(idx)
        }
    }

    @MainActor
    private static func makeIsolatedFilterStore() throws -> IsolatedFilterEnv {
        let id = UUID().uuidString
        let suiteName = "com.swiftpili.tests.portraitimmersive.\(id)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPiliPortraitImmersiveTests-\(id)", isDirectory: true)
            .appendingPathComponent("rules.json", isDirectory: false)
        let store = LocalContentFilterStore(
            storageURL: url,
            userDefaults: defaults,
            keyPrefix: "test_pi_lcf_\(id)",
            observesCloudBlocklist: false
        )
        return IsolatedFilterEnv(store: store, url: url, suiteName: suiteName, defaults: defaults)
    }

    private static func makeVideoCard(
        aid: Int,
        bvid: String,
        title: String,
        ownerMid: Int = 10,
        ownerName: String = "Creator",
        dimension: VideoInfo.Dimension?
    ) -> VideoCard {
        VideoCard(
            aid: aid,
            bvid: bvid,
            title: title,
            pic: "https://example.com/\(bvid).jpg",
            cover43: nil,
            duration: 60,
            dimension: dimension,
            owner: VideoInfo.VideoOwner(mid: ownerMid, name: ownerName, face: ""),
            stat: VideoInfo.VideoStat(view: 100, danmaku: 5, reply: 2, favorite: 3, coin: 1, share: 1, like: 10)
        )
    }

    private static func makeQueueItem(
        id: String,
        aid: Int,
        cid: Int,
        bvid: String,
        title: String,
        aspectRatioHint: CGFloat? = 9.0 / 16.0
    ) -> PlaybackQueueItem {
        let isPortrait = aspectRatioHint.map { $0 < 0.95 }
        let target = VideoRouteTarget(
            videoID: .bvid(bvid),
            preview: PortraitPagingPreview(
                title: title,
                coverURL: "https://example.com/\(bvid).jpg",
                ownerName: "Owner",
                durationSeconds: 45,
                isPortraitHint: isPortrait,
                aspectRatioHint: aspectRatioHint
            )
        )
        return PlaybackQueueItem(
            id: id,
            aid: aid,
            cid: cid,
            bvid: bvid,
            title: title,
            artist: "Owner",
            coverURL: "https://example.com/\(bvid).jpg",
            duration: 45,
            isPortraitHint: isPortrait,
            aspectRatioHint: aspectRatioHint,
            source: .ugc,
            originRoute: .videoDetail(target),
            originScreenRoute: .video(.bvid(bvid))
        )
    }

    @Test("PortraitPagingPolicy.allowsVerticalPaging(on:isImmersiveStage:itemCount:) enforces immersive stage and multi-item count across routes")
    func portraitPagingPolicyImmersiveAndItemCountMatrix() {
        let routes: [PortraitPagingRoute] = [.onlineDetail, .offlinePlayback, .shorts]
        for route in routes {
            // Inline mode never allows vertical paging regardless of item count
            #expect(PortraitPagingPolicy.allowsVerticalPaging(on: route, isImmersiveStage: false, itemCount: 0) == false)
            #expect(PortraitPagingPolicy.allowsVerticalPaging(on: route, isImmersiveStage: false, itemCount: 1) == false)
            #expect(PortraitPagingPolicy.allowsVerticalPaging(on: route, isImmersiveStage: false, itemCount: 5) == false)

            // Immersive stage requires at least 2 items
            #expect(PortraitPagingPolicy.allowsVerticalPaging(on: route, isImmersiveStage: true, itemCount: 0) == false)
            #expect(PortraitPagingPolicy.allowsVerticalPaging(on: route, isImmersiveStage: true, itemCount: 1) == false)
            #expect(PortraitPagingPolicy.allowsVerticalPaging(on: route, isImmersiveStage: true, itemCount: 2) == true)
            #expect(PortraitPagingPolicy.allowsVerticalPaging(on: route, isImmersiveStage: true, itemCount: 12) == true)
        }
    }

    @Test("PortraitImmersiveStagePolicy enforces Mode D, wide/compact layout, collapse lock, inline scroll, and 0.85 aspect boundary")
    func portraitImmersiveStagePolicyGuards() {
        // shouldEnterOnInitialOpen: Mode A never auto-enters
        #expect(PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: .inlineExpandable,
            isWideLayout: false,
            usesCompactFraming: true,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: true
        ) == false)

        // Mode D enters on compact non-wide portrait (< 0.85) or portrait fallback
        #expect(PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: false
        ) == true)
        #expect(PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            aspectRatio: 0.84,
            isPortraitFallback: false
        ) == true)
        #expect(PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            aspectRatio: 0.85,
            isPortraitFallback: true
        ) == false)
        #expect(PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            aspectRatio: 16.0 / 9.0,
            isPortraitFallback: false
        ) == false)
        #expect(PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            aspectRatio: nil,
            isPortraitFallback: true
        ) == true)
        #expect(PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            aspectRatio: nil,
            isPortraitFallback: false
        ) == false)

        // Wide layout & non-compact framing guards
        #expect(PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: .immersiveFullscreen,
            isWideLayout: true,
            usesCompactFraming: true,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: true
        ) == false)
        #expect(PortraitImmersiveStagePolicy.shouldEnterOnInitialOpen(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: false,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: true
        ) == false)

        // shouldPromoteAfterMetadataLoad: happy path in Mode D for portrait aspect
        #expect(PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            isAlreadyImmersive: false,
            userCollapsedCurrentVideo: false,
            userHasScrolledInline: false,
            aspectRatio: 3.0 / 4.0,
            isPortraitFallback: false
        ) == true)

        // Blocked by Mode A
        #expect(PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: .inlineExpandable,
            isWideLayout: false,
            usesCompactFraming: true,
            isAlreadyImmersive: false,
            userCollapsedCurrentVideo: false,
            userHasScrolledInline: false,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: true
        ) == false)

        // Blocked by wide layout or non-compact framing
        #expect(PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: .immersiveFullscreen,
            isWideLayout: true,
            usesCompactFraming: true,
            isAlreadyImmersive: false,
            userCollapsedCurrentVideo: false,
            userHasScrolledInline: false,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: true
        ) == false)
        #expect(PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: false,
            isAlreadyImmersive: false,
            userCollapsedCurrentVideo: false,
            userHasScrolledInline: false,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: true
        ) == false)

        // Blocked when already immersive, user collapsed current video, or user scrolled inline
        #expect(PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            isAlreadyImmersive: true,
            userCollapsedCurrentVideo: false,
            userHasScrolledInline: false,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: true
        ) == false)
        #expect(PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            isAlreadyImmersive: false,
            userCollapsedCurrentVideo: true,
            userHasScrolledInline: false,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: true
        ) == false)
        #expect(PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            isAlreadyImmersive: false,
            userCollapsedCurrentVideo: false,
            userHasScrolledInline: true,
            aspectRatio: 9.0 / 16.0,
            isPortraitFallback: true
        ) == false)

        // Landscape aspect never promotes
        #expect(PortraitImmersiveStagePolicy.shouldPromoteAfterMetadataLoad(
            mode: .immersiveFullscreen,
            isWideLayout: false,
            usesCompactFraming: true,
            isAlreadyImmersive: false,
            userCollapsedCurrentVideo: false,
            userHasScrolledInline: false,
            aspectRatio: 16.0 / 9.0,
            isPortraitFallback: true
        ) == false)
    }

    @Test("PortraitImmersiveFeedSession reset, PlaybackQueueContext backing, and syncPlaybackQueue updates")
    @MainActor
    func immersiveFeedSessionResetAndQueueSync() {
        let session = PortraitImmersiveFeedSession()
        session.reducer.updateContainerHeight(844)

        let zoomID = UUID()
        let initialTarget = VideoRouteTarget(
            videoID: .bvid("BV1Initial001"),
            preview: PortraitPagingPreview(title: "Initial", aspectRatioHint: 9.0 / 16.0),
            zoomSourceID: zoomID
        )

        // Reset without active queue starts with single zoom-stripped entry and preserves containerHeight
        session.reset(initialTarget: initialTarget, preferredCid: 2001, activeQueue: nil)
        #expect(session.isBackedByPlaybackQueue == false)
        #expect(session.entries.count == 1)
        #expect(session.reducer.itemCount == 1)
        #expect(session.reducer.currentIndex == 0)
        #expect(Self.approxEqual(session.reducer.containerHeight, 844))
        #expect(session.currentEntry?.target.videoID == .bvid("BV1Initial001"))
        #expect(session.currentEntry?.target.zoomSourceID == nil)
        #expect(session.currentEntry?.preferredCid == 2001)
        #expect(session.currentEntry?.queueItemID == nil)

        // Reset with PlaybackQueueContext mirrors queue items, index, cid, and blocks recommendation refill
        let item1 = Self.makeQueueItem(id: "q-1", aid: 11, cid: 1101, bvid: "BV1Queue001", title: "Queue 1")
        let item2 = Self.makeQueueItem(id: "q-2", aid: 12, cid: 1201, bvid: "BV1Queue002", title: "Queue 2")
        let item3 = Self.makeQueueItem(id: "q-3", aid: 13, cid: 1301, bvid: "BV1Queue003", title: "Queue 3", aspectRatioHint: 16.0 / 9.0)
        let queue = PlaybackQueueContext(
            kind: .playlist(name: "Watch Later"),
            items: [item1, item2, item3],
            currentIndex: 1
        )
        session.reset(initialTarget: initialTarget, preferredCid: nil, activeQueue: queue)
        #expect(session.isBackedByPlaybackQueue == true)
        #expect(session.entries.map(\.id) == ["q-1", "q-2", "q-3"])
        #expect(session.reducer.itemCount == 3)
        #expect(session.reducer.currentIndex == 1)
        #expect(session.currentEntry?.queueItemID == "q-2")
        #expect(session.currentEntry?.preferredCid == 1201)
        #expect(session.shouldRefillRecommendations() == false)

        // Related ingestion is ignored while backed by an active playback queue
        let extraCard = Self.makeVideoCard(
            aid: 99,
            bvid: "BV1Extra099",
            title: "Ignored While Queued",
            dimension: VideoInfo.Dimension(width: 1080, height: 1920, rotate: 0)
        )
        session.ingestRelatedVideos([extraCard])
        #expect(session.entries.count == 3)

        // syncPlaybackQueue updates items and index when idle
        let item4 = Self.makeQueueItem(id: "q-4", aid: 14, cid: 1401, bvid: "BV1Queue004", title: "Queue 4")
        let updatedQueue = PlaybackQueueContext(
            kind: .playlist(name: "Watch Later"),
            items: [item1, item2, item3, item4],
            currentIndex: 2
        )
        session.syncPlaybackQueue(updatedQueue)
        #expect(session.isBackedByPlaybackQueue == true)
        #expect(session.entries.count == 4)
        #expect(session.reducer.itemCount == 4)
        #expect(session.reducer.currentIndex == 2)
        #expect(session.currentEntry?.id == "q-3")

        // While dragging, syncPlaybackQueue updates itemCount without clobbering active currentIndex
        #expect(session.reducer.beginDrag() == true)
        let shiftedQueue = PlaybackQueueContext(
            kind: .playlist(name: "Watch Later"),
            items: [item1, item2, item3, item4],
            currentIndex: 0
        )
        session.syncPlaybackQueue(shiftedQueue)
        #expect(session.reducer.phase == .dragging)
        #expect(session.reducer.currentIndex == 2)
        if let settlement = session.reducer.cancelDrag() {
            _ = session.reducer.completeSettlement(token: settlement.token)
        }
        #expect(session.reducer.phase == .idle)

        // syncPlaybackQueue(nil) detaches to the current entry cleanly
        session.syncPlaybackQueue(nil)
        #expect(session.isBackedByPlaybackQueue == false)
        #expect(session.entries.count == 1)
        #expect(session.reducer.itemCount == 1)
        #expect(session.reducer.currentIndex == 0)
        #expect(session.currentEntry?.target.videoID == .bvid("BV1Queue003"))
        #expect(session.currentEntry?.queueItemID == nil)
        #expect(session.currentEntry?.preferredCid == 1301)

        // syncPlaybackQueue re-attaches cleanly from detached feed mode
        session.syncPlaybackQueue(queue)
        #expect(session.isBackedByPlaybackQueue == true)
        #expect(session.entries.count == 3)
        #expect(session.reducer.currentIndex == 1)
    }

    @Test("PortraitImmersiveFeedSession.ingestRelatedVideos deduplicates, applies filter/blocklist, and orders portrait-first stably")
    @MainActor
    func immersiveFeedSessionRelatedIngestionFilteringAndOrdering() throws {
        let env = try Self.makeIsolatedFilterStore()
        defer { env.cleanup() }
        let blocklist = StubPortraitBlocklist(blockedMIDs: [600])

        env.store.blockUP(mid: 500, name: "LocalBlockedUP")
        _ = env.store.blockVideo(aid: 501, bvid: "BV1BlockedVid", title: "Blocked Video")
        _ = env.store.addTitleKeyword("spoiler", isRegex: false)

        let session = PortraitImmersiveFeedSession()
        let initialTarget = VideoRouteTarget(
            videoID: .bvid("BV1Initial001"),
            preview: PortraitPagingPreview(title: "Initial Portrait", aspectRatioHint: 9.0 / 16.0)
        )
        session.reset(initialTarget: initialTarget)

        let cards: [VideoCard] = [
            // Duplicate of initial video (lowercase bv prefix normalized)
            Self.makeVideoCard(aid: 100, bvid: "bv1Initial001", title: "Dup Initial", dimension: .init(width: 1080, height: 1920, rotate: 0)),
            // Landscape 16:9 #1 (should appear after portrait additions, before Landscape #2)
            Self.makeVideoCard(aid: 101, bvid: "BV1Land001", title: "Landscape 1", dimension: .init(width: 1920, height: 1080, rotate: 0)),
            // Portrait 9:16 #1
            Self.makeVideoCard(aid: 102, bvid: "BV1Port001", title: "Portrait 9:16", dimension: .init(width: 1080, height: 1920, rotate: 0)),
            // Filtered by BlocklistManager
            Self.makeVideoCard(aid: 103, bvid: "BV1CloudBlk", title: "Cloud Blocked UP", ownerMid: 600, dimension: .init(width: 1080, height: 1920, rotate: 0)),
            // Filtered by LocalContentFilterStore blocked UP
            Self.makeVideoCard(aid: 104, bvid: "BV1LocalUP", title: "Local Blocked UP", ownerMid: 500, dimension: .init(width: 1080, height: 1920, rotate: 0)),
            // Filtered by LocalContentFilterStore blocked video
            Self.makeVideoCard(aid: 501, bvid: "BV1BlockedVid", title: "Local Blocked Video", dimension: .init(width: 1080, height: 1920, rotate: 0)),
            // Filtered by LocalContentFilterStore title keyword (case-insensitive)
            Self.makeVideoCard(aid: 105, bvid: "BV1KeywordBlk", title: "Huge SPOILER inside", dimension: .init(width: 1080, height: 1920, rotate: 0)),
            // Portrait 3:4 #2
            Self.makeVideoCard(aid: 106, bvid: "BV1Port002", title: "Portrait 3:4", dimension: .init(width: 900, height: 1200, rotate: 0)),
            // Portrait via rotate == 1 #3
            Self.makeVideoCard(aid: 107, bvid: "BV1Port003", title: "Portrait Rotated", dimension: .init(width: 1920, height: 1080, rotate: 1)),
            // Landscape 16:9 #2
            Self.makeVideoCard(aid: 108, bvid: "BV1Land002", title: "Landscape 2", dimension: .init(width: 1920, height: 1080, rotate: 0)),
            // Duplicate within same batch
            Self.makeVideoCard(aid: 102, bvid: "BV1Port001", title: "Dup Portrait 1", dimension: .init(width: 1080, height: 1920, rotate: 0)),
            // Invalid empty BVID skipped
            Self.makeVideoCard(aid: 109, bvid: "   ", title: "Blank BVID", dimension: .init(width: 1080, height: 1920, rotate: 0)),
        ]

        session.ingestRelatedVideos(cards, filterStore: env.store, blocklist: blocklist)

        let bvids = session.entries.map(\.target.videoID)
        #expect(bvids == [
            .bvid("BV1Initial001"),
            .bvid("BV1Port001"),
            .bvid("BV1Port002"),
            .bvid("BV1Port003"),
            .bvid("BV1Land001"),
            .bvid("BV1Land002"),
        ])
        #expect(session.reducer.itemCount == 6)
        #expect(session.reducer.currentIndex == 0)

        // Second ingestion deduplicates by both BVID and AID across batches
        let secondBatch: [VideoCard] = [
            Self.makeVideoCard(aid: 106, bvid: "BV1DifferentBV", title: "Same AID as Port 2", dimension: .init(width: 1080, height: 1920, rotate: 0)),
            Self.makeVideoCard(aid: 999, bvid: "BV1Land001", title: "Same BVID as Land 1", dimension: .init(width: 1080, height: 1920, rotate: 0)),
            Self.makeVideoCard(aid: 110, bvid: "BV1Port004", title: "Fresh Portrait", dimension: .init(width: 1080, height: 1920, rotate: 0)),
        ]
        session.ingestRelatedVideos(secondBatch, filterStore: env.store, blocklist: blocklist)
        #expect(session.entries.map(\.target.videoID) == [
            .bvid("BV1Initial001"),
            .bvid("BV1Port001"),
            .bvid("BV1Port002"),
            .bvid("BV1Port003"),
            .bvid("BV1Land001"),
            .bvid("BV1Land002"),
            .bvid("BV1Port004"),
        ])
        #expect(session.reducer.itemCount == 7)
    }

    @Test("PortraitImmersiveFeedSession recommendation refill threshold, filtering, portrait-first order, and error recovery")
    @MainActor
    func immersiveFeedSessionRecommendationRefill() async throws {
        let env = try Self.makeIsolatedFilterStore()
        defer { env.cleanup() }
        let blocklist = StubPortraitBlocklist(blockedMIDs: [888])
        _ = env.store.addTitleKeyword("clickbait", isRegex: false)

        let recorder = FetchRecorder()
        let mockResult = RecommendResult(item: [
            // Non-av item ignored
            RecommendResult.RecommendItem(
                id: 200,
                bvid: "BV1LiveSkip",
                title: "Live Stream",
                pic: "https://example.com/live.jpg",
                pic4By3: nil,
                cover43: nil,
                duration: 0,
                owner: .init(mid: 20, name: "Streamer", face: ""),
                stat: nil,
                goto: "live",
                uri: "bilibili://live/200",
                roomId: 200
            ),
            // Landscape 16:9 recommendation (fallback after portraits)
            RecommendResult.RecommendItem(
                id: 201,
                bvid: "BV1RecLand1",
                title: "Recommended 16:9",
                pic: "https://example.com/land.jpg",
                pic4By3: nil,
                cover43: nil,
                duration: 120,
                owner: .init(mid: 21, name: "LandUP", face: ""),
                stat: nil,
                goto: "av",
                uri: "bilibili://video/201?player_width=1920&player_height=1080",
                roomId: nil
            ),
            // Blocked via cloud blocklist
            RecommendResult.RecommendItem(
                id: 202,
                bvid: "BV1RecBlocked",
                title: "Blocked Creator",
                pic: "https://example.com/blk.jpg",
                pic4By3: nil,
                cover43: nil,
                duration: 30,
                owner: .init(mid: 888, name: "Blocked", face: ""),
                stat: nil,
                goto: "av",
                uri: "bilibili://story/202",
                roomId: nil
            ),
            // Blocked via local title keyword
            RecommendResult.RecommendItem(
                id: 203,
                bvid: "BV1RecKeyword",
                title: "Total Clickbait Video",
                pic: "https://example.com/kw.jpg",
                pic4By3: nil,
                cover43: nil,
                duration: 30,
                owner: .init(mid: 23, name: "Spam", face: ""),
                stat: nil,
                goto: "av",
                uri: "bilibili://story/203",
                roomId: nil
            ),
            // Duplicate of existing entry
            RecommendResult.RecommendItem(
                id: 204,
                bvid: "BV1Seed001",
                title: "Duplicate Seed",
                pic: "https://example.com/dup.jpg",
                pic4By3: nil,
                cover43: nil,
                duration: 30,
                owner: .init(mid: 24, name: "SeedUP", face: ""),
                stat: nil,
                goto: "av",
                uri: "bilibili://story/204",
                roomId: nil
            ),
            // Portrait recommendation #1 via story URI
            RecommendResult.RecommendItem(
                id: 205,
                bvid: "BV1RecPort1",
                title: "Story Vertical",
                pic: "https://example.com/p1.jpg",
                pic4By3: nil,
                cover43: nil,
                duration: 40,
                owner: .init(mid: 25, name: "PortUP1", face: ""),
                stat: nil,
                goto: "av",
                uri: "bilibili://story/205",
                roomId: nil
            ),
            // Portrait recommendation #2 via explicit 3:4 dimensions
            RecommendResult.RecommendItem(
                id: 206,
                bvid: "BV1RecPort2",
                title: "Explicit 3:4",
                pic: "https://example.com/p2.jpg",
                pic4By3: nil,
                cover43: nil,
                duration: 50,
                owner: .init(mid: 26, name: "PortUP2", face: ""),
                stat: nil,
                goto: nil,
                uri: "bilibili://video/206?player_width=900&player_height=1200",
                roomId: nil
            ),
        ])

        let session = PortraitImmersiveFeedSession { idx in
            await recorder.record(idx)
            if idx == 2 {
                throw URLError(.notConnectedToInternet)
            }
            return mockResult
        }

        // Empty session does not request refill
        #expect(session.shouldRefillRecommendations(threshold: 3) == false)

        session.reset(
            initialTarget: VideoRouteTarget(
                videoID: .bvid("BV1Seed001"),
                preview: PortraitPagingPreview(title: "Seed", aspectRatioHint: 9.0 / 16.0)
            )
        )
        #expect(session.shouldRefillRecommendations(threshold: 3) == true)

        // Add 5 related items so remaining == 5 (> threshold 3) -> refill skipped
        let fillerCards = (1...5).map { idx in
            Self.makeVideoCard(
                aid: 300 + idx,
                bvid: "BV1Fill00\(idx)",
                title: "Fill \(idx)",
                dimension: .init(width: 1080, height: 1920, rotate: 0)
            )
        }
        session.ingestRelatedVideos(fillerCards, filterStore: env.store, blocklist: blocklist)
        #expect(session.entries.count == 6)
        #expect(session.shouldRefillRecommendations(threshold: 3) == false)
        await session.refillRecommendationsIfNeeded(threshold: 3, filterStore: env.store, blocklist: blocklist)
        #expect(await recorder.indices == [])

        // Move reducer to index 2 (remaining == 3 <= threshold 3) -> refill triggers
        session.reducer.syncItems(count: session.entries.count, currentIndex: 2)
        #expect(session.shouldRefillRecommendations(threshold: 3) == true)

        await session.refillRecommendationsIfNeeded(threshold: 3, filterStore: env.store, blocklist: blocklist)
        #expect(await recorder.indices == [1])
        #expect(session.isRefilling == false)
        #expect(session.entries.suffix(3).map(\.target.videoID) == [
            .bvid("BV1RecPort1"),
            .bvid("BV1RecPort2"),
            .bvid("BV1RecLand1"),
        ])
        #expect(session.reducer.itemCount == session.entries.count)

        // Move near tail and trigger failing refill (idx == 2) -> recovers isRefilling cleanly
        session.reducer.syncItems(count: session.entries.count, currentIndex: session.entries.count - 1)
        let countBeforeError = session.entries.count
        await session.refillRecommendationsIfNeeded(threshold: 3, filterStore: env.store, blocklist: blocklist)
        #expect(await recorder.indices == [1, 2])
        #expect(session.isRefilling == false)
        #expect(session.entries.count == countBeforeError)
    }

    @Test("PlayerViewModel.requestFullscreenTransition routes portrait button toggles to inline immersive handler and resets on owner teardown")
    @MainActor
    func playerViewModelInlinePortraitImmersiveRoutingAndTeardown() {
        let vm = PlayerViewModel.shared
        let savedOwner = vm.ownerKey
        let savedMode = vm.mode
        let savedPortrait = vm.isPortraitContent
        let savedFullscreen = vm.isFullscreen
        let savedPureView = vm.portraitPureViewEnabled
        let savedInlineImmersive = vm.isInlinePortraitImmersiveActive
        let savedHandler = vm.onRequestInlinePortraitImmersive
        let savedShowControls = vm.showControls
        let savedTransition = vm.fullscreenTransition
        defer {
            vm.hideControlsTask?.cancel()
            vm.hideControlsTask = nil
            vm.endCurrentOwnerPlayback()
            vm.ownerKey = savedOwner
            vm.mode = savedMode
            vm.isPortraitContent = savedPortrait
            vm.isFullscreen = savedFullscreen
            vm.portraitPureViewEnabled = savedPureView
            vm.isInlinePortraitImmersiveActive = savedInlineImmersive
            vm.onRequestInlinePortraitImmersive = savedHandler
            vm.showControls = savedShowControls
            vm.fullscreenTransition = savedTransition
            FullscreenOrientationLatch.shared.clear()
        }

        let leaseA = vm.claimOwnerLease(owner: "vod-BV1immRouteA")
        vm.mode = .vod
        vm.isPortraitContent = true
        vm.isFullscreen = false
        vm.isInlinePortraitImmersiveActive = false
        vm.portraitPureViewEnabled = true
        vm.showControls = false
        vm.hideControlsTask = Task { try? await Task.sleep(for: .seconds(30)) }

        var recordedTargets: [Bool] = []
        vm.onRequestInlinePortraitImmersive = { target in
            recordedTargets.append(target)
            vm.isInlinePortraitImmersiveActive = target
            return true
        }

        // Portrait VOD + .button -> enters inline immersive without entering modal fullscreen
        vm.requestFullscreenTransition(target: true, source: .button)
        #expect(recordedTargets == [true])
        #expect(vm.isInlinePortraitImmersiveActive == true)
        #expect(vm.isFullscreen == false)
        #expect(vm.portraitPureViewEnabled == false)
        #expect(vm.showControls == true)
        #expect(vm.hideControlsTask == nil)

        // Portrait VOD + .button exit -> leaves inline immersive and clears Pure View
        vm.portraitPureViewEnabled = true
        vm.requestFullscreenTransition(target: false, source: .button)
        #expect(recordedTargets == [true, false])
        #expect(vm.isInlinePortraitImmersiveActive == false)
        #expect(vm.portraitPureViewEnabled == false)
        #expect(vm.isFullscreen == false)

        // Offline portrait + .button also routes to inline immersive
        vm.mode = .offline
        vm.requestFullscreenTransition(target: true, source: .button)
        #expect(recordedTargets == [true, false, true])
        #expect(vm.isInlinePortraitImmersiveActive == true)
        vm.requestFullscreenTransition(target: false, source: .button)
        #expect(recordedTargets == [true, false, true, false])

        // Non-button source (.deviceOrientation) does NOT invoke inline immersive handler
        vm.mode = .vod
        vm.requestFullscreenTransition(target: true, source: .deviceOrientation)
        #expect(recordedTargets == [true, false, true, false])

        // Live mode does NOT invoke inline immersive handler even when portrait + .button
        vm.mode = .live
        vm.requestFullscreenTransition(target: true, source: .button)
        #expect(recordedTargets == [true, false, true, false])

        // Landscape VOD falls through to standard fullscreen transition instead of inline immersive handler
        vm.mode = .vod
        vm.isPortraitContent = false
        vm.requestFullscreenTransition(target: true, source: .button)
        #expect(recordedTargets == [true, false, true, false])
        #expect(vm.isInlinePortraitImmersiveActive == false)

        // Owner replacement resets isInlinePortraitImmersiveActive and onRequestInlinePortraitImmersive
        vm.isPortraitContent = true
        vm.isInlinePortraitImmersiveActive = true
        #expect(vm.onRequestInlinePortraitImmersive != nil)
        let leaseB = vm.claimOwnerLease(owner: "vod-BV1immRouteB")
        #expect(leaseB.owner != leaseA.owner)
        #expect(vm.isInlinePortraitImmersiveActive == false)
        #expect(vm.onRequestInlinePortraitImmersive == nil)

        // Owner teardown also resets both properties cleanly
        vm.isInlinePortraitImmersiveActive = true
        vm.onRequestInlinePortraitImmersive = { _ in true }
        _ = vm.endOwnerPlayback(lease: leaseB)
        #expect(vm.isInlinePortraitImmersiveActive == false)
        #expect(vm.onRequestInlinePortraitImmersive == nil)
    }

    // MARK: - SwiftPili Branded Share Studio & Poster Renderer

    @Test("SwiftPiliBrandArt renders vector app icon emblem in light and dark variants")
    func swiftPiliBrandArtRendersAppIcon() {
        let lightIcon = SwiftPiliBrandArt.appIconImage(side: 128, accent: .systemPink, isDark: false)
        let darkIcon = SwiftPiliBrandArt.appIconImage(side: 128, accent: .systemBlue, isDark: true)
        #expect(lightIcon.size == CGSize(width: 128, height: 128))
        #expect(darkIcon.size == CGSize(width: 128, height: 128))
        #expect(lightIcon.pngData()?.isEmpty == false)
        #expect(darkIcon.pngData()?.isEmpty == false)
    }

    @Test("ShareCardRenderer renders 1080px branded posters across themes, cover aspects, and intro toggles")
    func shareCardRendererPosterVariants() {
        let landscapeCover = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        let portraitCover = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640)).image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
        }

        let baseRequest = ShareCardRenderer.Request(
            coverURL: "",
            avatarURL: "",
            title: "SwiftPili Branded Share Poster Verification",
            uploader: "SwiftPiliCreator",
            description: "Detailed introduction text for testing description quote block height.",
            bvid: "BV1ShareTest",
            durationSeconds: 245,
            viewCount: 128_000,
            likeCount: 9_600,
            isPortraitCover: false,
            linkURL: "https://www.bilibili.com/video/BV1ShareTest",
            linkDisplay: "bilibili.com/video/BV1ShareTest",
            accent: .systemPink,
            style: .ambientDark,
            includesDescription: true
        )

        let darkWithDesc = ShareCardRenderer.renderSynchronously(
            request: baseRequest,
            cover: landscapeCover
        )
        #expect(darkWithDesc.size.width == 1080)
        #expect(darkWithDesc.size.height > 1100)

        var lightWithoutDescReq = baseRequest
        lightWithoutDescReq.style = .editorialLight
        lightWithoutDescReq.includesDescription = false
        let lightWithoutDesc = ShareCardRenderer.renderSynchronously(
            request: lightWithoutDescReq,
            cover: landscapeCover
        )
        #expect(lightWithoutDesc.size.width == 1080)
        #expect(darkWithDesc.size.height > lightWithoutDesc.size.height)

        var portraitReq = baseRequest
        portraitReq.isPortraitCover = true
        let portraitPoster = ShareCardRenderer.renderSynchronously(
            request: portraitReq,
            cover: portraitCover
        )
        #expect(portraitPoster.size.width == 1080)
        #expect(portraitPoster.size.height > darkWithDesc.size.height)
    }

    @Test("VideoSharePayload formats BV and AV fallback URLs and Rich ActivityItemSources build LinkMetadata")
    @MainActor
    func videoSharePayloadAndLinkMetadata() {
        let bvPayload = VideoSharePayload(
            bvid: "BV1abc123",
            aid: 42,
            title: "Demo Title",
            uploader: "UploaderName",
            avatarURL: "",
            coverURL: "",
            description: "Hello",
            durationSeconds: 90,
            viewCount: 100,
            likeCount: 10,
            isPortraitCover: false
        )
        #expect(bvPayload.shareURLString == "https://www.bilibili.com/video/BV1abc123")
        #expect(bvPayload.linkDisplay == "bilibili.com/video/BV1abc123")

        let avFallbackPayload = VideoSharePayload(
            bvid: "",
            aid: 987654,
            title: "AV Only",
            uploader: "",
            avatarURL: "",
            coverURL: "",
            description: "",
            durationSeconds: 0,
            viewCount: 0,
            likeCount: 0,
            isPortraitCover: true
        )
        #expect(avFallbackPayload.shareURLString == "https://www.bilibili.com/video/av987654")
        #expect(avFallbackPayload.linkDisplay == "bilibili.com/video/av987654")

        let url = URL(string: bvPayload.shareURLString)!
        let linkSource = SwiftPiliLinkActivityItemSource(
            url: url,
            title: bvPayload.title,
            uploader: bvPayload.uploader,
            accent: .systemPink
        )
        let dummyVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let metadata = linkSource.activityViewControllerLinkMetadata(dummyVC)
        #expect(metadata?.title == "Demo Title (@UploaderName) — SwiftPili")
        #expect(metadata?.originalURL == url)
        #expect(metadata?.iconProvider != nil)
    }

    // MARK: - Landscape Fullscreen Continuation & First-Video Rubber-Band Paging

    @Test("Same-owner VOD reload in landscape fullscreen preserves isFullscreen while new-owner or ownerExit exits fullscreen")
    @MainActor
    func sameOwnerReloadPreservesLandscapeFullscreen() {
        let vm = PlayerViewModel.shared
        let savedFullscreen = vm.isFullscreen
        let savedReceipt = vm.fullscreenPresentationReceipt
        let savedMask = AppOrientation.shared.mask
        let savedResetPending = vm.presentationResetPendingForOwnerChange
        defer {
            vm.isFullscreen = savedFullscreen
            vm.fullscreenPresentationReceipt = savedReceipt
            vm.presentationResetPendingForOwnerChange = savedResetPending
            AppOrientation.shared.set(savedMask)
        }

        let leaseA = vm.claimOwnerLease(owner: "vod-BV1fsKeepA")
        vm.presentationResetPendingForOwnerChange = false
        let contextA = PlayerScreenPresentationContext(
            screenID: UUID(),
            ownerLease: leaseA,
            route: .video(.bvid("BV1fsKeepA")),
            position: PlayerRoutePosition(tab: .home, sidebarID: nil, depth: 1),
            source: .vod(aid: 1001, cid: 2001, source: .ugc)
        )
        vm.fullscreenPresentationReceipt = PlayerPresentationReceipt(id: UUID(), context: contextA)
        vm.isFullscreen = true
        AppOrientation.shared.set(.landscape)

        // Same-owner part/episode/inline recommendation switch (.newContentOwnership, !newOwner) keeps fullscreen
        vm.stop(reason: .newContentOwnership)
        #expect(vm.isFullscreen == true)

        // New-owner takeover (.newContentOwnership with presentationResetPendingForOwnerChange == true) exits fullscreen
        _ = vm.claimOwnerLease(owner: "vod-BV1fsNewOwnerB")
        #expect(vm.presentationResetPendingForOwnerChange == true)
        vm.stop(reason: .newContentOwnership)
        #expect(vm.isFullscreen == false)

        // Explicit .ownerExit also exits fullscreen
        let leaseC = vm.claimOwnerLease(owner: "vod-BV1fsExitC")
        vm.presentationResetPendingForOwnerChange = false
        let contextC = PlayerScreenPresentationContext(
            screenID: UUID(),
            ownerLease: leaseC,
            route: .video(.bvid("BV1fsExitC")),
            position: PlayerRoutePosition(tab: .home, sidebarID: nil, depth: 1),
            source: .vod(aid: 1003, cid: 2003, source: .ugc)
        )
        vm.fullscreenPresentationReceipt = PlayerPresentationReceipt(id: UUID(), context: contextC)
        vm.isFullscreen = true
        vm.stop(reason: .ownerExit)
        #expect(vm.isFullscreen == false)
        _ = vm.endOwnerPlayback(lease: leaseC)
    }

    @Test("PortraitPagingReducer first-item pull-down applies boundary damping and rebounds without exiting Story")
    func portraitPagingFirstItemPullDownRebounds() {
        var reducer = PortraitPagingReducer(itemCount: 5, initialIndex: 0)
        reducer.updateContainerHeight(840)
        #expect(reducer.beginDrag() == true)

        let dampedOffset = reducer.drag(translation: 120)
        #expect(dampedOffset > 0)
        #expect(dampedOffset < 120)

        let settlement = reducer.endDrag(translation: 120, predictedEndTranslation: 320)
        #expect(settlement?.kind == .rebound)
        #expect(reducer.offset == 0)
        #expect(reducer.completeSettlement(token: settlement!.token) == nil)
        #expect(reducer.currentIndex == 0)
    }
}
