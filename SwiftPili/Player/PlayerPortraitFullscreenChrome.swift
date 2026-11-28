import SwiftUI
import UIKit

struct PortraitDoubleTapPulse: Equatable {
    let id = UUID()
    let location: CGPoint?
}

enum PlayerPortraitChromePolicy {
    static let interactionFadeOpacity: Double = 0.14
    static let interactionGradientOpacity: Double = 0.35
    static let burstMarginX: CGFloat = 52
    static let burstMarginY: CGFloat = 88
    static let rightRailExtraBottomLift: CGFloat = 18
    static let rightRailItemSpacing: CGFloat = 13
    static let bottomDockHeight: CGFloat = 44
    static let bottomDockHorizontalPadding: CGFloat = 20
    static let bottomDockFallbackFloor: CGFloat = 14
    static let seekBarHorizontalInset: CGFloat = 16
    static let bottomGradientBaseHeight: CGFloat = 240
    static let seekBarHeight: CGFloat = 24
    static let bottomSplitBottomPadding: CGFloat = 8
    static let bottomDockTopPadding: CGFloat = 4
    static let noDanmakuBottomFloor: CGFloat = 12

    static func bottomDockBottomPadding(bottomSafeArea: CGFloat) -> CGFloat {
        let safe = max(0, bottomSafeArea)
        return safe >= 20 ? safe : max(bottomDockFallbackFloor, safe)
    }

    static func metadataBottomClearance(
        bottomSafeArea: CGFloat,
        showsDanmakuDock: Bool
    ) -> CGFloat {
        let safe = max(0, bottomSafeArea)
        let dockAreaHeight: CGFloat = if showsDanmakuDock {
            bottomDockTopPadding
                + bottomDockHeight
                + bottomDockBottomPadding(bottomSafeArea: safe)
        } else {
            max(noDanmakuBottomFloor, safe)
        }
        return dockAreaHeight + seekBarHeight + bottomSplitBottomPadding
    }

    @MainActor
    static func matchedContext(
        _ candidate: PlayerPortraitFullscreenContext?,
        screenLease: PlayerOwnerLease?
    ) -> PlayerPortraitFullscreenContext? {
        guard let screenLease,
              candidate?.ownerLease == screenLease else {
            return nil
        }
        return candidate
    }

    static func isPureViewActive(
        pureViewEnabled: Bool,
        isPlaybackUnavailable: Bool,
        isPlaybackEnded: Bool
    ) -> Bool {
        pureViewEnabled && !isPlaybackUnavailable && !isPlaybackEnded
    }

    static func chromeOpacity(isInteracting: Bool) -> Double {
        isInteracting ? interactionFadeOpacity : 1.0
    }

    static func clampedBurstPosition(_ location: CGPoint?, in size: CGSize) -> CGPoint {
        guard let location,
              location.x.isFinite, location.y.isFinite,
              size.width > 1, size.height > 1 else {
            return CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        }
        let x = min(max(location.x, burstMarginX), max(burstMarginX, size.width - burstMarginX))
        let y = min(max(location.y, burstMarginY), max(burstMarginY, size.height - burstMarginY))
        return CGPoint(x: x, y: y)
    }
}

struct PlayerPortraitFullscreenChrome: View {
    let player: PlayerViewModel
    let owner: String
    let isCurrentOwner: Bool
    let screenLease: PlayerOwnerLease?
    let presentationReceipt: PlayerPresentationReceipt?
    let fullscreenHostIdentity: UUID?
    let gestureDisplay: PlayerGestureDisplay
    let chromeInsets: PlayerChromeInsets
    let isScrubbingOrFastForwarding: Bool
    let isPlaybackUnavailable: Bool
    let isPlaybackEnded: Bool
    let doubleTapLikePulse: PortraitDoubleTapPulse?
    @Binding var danmakuPanelPresented: Bool
    @Binding var subtitlePanelPresented: Bool
    @Binding var showSponsorBlock: Bool
    @Binding var isDraggingHairlineBar: Bool

    private let experiments = ExperimentalSettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appSceneID) private var appSceneID
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var danmakuEnabled = false

    @State private var isTitleExpanded = false
    @State private var followRequestInFlight = false
    @State private var coinRequestInFlight = false
    @State private var favoriteRequestInFlight = false
    @State private var tripleRequestInFlight = false
    @State private var tripleHoldProgress: CGFloat = 0

    @State private var showPlaylistSheet = false
    @State private var showDetailsSheet = false
    @State private var showCoinDialog = false
    @State private var showFavoriteSheet = false
    @State private var favoriteSheetFolders: [FavFolderListResult.FavFolder] = []
    @State private var favoriteSheetInitialSelection: Set<Int> = []
    @State private var showCommentsSheet = false
    @State private var showShareSheet = false
    @State private var showChapterSheet = false
    @State private var enhancementPresentation: EnhancementPresentation?
    @State private var inlineDanmakuDraft = ""
    @State private var inlineDanmakuNotice: DanmakuNotice?
    @State private var inlineKeyboardFrame: CGRect?
    @State private var inlineDanmakuSend = DanmakuComposerSendGate()

    private struct EnhancementScope: Equatable {
        let screenLease: PlayerOwnerLease
        let receipt: PlayerPresentationReceipt?
        let hostIdentity: UUID?
        let surfaceLease: PlayerSurfaceLease?
        let source: DecoderRecoveryAdmission.Source?
        let loadGeneration: Int
        let backend: ObjectIdentifier
        let backendGeneration: UInt64
        let access: ExperimentalAccessReceipt
    }

    private struct EnhancementPresentation: Identifiable {
        let id = UUID()
        let scope: EnhancementScope
    }

    private var context: PlayerPortraitFullscreenContext? {
        PlayerPortraitChromePolicy.matchedContext(
            player.portraitFullscreenContext,
            screenLease: screenLease
        )
    }

    private var hasDanmakuSupport: Bool {
        player.supportsDanmakuControls
            || (player.mode == .offline && player.hasRegisteredOfflineDanmaku)
    }

    private var isPureView: Bool {
        PlayerPortraitChromePolicy.isPureViewActive(
            pureViewEnabled: player.portraitPureViewEnabled,
            isPlaybackUnavailable: isPlaybackUnavailable,
            isPlaybackEnded: isPlaybackEnded
        )
    }

    private var shouldFadeChromeForInteraction: Bool {
        isScrubbingOrFastForwarding || isDraggingHairlineBar || gestureDisplay.isSeeking
    }

    private var chromeInteractionOpacity: Double {
        PlayerPortraitChromePolicy.chromeOpacity(isInteracting: shouldFadeChromeForInteraction)
    }

    private var interactionFadeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    private var showsCenterPauseIndicator: Bool {
        isCurrentOwner
            && !player.isPlaying
            && !player.isBuffering
            && !isPlaybackEnded
            && !isPlaybackUnavailable
            && !shouldFadeChromeForInteraction
    }

    private var resolvedUpName: String? {
        context?.upName.portraitNonEmpty ?? player.nowPlayingMeta?.artist.portraitNonEmpty
    }

    private var resolvedTitle: String? {
        context?.title.portraitNonEmpty ?? player.nowPlayingMeta?.title.portraitNonEmpty
    }

    private var preferredSheetColorScheme: ColorScheme? {
        (AppearanceMode(rawValue: appearanceRaw) ?? .system).colorScheme
    }

    private var mountsInlineDanmakuComposer: Bool {
        isCurrentOwner
            && context?.isInRouteImmersiveStage == true
            && !player.isFullscreen
            && player.mode.usesOnlineVODServices
            && player.fullscreenDanmakuComposerPresented
    }

    private var canOpenDetails: Bool {
        (context?.hasExpandableDetails == true && context?.makeDetailsSheetView != nil)
            || context?.onOpenDetailsSheet != nil
    }

    private var showsSeekBar: Bool {
        !isPlaybackUnavailable
            && !isPlaybackEnded
            && !isPureView
            && isCurrentOwner
            && player.mode.isSeekable
            && player.currentURL != nil
            && player.duration > 0
    }

    var body: some View {
        ZStack {
            if !isPureView && !isPlaybackUnavailable && !isPlaybackEnded {
                legibilityGradients
                    .opacity(shouldFadeChromeForInteraction ? PlayerPortraitChromePolicy.interactionGradientOpacity : 1.0)
                    .animation(interactionFadeAnimation, value: shouldFadeChromeForInteraction)
            }

            if showsCenterPauseIndicator {
                centerPauseIndicator
                    .transition(.scale(scale: 0.84).combined(with: .opacity))
            }

            if let pulse = doubleTapLikePulse {
                PortraitDoubleTapLikeBurstView(pulse: pulse)
                    .id(pulse.id)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                if isPureView {
                    pureViewExitBar
                } else {
                    topFeatherBar
                        .opacity(chromeInteractionOpacity)
                        .allowsHitTesting(!shouldFadeChromeForInteraction)
                        .animation(interactionFadeAnimation, value: shouldFadeChromeForInteraction)
                }

                Spacer(minLength: 0)

                if !isPureView && !isPlaybackUnavailable && !isPlaybackEnded {
                    bottomSplitArea
                        .opacity(chromeInteractionOpacity)
                        .allowsHitTesting(!shouldFadeChromeForInteraction)
                        .animation(interactionFadeAnimation, value: shouldFadeChromeForInteraction)

                    if showsSeekBar {
                        PortraitHairlineSeekBar(
                            player: player,
                            owner: owner,
                            isCurrentOwner: isCurrentOwner,
                            gestureDisplay: gestureDisplay,
                            isDraggingBar: $isDraggingHairlineBar
                        )
                        .padding(.horizontal, PlayerPortraitChromePolicy.seekBarHorizontalInset)
                        .transition(.opacity)
                    } else if player.mode.isSeekable {
                        Color.clear
                            .frame(height: PlayerPortraitChromePolicy.seekBarHeight)
                            .padding(.horizontal, PlayerPortraitChromePolicy.seekBarHorizontalInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    bottomDanmakuDock
                        .opacity(mountsInlineDanmakuComposer ? 0 : chromeInteractionOpacity)
                        .allowsHitTesting(!mountsInlineDanmakuComposer && !shouldFadeChromeForInteraction)
                        .animation(interactionFadeAnimation, value: shouldFadeChromeForInteraction)
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: showsCenterPauseIndicator)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isPureView)
        .ignoresSafeArea(.keyboard, edges: .all)
        .overlay(alignment: .bottom) {
            if mountsInlineDanmakuComposer {
                ZStack(alignment: .bottom) {
                    Color.white.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            AppWindowMetrics.current?.endEditing(true)
                            dismissInlineImmersiveDanmakuComposer(clearDraft: false)
                        }
                        .gesture(
                            DragGesture(minimumDistance: 6)
                                .onEnded { _ in
                                    AppWindowMetrics.current?.endEditing(true)
                                    dismissInlineImmersiveDanmakuComposer(clearDraft: false)
                                }
                        )

                    FullscreenDanmakuComposer(
                        draft: $inlineDanmakuDraft,
                        notice: nil,
                        isSending: inlineDanmakuSend.isSending,
                        keyboardFrame: inlineKeyboardFrame,
                        onSubmit: submitInlineImmersiveDanmaku,
                        onClose: {
                            AppWindowMetrics.current?.endEditing(true)
                            dismissInlineImmersiveDanmakuComposer(clearDraft: true)
                        },
                        onFocusLost: inlineImmersiveDanmakuFocusLost
                    )
                }
            }
        }
        .danmakuNoticeToast($inlineDanmakuNotice)
        .confirmationDialog("Coin this video", isPresented: $showCoinDialog, titleVisibility: .visible) {
            Button("Give 1 Coin") { giveCoin(1) }
            Button("Give 2 Coins") { giveCoin(2) }
        }
        .sheet(isPresented: $showPlaylistSheet) {
            PlayerPlaylistDrawerSheet(player: player)
                .preferredColorScheme(preferredSheetColorScheme)
        }
        .sheet(isPresented: $showDetailsSheet) {
            if let makeDetails = context?.makeDetailsSheetView {
                makeDetails()
                    .preferredColorScheme(preferredSheetColorScheme)
            }
        }
        .sheet(isPresented: $showFavoriteSheet) {
            FavoriteFolderSheet(
                folders: favoriteSheetFolders,
                selection: favoriteSheetInitialSelection
            ) { selected in
                guard let commit = context?.onCommitFavoriteFolders else { return }
                Task {
                    favoriteRequestInFlight = true
                    await commit(selected)
                    favoriteRequestInFlight = false
                }
            }
            .preferredColorScheme(preferredSheetColorScheme)
        }
        .sheet(isPresented: $showCommentsSheet) {
            if let makeComments = context?.makeCommentsSheetView {
                makeComments()
                    .preferredColorScheme(preferredSheetColorScheme)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let makeShare = context?.makeShareSheetView {
                makeShare()
                    .preferredColorScheme(preferredSheetColorScheme)
            }
        }
        .sheet(isPresented: $showChapterSheet) {
            PlayerChapterSheet(
                chapters: player.videoChapters,
                currentTime: player.displayTime
            ) { chapter in
                player.seek(to: chapter.from)
                if !player.isPlaying {
                    player.play()
                }
            }
            .preferredColorScheme(preferredSheetColorScheme)
        }
        .sheet(item: $enhancementPresentation) { request in
            PlayerVideoEnhancementSheet(
                player: player,
                canEdit: { canEditEnhancement(request) },
                onClose: { closeEnhancement(request) }
            )
            .preferredColorScheme(preferredSheetColorScheme)
        }
        .modifier(LiveKeyboardFrameTracker(frame: $inlineKeyboardFrame))
        .onChange(of: resolvedTitle) { _, _ in
            isTitleExpanded = false
        }
        .onChange(of: player.loadGeneration) { _, _ in
            guard context?.isInRouteImmersiveStage == true else { return }
            dismissInlineImmersiveDanmakuComposer(clearDraft: true)
        }
        .onChange(of: context?.isInRouteImmersiveStage ?? false) { _, active in
            if !active {
                dismissInlineImmersiveDanmakuComposer(clearDraft: true)
                inlineKeyboardFrame = nil
            }
        }
        .onChange(of: player.videoChapters.isEmpty) { _, isEmpty in
            if isEmpty { showChapterSheet = false }
        }
        .onChange(of: enhancementPresentation.map(canEditEnhancement), initial: true) { _, _ in
            if let request = enhancementPresentation, !canEditEnhancement(request) {
                closeEnhancement(request)
            }
        }
        .onChange(of: danmakuEnabled) { _, enabled in
            if !enabled {
                danmakuPanelPresented = false
                player.setDanmakuSettingsHold(false)
                if context?.isInRouteImmersiveStage == true {
                    dismissInlineImmersiveDanmakuComposer(clearDraft: true)
                }
            }
        }
        .onDisappear {
            isDraggingHairlineBar = false
            tripleHoldProgress = 0
            if context?.isInRouteImmersiveStage == true {
                dismissInlineImmersiveDanmakuComposer(clearDraft: true)
            }
            inlineDanmakuNotice = nil
            inlineKeyboardFrame = nil
        }
    }

    // MARK: - Zone 1: Subtle Top & Bottom Legibility Gradients

    private var legibilityGradients: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.38), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(100, chromeInsets.top + 56))

            Spacer(minLength: 0)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.32), location: 0.55),
                    .init(color: .black.opacity(0.58), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: PlayerPortraitChromePolicy.bottomGradientBaseHeight + max(0, chromeInsets.bottom - 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Zone 2: Top Feather Bar & Pure View Pill

    private var pureViewExitBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                player.portraitPureViewEnabled = false
            } label: {
                pureViewExitLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player.portrait.exitPureView")
            .accessibilityLabel(Text("Exit Pure View"))
        }
        .padding(.top, chromeInsets.top + 6)
        .padding(.horizontal, 16)
    }

    private var pureViewExitLabel: some View {
        Image(systemName: "eye.slash")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background { pureViewExitSurface }
            .environment(\.colorScheme, .dark)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var pureViewExitSurface: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color.black.opacity(0.38))
        }
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var topFeatherBar: some View {
        HStack(spacing: 10) {
            Button {
                if let back = context?.onBackToFeed {
                    back()
                } else {
                    player.requestFullscreenTransition(target: false, source: .button)
                }
            } label: {
                topFeatherGlyph("chevron.left", size: 16)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player.portrait.back")
            .accessibilityLabel(Text("Back"))

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    collapseToStandardView()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.topthird.inset.filled")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Standard View")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background { danmakuDockSurface(Capsule()) }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.portrait.collapse")
                .accessibilityLabel(Text("Switch to Standard View"))

                if let playlist = player.activePlaylistQueue {
                    Button {
                        showPlaylistSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 13, weight: .semibold))
                            Text(verbatim: "\(playlist.displayIndex)/\(playlist.totalCount)")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background { danmakuDockSurface(Capsule()) }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.portrait.playlist")
                    .accessibilityLabel(Text("Playlist"))
                    .accessibilityValue(Text(verbatim: "\(playlist.displayIndex)/\(playlist.totalCount)"))
                }

                topMoreMenu
            }
        }
        .padding(.top, chromeInsets.top + 6)
        .padding(.horizontal, 16)
    }

    private func collapseToStandardView() {
        if let collapse = context?.onCollapseToDetail {
            collapse()
        } else {
            player.requestFullscreenTransition(target: false, source: .button)
        }
    }

    private func topFeatherGlyph(_ systemName: String, size: CGFloat, tint: Color = .white) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background { danmakuDockSurface(Circle()) }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var topMoreMenu: some View {
        let renderedEnhancementScope = currentEnhancementScope
        return Menu {
            Button {
                collapseToStandardView()
            } label: {
                Label("Switch to Standard View", systemImage: "rectangle.topthird.inset.filled")
            }

            if canOpenDetails {
                Button {
                    openDetailsSheet()
                } label: {
                    Label("Details & Episodes", systemImage: "info.bubble")
                }
            }

            Divider()

            if player.mode.usesOnlineVODServices, !player.availableQualities.isEmpty {
                Menu {
                    ForEach(player.availableQualities, id: \.id) { quality in
                        Button {
                            Task { await player.switchQuality(quality.id) }
                        } label: {
                            HStack {
                                Text(quality.desc)
                                if quality.id == player.currentQuality {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Resolution", systemImage: "rectangle.on.rectangle")
                }
            }

            if player.mode.supportsPlaybackRate {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            player.setRate(Float(rate), flushPipeline: true)
                        } label: {
                            HStack {
                                Text("\(rate, specifier: "%.2g")x")
                                if Float(rate) == player.playbackRate {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Speed", systemImage: "speedometer")
                }
            }

            Button {
                subtitlePanelPresented = true
            } label: {
                Label(
                    "Subtitles",
                    systemImage: player.hasAnyActiveSubtitle ? "captions.bubble.fill" : "captions.bubble"
                )
            }

            PlayerSleepTimerSubmenu(player: player)

            if !player.videoChapters.isEmpty {
                Button {
                    showChapterSheet = true
                } label: {
                    Label("Chapters", systemImage: "list.bullet.indent")
                }
            }

            if hasDanmakuSupport, danmakuEnabled {
                Button {
                    danmakuPanelPresented.toggle()
                    player.setDanmakuSettingsHold(danmakuPanelPresented)
                } label: {
                    Label("Danmaku Settings", systemImage: "slider.horizontal.3")
                }
            }

            if player.mode.usesOnlineVODServices, SponsorBlockManager.shared.isEnabled {
                Button {
                    showSponsorBlock = true
                } label: {
                    Label("SponsorBlock", systemImage: "shield.lefthalf.filled")
                }
            }

            if experiments.isAllowed(.videoEnhancement),
               player.isVideoEnhancementEligibleForStream,
               let scope = renderedEnhancementScope {
                Button {
                    openEnhancement(for: scope)
                } label: {
                    Label("Video Enhancement", systemImage: "sparkles.tv")
                }
            }

            Menu {
                ForEach(VideoScaleMode.allCases) { mode in
                    Button {
                        player.scaleMode = mode
                    } label: {
                        HStack {
                            Text(mode.label)
                            if mode == player.scaleMode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Aspect Mode", systemImage: "aspectratio")
            }

            Toggle(isOn: Binding(get: { player.showStats }, set: { player.showStats = $0 })) {
                Label("Playback Info", systemImage: "info.circle")
            }

            Divider()

            Toggle(isOn: Binding(
                get: { player.portraitPureViewEnabled },
                set: { player.portraitPureViewEnabled = $0 }
            )) {
                Label("Pure View", systemImage: "eye")
            }
        } label: {
            topFeatherGlyph("ellipsis.circle", size: 17)
        }
        .accessibilityIdentifier("player.portrait.more")
        .accessibilityLabel(Text("More"))
    }

    // MARK: - Zone 3: Bottom-Left Metadata + Lower-Right Action Rail

    private var bottomSplitArea: some View {
        HStack(alignment: .bottom, spacing: 12) {
            bottomMetadataStack
                .frame(maxWidth: .infinity, alignment: .leading)

            if let context, player.mode == .vod {
                rightActionRail(context: context)
                    .frame(width: 48)
                    .padding(.bottom, PlayerPortraitChromePolicy.rightRailExtraBottomLift)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, PlayerPortraitChromePolicy.bottomSplitBottomPadding)
    }

    private var bottomMetadataStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let upName = resolvedUpName {
                ownerIdentityRow(upName: upName)
            }

            if let title = resolvedTitle {
                titleRow(title: title)
            }

            portraitSummarySubRow
        }
    }

    private func ownerIdentityRow(upName: String) -> some View {
        let displayHandle = upName.hasPrefix("@") ? upName : "@\(upName)"
        let avatarURL = context?.upAvatarURL.portraitNonEmpty ?? ""
        return HStack(spacing: 8) {
            Button {
                context?.onTapOwner?()
            } label: {
                HStack(spacing: 7) {
                    PortraitChromeAvatarView(urlString: avatarURL, size: 28)
                    Text(verbatim: displayHandle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(context?.onTapOwner == nil)
            .accessibilityIdentifier("player.portrait.owner")

            followSlotView
        }
        .frame(height: 28, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: context?.isFollowing)
    }

    @ViewBuilder
    private var followSlotView: some View {
        let shouldReserveWidth = context?.isFollowing == nil
            && context?.onToggleFollow != nil
            && AuthManager.shared.isLoggedIn
            && ((context?.upMid ?? 0) == 0 || String(context?.upMid ?? 0) != AuthManager.shared.dedeUserID)

        if context?.isFollowing == false, let toggleFollow = context?.onToggleFollow {
            Button {
                guard !followRequestInFlight else { return }
                Task {
                    followRequestInFlight = true
                    await toggleFollow()
                    followRequestInFlight = false
                }
            } label: {
                followPillLabel
            }
            .buttonStyle(.plain)
            .disabled(followRequestInFlight)
            .transition(.opacity)
            .accessibilityIdentifier("player.portrait.follow")
        } else if shouldReserveWidth {
            followPillLabel
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var followPillLabel: some View {
        Text("+ Follow")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.biliAccent, in: Capsule())
    }

    @ViewBuilder
    private func titleRow(title: String) -> some View {
        if canOpenDetails {
            Button {
                openDetailsSheet()
            } label: {
                titleLabel(title, lineLimit: 2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player.portrait.title")
        } else {
            titleLabel(title, lineLimit: isTitleExpanded ? 4 : 2)
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                        isTitleExpanded.toggle()
                    }
                }
                .accessibilityIdentifier("player.portrait.title")
        }
    }

    private func titleLabel(_ title: String, lineLimit: Int) -> some View {
        Text(verbatim: title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.95))
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .contentShape(Rectangle())
    }

    private var portraitSummarySubRow: some View {
        let badge = context?.summaryBadgeText?.portraitNonEmpty
        let descPreview = context?.descriptionPreview?.portraitNonEmpty
        let statsSummary = context?.statsSummary?.portraitNonEmpty
        let hasCapsule = badge != nil || descPreview != nil || canOpenDetails
        let accessibilityID = (badge != nil && descPreview == nil)
            ? "player.portrait.episodesBadge"
            : "player.portrait.descriptionEntry"

        return ZStack(alignment: .leading) {
            if hasCapsule {
                portraitSummaryCapsuleHost(
                    badge: badge,
                    descPreview: descPreview,
                    statsSummary: statsSummary,
                    accessibilityID: accessibilityID
                )
                .transition(.opacity)
            } else if let statsSummary {
                Text(verbatim: statsSummary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .transition(.opacity)
            } else {
                Color.clear
                    .frame(height: 24)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 24, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: canOpenDetails)
    }

    @ViewBuilder
    private func portraitSummaryCapsuleHost(
        badge: String?,
        descPreview: String?,
        statsSummary: String?,
        accessibilityID: String
    ) -> some View {
        let row = portraitSummaryCapsuleContent(
            badge: badge,
            descPreview: descPreview,
            statsSummary: statsSummary
        )
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background { summaryCapsuleSurface }
        .contentShape(Capsule())

        if canOpenDetails {
            Button(action: openDetailsSheet) {
                row
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityID)
        } else {
            row
                .accessibilityIdentifier(accessibilityID)
        }
    }

    private var summaryCapsuleSurface: some View {
        Capsule()
            .fill(Color.black.opacity(0.32))
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
    }

    private func portraitSummaryCapsuleContent(
        badge: String?,
        descPreview: String?,
        statsSummary: String?
    ) -> some View {
        let middleText = descPreview ?? statsSummary
        return HStack(spacing: 6) {
            if let badge {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(verbatim: badge)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                    if middleText == nil && !canOpenDetails {
                        Text("Episodes")
                            .font(.caption2.weight(.medium))
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize()
            }

            if let middleText {
                if badge != nil {
                    Rectangle()
                        .fill(.white.opacity(0.22))
                        .frame(width: 1, height: 11)
                }
                Text(verbatim: middleText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if canOpenDetails {
                HStack(spacing: 2) {
                    Text(badge != nil && descPreview == nil ? "Episodes" : "Details")
                        .font(.caption2.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
            }
        }
    }

    private func rightActionRail(context: PlayerPortraitFullscreenContext) -> some View {
        VStack(spacing: PlayerPortraitChromePolicy.rightRailItemSpacing) {
            PortraitRailLikeButton(
                isLiked: context.isLiked,
                count: context.likeCount,
                externalActionInFlight: tripleRequestInFlight,
                holdProgress: $tripleHoldProgress,
                onTap: {
                    await context.onToggleLike?()
                },
                onTripleCombo: {
                    guard !tripleRequestInFlight, let triple = context.onTripleCombo else { return }
                    tripleRequestInFlight = true
                    _ = await triple()
                    tripleRequestInFlight = false
                }
            )

            railActionButton(
                systemName: (context.isCoined || tripleHoldProgress > 0.35) ? "b.circle.fill" : "b.circle",
                isActive: context.isCoined || tripleHoldProgress > 0.35,
                caption: context.coinCount > 0 ? FormatUtils.viewCount(context.coinCount) : String(localized: "Coin"),
                accessibilityTitle: "Coin",
                accessibilityValue: Text(context.coinCount, format: .number),
                accessibilityID: "player.portrait.coin",
                disabled: coinRequestInFlight || tripleRequestInFlight || context.onGiveCoin == nil
            ) {
                if context.canGiveTwoCoins {
                    showCoinDialog = true
                } else {
                    giveCoin(1)
                }
            }

            railActionButton(
                systemName: (context.isFavorited || tripleHoldProgress > 0.65) ? "star.fill" : "star",
                isActive: context.isFavorited || tripleHoldProgress > 0.65,
                caption: context.favoriteCount > 0
                    ? FormatUtils.viewCount(context.favoriteCount)
                    : String(localized: "Favorite"),
                accessibilityTitle: "Favorite",
                accessibilityValue: Text(context.favoriteCount, format: .number),
                accessibilityID: "player.portrait.favorite",
                disabled: favoriteRequestInFlight || tripleRequestInFlight || context.onRequestFavoriteSheet == nil
            ) {
                openFavoriteSheet(context: context)
            }

            railActionButton(
                systemName: "text.bubble",
                isActive: false,
                caption: context.replyCount > 0
                    ? FormatUtils.viewCount(context.replyCount)
                    : String(localized: "Comments"),
                accessibilityTitle: "Comments",
                accessibilityValue: Text(context.replyCount, format: .number),
                accessibilityID: "player.portrait.comments",
                disabled: context.commentsClosed || context.makeCommentsSheetView == nil
            ) {
                showCommentsSheet = true
            }
            .opacity(context.commentsClosed ? 0.45 : 1.0)

            railShareMenu(context: context)
        }
    }

    private func railActionButton(
        systemName: String,
        isActive: Bool,
        caption: String,
        accessibilityTitle: LocalizedStringKey,
        accessibilityValue: Text,
        accessibilityID: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isActive ? Color.biliAccent : .white)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                Text(verbatim: caption)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func railShareMenu(context: PlayerPortraitFullscreenContext) -> some View {
        let caption = context.shareCount > 0
            ? FormatUtils.viewCount(context.shareCount)
            : String(localized: "Share")

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if context.makeShareSheetView != nil {
                showShareSheet = true
            } else {
                let shareURLString = context.bvid.portraitNonEmpty.map { "https://www.bilibili.com/video/\($0)" }
                if let shareURLString, let url = URL(string: shareURLString) {
                    let accent = UIColor(Color.biliAccent).resolvedColor(with: UITraitCollection.current)
                    let source = SwiftPiliLinkActivityItemSource(
                        url: url,
                        title: resolvedTitle ?? "",
                        uploader: resolvedUpName ?? "",
                        accent: accent
                    )
                    ActivitySharePresenter.present(items: [source]) { completed in
                        guard completed else { return }
                        Task { await context.onRecordShare?() }
                    }
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                Text(verbatim: caption)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("player.portrait.share")
        .accessibilityLabel(Text("Share"))
        .accessibilityValue(Text(context.shareCount, format: .number))
    }

    // MARK: - Zone 4b: Floating Bottom Danmaku Dock

    @ViewBuilder
    private var bottomDanmakuDock: some View {
        let bottomPadding = PlayerPortraitChromePolicy.bottomDockBottomPadding(bottomSafeArea: chromeInsets.bottom)
        if player.mode.usesOnlineVODServices || hasDanmakuSupport {
            HStack(spacing: 10) {
                if player.mode.usesOnlineVODServices {
                    if AuthManager.shared.isLoggedIn {
                        let draftPreview = inlineDanmakuDraft.portraitNonEmpty
                        Button {
                            if !danmakuEnabled {
                                danmakuEnabled = true
                            }
                            player.fullscreenDanmakuComposerPresented = true
                        } label: {
                            if let draftPreview {
                                danmakuDockDraftCapsuleLabel(draft: draftPreview)
                            } else {
                                danmakuDockCapsuleLabel(
                                    text: danmakuEnabled ? "Send a friendly danmaku..." : "Danmaku Off"
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("player.portrait.sendDanmaku")
                        .accessibilityLabel(Text("Send danmaku"))
                    } else {
                        Button {
                            if player.isFullscreen {
                                player.requestLoginFromFullscreen(sceneID: appSceneID)
                            } else {
                                context?.onRequestLogin?()
                            }
                        } label: {
                            danmakuDockCapsuleLabel(text: "Log in to send danmaku")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("player.portrait.sendDanmaku")
                        .accessibilityLabel(Text("Log in to send danmaku"))
                    }
                } else {
                    Spacer(minLength: 0)
                }

                if hasDanmakuSupport {
                    Button {
                        danmakuEnabled.toggle()
                    } label: {
                        DanmakuSymbolIcon(
                            isOn: danmakuEnabled,
                            fontSize: 13.5,
                            activeColor: Color.biliAccent,
                            inactiveColor: .white.opacity(0.88)
                        )
                        .frame(width: 38, height: 38)
                        .background { danmakuDockSurface(Circle()) }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .danmakuToggleAccessibility(isOn: danmakuEnabled)
                    .accessibilityIdentifier("player.portrait.danmakuToggle")
                }
            }
            .padding(.horizontal, PlayerPortraitChromePolicy.bottomDockHorizontalPadding)
            .padding(.top, PlayerPortraitChromePolicy.bottomDockTopPadding)
            .padding(.bottom, bottomPadding)
        } else {
            Color.clear
                .frame(height: max(PlayerPortraitChromePolicy.noDanmakuBottomFloor, chromeInsets.bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func danmakuDockDraftCapsuleLabel(draft: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.biliAccent)
            Text(verbatim: draft)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background { danmakuDockSurface(Capsule()) }
        .frame(minHeight: PlayerPortraitChromePolicy.bottomDockHeight)
        .contentShape(Rectangle())
    }

    private func danmakuDockCapsuleLabel(text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: DanmakuSymbolIcon.inactiveSymbolName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background { danmakuDockSurface(Capsule()) }
        .frame(minHeight: PlayerPortraitChromePolicy.bottomDockHeight)
        .contentShape(Rectangle())
    }

    private func danmakuDockSurface<S: InsettableShape>(_ shape: S) -> some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.28))
        }
        .overlay {
            shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Zone 5: Center Pause Indicator

    private var centerPauseIndicator: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.38))
                .frame(width: 54, height: 54)
            Image(systemName: "play.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.92))
                .offset(x: 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Actions & Enhancement Scope

    private func openDetailsSheet() {
        if context?.makeDetailsSheetView != nil {
            context?.onOpenDetailsSheet?()
            showDetailsSheet = true
        } else if let onOpen = context?.onOpenDetailsSheet {
            onOpen()
        }
    }

    private func submitInlineImmersiveDanmaku() {
        guard isCurrentOwner,
              context?.isInRouteImmersiveStage == true,
              player.mode.usesOnlineVODServices,
              !inlineDanmakuSend.isSending else { return }
        let submittedLoadGeneration = player.loadGeneration
        let submittedOwnerLease = screenLease
        let submittedSession = AuthManager.shared.sessionGeneration
        guard let text = inlineDanmakuSend.begin(draft: inlineDanmakuDraft) else {
            dismissInlineImmersiveDanmakuComposer(clearDraft: true)
            return
        }
        Task {
            let message = await player.sendDanmaku(text: text)
            inlineDanmakuSend.settle()
            guard isCurrentOwner,
                  let submittedOwnerLease,
                  player.isCurrentOwner(submittedOwnerLease),
                  player.loadGeneration == submittedLoadGeneration,
                  AuthManager.shared.sessionGeneration == submittedSession else {
                inlineDanmakuDraft = ""
                return
            }
            if let message {
                inlineDanmakuDraft = text
                player.fullscreenDanmakuComposerPresented = false
                inlineDanmakuNotice = DanmakuNotice(text: message)
            } else {
                inlineDanmakuDraft = ""
                player.fullscreenDanmakuComposerPresented = false
                inlineDanmakuNotice = DanmakuNotice(text: String(localized: "Danmaku sent"))
            }
        }
    }

    private func inlineImmersiveDanmakuFocusLost() {
        guard isCurrentOwner,
              context?.isInRouteImmersiveStage == true,
              !inlineDanmakuSend.isSending,
              player.fullscreenDanmakuComposerPresented else { return }
        dismissInlineImmersiveDanmakuComposer(clearDraft: false)
    }

    private func dismissInlineImmersiveDanmakuComposer(clearDraft: Bool) {
        if clearDraft, !inlineDanmakuSend.isSending {
            inlineDanmakuDraft = ""
        }
        if isCurrentOwner, !player.isFullscreen, player.fullscreenDanmakuComposerPresented {
            player.fullscreenDanmakuComposerPresented = false
        }
    }

    private func giveCoin(_ count: Int) {
        guard !coinRequestInFlight, let onGiveCoin = context?.onGiveCoin else { return }
        Task {
            coinRequestInFlight = true
            await onGiveCoin(count)
            coinRequestInFlight = false
        }
    }

    private func openFavoriteSheet(context: PlayerPortraitFullscreenContext) {
        guard !favoriteRequestInFlight,
              let requestFolders = context.onRequestFavoriteSheet else { return }
        Task {
            favoriteRequestInFlight = true
            let fetched = await requestFolders()
            favoriteRequestInFlight = false
            let mapped = fetched.map { folder in
                FavFolderListResult.FavFolder(
                    id: folder.id,
                    title: folder.title,
                    mediaCount: folder.mediaCount,
                    favState: folder.attr
                )
            }
            favoriteSheetFolders = mapped
            favoriteSheetInitialSelection = Set(mapped.filter(\.containsVideo).map(\.id))
            showFavoriteSheet = true
        }
    }

    private var currentEnhancementScope: EnhancementScope? {
        guard let screenLease,
              player.isCurrentOwner(screenLease),
              player.isVideoEnhancementEligibleForStream,
              let access = experiments.captureAccess(.videoEnhancement),
              player.isFullscreen == (presentationReceipt != nil) else {
            return nil
        }
        if let presentationReceipt {
            guard let fullscreenHostIdentity,
                  presentationReceipt.context.ownerLease == screenLease,
                  player.isCurrentPresentationReceipt(presentationReceipt, hostIdentity: fullscreenHostIdentity) else {
                return nil
            }
        }
        let backend = player.backend
        return EnhancementScope(
            screenLease: screenLease,
            receipt: presentationReceipt,
            hostIdentity: fullscreenHostIdentity,
            surfaceLease: player.activeSurfaceLease,
            source: player.decoderRecoverySource(),
            loadGeneration: player.loadGeneration,
            backend: ObjectIdentifier(backend),
            backendGeneration: backend.runtimeGeneration,
            access: access
        )
    }

    private func openEnhancement(for scope: EnhancementScope) {
        guard enhancementPresentation == nil,
              currentEnhancementScope == scope,
              experiments.isCurrentAccess(scope.access) else { return }
        enhancementPresentation = EnhancementPresentation(scope: scope)
    }

    private func canEditEnhancement(_ request: EnhancementPresentation) -> Bool {
        enhancementPresentation?.id == request.id
            && currentEnhancementScope == request.scope
            && experiments.isCurrentAccess(request.scope.access)
    }

    private func closeEnhancement(_ request: EnhancementPresentation) {
        if enhancementPresentation?.id == request.id {
            enhancementPresentation = nil
        }
    }
}

// MARK: - Portrait Rail Like + Triple-Combo Hold Button

private struct PortraitRailLikeButton: View {
    let isLiked: Bool
    let count: Int
    let externalActionInFlight: Bool
    @Binding var holdProgress: CGFloat
    let onTap: () async -> Void
    let onTripleCombo: () async -> Void

    @AppMotion private var motion
    @State private var tapInFlight = false
    @State private var holdTask: Task<Void, Never>?
    @State private var activePressID: UUID?
    @State private var didFireLongPress = false
    @State private var pressCancelledByDrag = false
    @GestureState private var isPressing = false

    private static let holdDurationSeconds: Double = 0.85
    private static let ringDelayMs = 150
    private static let maxHoldDistance: CGFloat = 24

    var body: some View {
        let isCharging = holdProgress > 0.01
        let active = isLiked || isCharging
        let caption = count > 0 ? FormatUtils.viewCount(count) : String(localized: "Like")

        let base = VStack(spacing: 4) {
            likeIcon(isCharging: isCharging, active: active)
            Text(verbatim: caption)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .gesture(pressHoldGesture)
        .onChange(of: isPressing) { _, pressing in
            handlePressStateChange(pressing: pressing)
        }
        .onDisappear {
            cancelHoldAnimation(resetInstantly: true)
        }

        return applyAccessibility(to: base)
    }

    private func likeIcon(isCharging: Bool, active: Bool) -> some View {
        ZStack {
            if isCharging {
                Circle()
                    .stroke(Color.biliAccent.opacity(0.28), lineWidth: 2.2)
                    .frame(width: 28, height: 28)
                Circle()
                    .trim(from: 0, to: holdProgress)
                    .stroke(
                        Color.biliAccent,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 28, height: 28)
            }

            Image(systemName: active ? "hand.thumbsup.fill" : "hand.thumbsup")
                .font(.system(size: isCharging ? 17 : 22, weight: .semibold))
                .foregroundStyle(active ? Color.biliAccent : .white)
                .scaleEffect(isCharging ? (1.0 + 0.08 * holdProgress) : 1.0)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
        .frame(width: 30, height: 30)
    }

    private var pressHoldGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressing) { _, pressing, _ in
                pressing = true
            }
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                if distance > Self.maxHoldDistance, !pressCancelledByDrag {
                    pressCancelledByDrag = true
                    cancelHoldAnimation(resetInstantly: false)
                }
            }
            .onEnded { value in
                let distance = hypot(value.translation.width, value.translation.height)
                cancelHoldAnimation(resetInstantly: false)
                guard !didFireLongPress,
                      !pressCancelledByDrag,
                      distance <= Self.maxHoldDistance else {
                    return
                }
                triggerLikeTap()
            }
    }

    private func applyAccessibility<Content: View>(to content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("player.portrait.like")
            .accessibilityAddTraits(isLiked ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(Text("Like"))
            .accessibilityHint(Text("Hold for Triple Combo"))
            .accessibilityValue(Text(count, format: .number))
            .accessibilityAction {
                triggerLikeTap()
            }
            .accessibilityAction(named: Text("Triple Combo")) {
                Task { await onTripleCombo() }
            }
    }

    private func handlePressStateChange(pressing: Bool) {
        if pressing {
            let pressID = UUID()
            activePressID = pressID
            didFireLongPress = false
            pressCancelledByDrag = false
            startHoldAnimation(pressID: pressID)
        } else {
            activePressID = nil
            cancelHoldAnimation(resetInstantly: false)
        }
    }

    private func triggerLikeTap() {
        guard !tapInFlight, !externalActionInFlight else { return }
        Task {
            tapInFlight = true
            await onTap()
            tapInFlight = false
        }
    }

    private func startHoldAnimation(pressID: UUID) {
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.ringDelayMs))
            guard !Task.isCancelled, activePressID == pressID, !pressCancelledByDrag else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let remaining = max(0.2, Self.holdDurationSeconds - Double(Self.ringDelayMs) / 1000.0)
            let step1 = remaining * 0.35
            let step2 = remaining * 0.30
            let step3 = remaining * 0.35
            withAnimation(motion.animation(normal: .linear(duration: step1))) {
                holdProgress = 0.35
            }
            try? await Task.sleep(for: .milliseconds(Int((step1 * 1000).rounded())))
            guard !Task.isCancelled, activePressID == pressID, !pressCancelledByDrag else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(motion.animation(normal: .linear(duration: step2))) {
                holdProgress = 0.65
            }
            try? await Task.sleep(for: .milliseconds(Int((step2 * 1000).rounded())))
            guard !Task.isCancelled, activePressID == pressID, !pressCancelledByDrag else { return }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            withAnimation(motion.animation(normal: .linear(duration: step3))) {
                holdProgress = 1.0
            }
            try? await Task.sleep(for: .milliseconds(Int((step3 * 1000).rounded())))
            guard !Task.isCancelled, activePressID == pressID, !pressCancelledByDrag else { return }
            didFireLongPress = true
            activePressID = nil
            cancelHoldAnimation(resetInstantly: false)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await onTripleCombo()
        }
    }

    private func cancelHoldAnimation(resetInstantly: Bool) {
        holdTask?.cancel()
        holdTask = nil
        if resetInstantly {
            holdProgress = 0
        } else {
            withAnimation(motion.animation(normal: .easeOut(duration: 0.16))) {
                holdProgress = 0
            }
        }
    }
}

// MARK: - Double-Tap Like Burst

private struct PortraitDoubleTapLikeBurstView: View {
    let pulse: PortraitDoubleTapPulse

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 0.45
    @State private var opacity: Double = 0.0
    @State private var yRise: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let point = clampedPosition(in: proxy.size)
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Color.biliAccent)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                .scaleEffect(scale)
                .opacity(opacity)
                .offset(y: yRise)
                .position(point)
        }
        .task(id: pulse.id) {
            if reduceMotion {
                scale = 1.0
                opacity = 0.95
                try? await Task.sleep(for: .milliseconds(360))
                guard !Task.isCancelled else { return }
                opacity = 0
            } else {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.56)) {
                    scale = 1.12
                    opacity = 1.0
                }
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.34)) {
                    scale = 1.24
                    yRise = -24
                    opacity = 0.0
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func clampedPosition(in size: CGSize) -> CGPoint {
        PlayerPortraitChromePolicy.clampedBurstPosition(pulse.location, in: size)
    }
}

// MARK: - Zone 4: Edge-to-Edge Portrait Hairline Seek Bar

private struct PortraitHairlineSeekBar: View {
    let player: PlayerViewModel
    let owner: String
    let isCurrentOwner: Bool
    let gestureDisplay: PlayerGestureDisplay
    @Binding var isDraggingBar: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @AppMotion private var motion

    @State private var barWidth: CGFloat = 0
    @State private var isVisible = false
    @State private var scrubInteraction: ScrubInteraction?
    @State private var scrubBaseProgress: Double?
    @State private var scrubStartTranslationWidth: CGFloat?
    @State private var dragRejectedForVerticalPaging = false
    @State private var lastScrubFraction: Double?
    @GestureState private var isTouchingBar = false

    private var isOwner: Bool { isCurrentOwner && player.ownerKey == owner }

    private var isActiveScrub: Bool {
        isDraggingBar || gestureDisplay.isSeeking
    }

    private var scrubAnimation: Animation? {
        motion.animation(normal: .easeInOut(duration: 0.16))
    }

    var body: some View {
        let interval = samplingInterval(
            sceneIsActive: scenePhase == .active,
            isVisible: isVisible,
            width: barWidth,
            displayScale: displayScale
        )
        let chapterFractions = VideoChapter.tickFractions(
            for: player.videoChapters,
            duration: player.duration
        )

        TimelineView(.animation(minimumInterval: interval ?? 0.25, paused: interval == nil)) { _ in
            let shown = projection(samplingClock: interval != nil)
            trackStrip(progress: shown.progress, buffered: shown.buffered, chapterFractions: chapterFractions)
        }
        .overlay(alignment: .bottom) {
            if isActiveScrub {
                scrubPreviewOverlay
                    .padding(.bottom, 28)
                    .transition(.opacity)
            }
        }
        .animation(scrubAnimation, value: isActiveScrub)
        .onAppear { isVisible = true }
        .onChange(of: isTouchingBar) { _, touching in
            if !touching {
                finishScrub()
            }
        }
        .onChange(of: scrubSource) { _, current in
            guard case .active(let source) = scrubInteraction, source != current else { return }
            scrubInteraction = .retired
            scrubBaseProgress = nil
            scrubStartTranslationWidth = nil
            dragRejectedForVerticalPaging = false
            lastScrubFraction = nil
            isDraggingBar = false
            gestureDisplay.cancelSeek()
        }
        .onDisappear {
            isVisible = false
            if case .active = scrubInteraction {
                gestureDisplay.cancelSeek()
            }
            scrubInteraction = nil
            scrubBaseProgress = nil
            scrubStartTranslationWidth = nil
            dragRejectedForVerticalPaging = false
            lastScrubFraction = nil
            isDraggingBar = false
        }
    }

    private func trackStrip(
        progress: Double,
        buffered: Double,
        chapterFractions: [Double]
    ) -> some View {
        let clampedProgress = progress.isFinite ? min(max(progress, 0), 1) : 0
        let clampedBuffered = buffered.isFinite ? min(max(buffered, 0), 1) : 0
        let displayedBuffered = isActiveScrub ? clampedBuffered : max(clampedProgress, clampedBuffered)
        let trackHeight: CGFloat = isActiveScrub ? 7 : 2.5
        let knobSize: CGFloat = 14

        return GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let playedWidth = CGFloat(clampedProgress) * width
            let bufferedWidth = CGFloat(displayedBuffered) * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(isActiveScrub ? 0.28 : 0.22))
                Rectangle()
                    .fill(Color.white.opacity(isActiveScrub ? 0.45 : 0.38))
                    .frame(width: max(0, bufferedWidth - playedWidth))
                    .offset(x: playedWidth)
                Rectangle()
                    .fill(Color.biliAccent.opacity(isActiveScrub ? 1.0 : 0.90))
                    .frame(width: playedWidth)

                ForEach(chapterFractions.indices, id: \.self) { index in
                    let fraction = chapterFractions[index]
                    if fraction > 0.005, fraction < 0.995 {
                        chapterTick(fraction: fraction, width: width)
                    }
                }
            }
            .clipShape(Capsule())
            .frame(height: trackHeight)
            .overlay(alignment: .leading) {
                if isActiveScrub {
                    let clampedKnobX = min(max(playedWidth, knobSize * 0.5), max(knobSize * 0.5, width - knobSize * 0.5))
                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.45), radius: 2.5, y: 1)
                        .offset(x: clampedKnobX - knobSize * 0.5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(seekBarGesture(width: width, clampedProgress: clampedProgress, chapterFractions: chapterFractions))
            .onAppear { barWidth = width }
            .onChange(of: width) { _, newWidth in barWidth = newWidth }
        }
        .frame(height: PlayerPortraitChromePolicy.seekBarHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("player.portrait.seekBar")
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text("\(Int((clampedProgress * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            let next: Double
            switch direction {
            case .increment:
                next = min(1, clampedProgress + 0.05)
            case .decrement:
                next = max(0, clampedProgress - 0.05)
            @unknown default:
                return
            }
            updateScrub(next, chapterFractions: chapterFractions)
            finishScrub()
        }
    }

    private func chapterTick(fraction: Double, width: CGFloat) -> some View {
        let tickWidth: CGFloat = isActiveScrub ? 2.5 : 2
        let tickHeight: CGFloat = isActiveScrub ? 7 : 3.5
        let haloWidth = tickWidth + 1.5
        return Capsule()
            .fill(Color.black.opacity(0.68))
            .frame(width: haloWidth, height: tickHeight)
            .overlay {
                Capsule()
                    .fill(Color.white.opacity(isActiveScrub ? 0.96 : 0.88))
                    .frame(width: tickWidth, height: max(2, tickHeight - 1))
            }
            .offset(x: CGFloat(fraction) * width - haloWidth * 0.5)
    }

    private func seekBarGesture(
        width: CGFloat,
        clampedProgress: Double,
        chapterFractions: [Double]
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouchingBar) { _, touching, _ in touching = true }
            .onChanged { gesture in
                guard !dragRejectedForVerticalPaging else { return }
                if case .retired = scrubInteraction { return }
                let dx = abs(gesture.translation.width)
                let dy = abs(gesture.translation.height)
                if scrubInteraction == nil {
                    if dy >= 6, dy > dx {
                        dragRejectedForVerticalPaging = true
                        return
                    }
                    guard dx >= 6, dx >= dy else { return }
                    scrubBaseProgress = clampedProgress
                    scrubStartTranslationWidth = gesture.translation.width
                }
                let base = scrubBaseProgress ?? clampedProgress
                let startTranslation = scrubStartTranslationWidth ?? gesture.translation.width
                let delta = Double((gesture.translation.width - startTranslation) / width)
                let fraction = min(max(base + delta, 0), 1)
                updateScrub(fraction, chapterFractions: chapterFractions)
            }
            .onEnded { gesture in
                if case .active = scrubInteraction {
                    finishScrub()
                    return
                }
                let isShortTap = !dragRejectedForVerticalPaging
                    && abs(gesture.translation.width) < 6
                    && abs(gesture.translation.height) < 6
                scrubBaseProgress = nil
                scrubStartTranslationWidth = nil
                dragRejectedForVerticalPaging = false
                lastScrubFraction = nil
                guard isShortTap,
                      scrubSource != nil,
                      !gestureDisplay.isSeeking,
                      player.duration.isFinite,
                      player.duration > 0 else {
                    return
                }
                let fraction = min(max(Double(gesture.location.x / width), 0), 1)
                UISelectionFeedbackGenerator().selectionChanged()
                player.seek(to: fraction * player.duration)
            }
    }

    private var scrubPreviewOverlay: some View {
        let loader = PlayerStoryboardPreviewLoader.shared
        let seekTime = gestureDisplay.seekValue
        let chapter = player.chapter(at: seekTime)
        return VStack(spacing: 6) {
            if let image = loader.previewImage {
                PlayerStoryboardThumbnailView(
                    image: image,
                    aspectRatio: loader.previewAspectRatio,
                    isFullscreen: true
                )
            }

            VStack(spacing: 2) {
                Text(verbatim:
                    "\(FormatUtils.duration(Int(seekTime))) / \(FormatUtils.duration(Int(player.duration)))"
                )
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)

                if let chapter {
                    Text(verbatim: chapter.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .frame(maxWidth: 240)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Scrubbing State & Projection

    private struct ScrubSource: Equatable {
        let owner: PlayerOwnerLease
        let load: Int
        let backend: ObjectIdentifier
        let runtime: UInt64
    }

    private enum ScrubInteraction {
        case active(ScrubSource)
        case retired
    }

    private var scrubSource: ScrubSource? {
        guard isOwner,
              let lease = player.currentOwnerLease,
              lease.owner == owner,
              player.currentURL != nil,
              player.mode.isSeekable else {
            return nil
        }
        _ = player.playerGeneration
        let backend = player.backend
        return ScrubSource(
            owner: lease,
            load: player.loadGeneration,
            backend: ObjectIdentifier(backend),
            runtime: backend.runtimeGeneration
        )
    }

    private func updateScrub(_ fraction: Double, chapterFractions: [Double]) {
        guard let source = scrubSource else { return }
        switch scrubInteraction {
        case .none:
            guard !gestureDisplay.isSeeking else { return }
            scrubInteraction = .active(source)
            lastScrubFraction = fraction
            isDraggingBar = true
        case .active(let accepted):
            guard source == accepted, gestureDisplay.isSeeking else { return }
            if let previous = lastScrubFraction,
               Self.crossedChapterTick(from: previous, to: fraction, ticks: chapterFractions) {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            lastScrubFraction = fraction
        case .retired:
            return
        }
        gestureDisplay.scrub(fraction: fraction, duration: player.duration)
    }

    private static func crossedChapterTick(
        from previous: Double,
        to current: Double,
        ticks: [Double]
    ) -> Bool {
        guard previous != current, !ticks.isEmpty else { return false }
        return ticks.contains { tick in
            guard tick > 0.005, tick < 0.995 else { return false }
            return (previous < tick && current >= tick)
                || (previous > tick && current <= tick)
        }
    }

    private func finishScrub() {
        defer {
            scrubInteraction = nil
            scrubBaseProgress = nil
            scrubStartTranslationWidth = nil
            dragRejectedForVerticalPaging = false
            lastScrubFraction = nil
            isDraggingBar = false
        }
        guard case .active(let source) = scrubInteraction, gestureDisplay.isSeeking else { return }
        guard source == scrubSource else {
            gestureDisplay.cancelSeek()
            return
        }
        gestureDisplay.commitSeek { player.seek(to: $0) }
    }

    private struct Projection: Equatable {
        let progress: Double
        let buffered: Double
    }

    private func projection(samplingClock: Bool) -> Projection {
        guard isOwner, player.duration.isFinite, player.duration > 0 else {
            return Projection(progress: 0, buffered: 0)
        }
        let position = player.seekStripDisplayPosition(
            gestureDisplay: gestureDisplay,
            samplingClock: samplingClock
        )
        let end = player.seekStripBufferedEnd ?? 0
        return Projection(progress: position / player.duration, buffered: end / player.duration)
    }

    private func samplingInterval(
        sceneIsActive: Bool,
        isVisible: Bool,
        width: CGFloat,
        displayScale: CGFloat
    ) -> TimeInterval? {
        guard sceneIsActive, isVisible, isOwner,
              player.mode.isSeekable, player.currentURL != nil,
              player.duration.isFinite, player.duration > 0,
              width.isFinite, width > 0, displayScale.isFinite, displayScale > 0 else {
            return nil
        }
        if gestureDisplay.isSeeking { return BufferedTimeUIProjection.defaultCadence }
        guard player.canSampleSeekStripClock,
              player.playbackRate.isFinite, player.playbackRate > 0 else {
            return nil
        }
        let pixels = Double(width * displayScale)
        let interval = player.duration / pixels / Double(player.playbackRate)
        return min(max(interval, 1.0 / 60), BufferedTimeUIProjection.defaultCadence)
    }
}

private extension String {
    var portraitNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
