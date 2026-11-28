import SwiftUI
import UIKit

struct InAppMiniPlayerOverlay: View {
    let topBarClearance: CGFloat
    let bottomBarClearance: CGFloat
    let horizontalMargin: CGFloat
    let isCovered: Bool

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appSceneID) private var appSceneID
    @Environment(\.colorScheme) private var colorScheme
    @AppMotion private var motion

    private var miniPlayer: InAppMiniPlayerState { InAppMiniPlayerState.shared }

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var dismissSlideX: CGFloat = 0
    @State private var dismissOpacity: Double = 1
    @State private var dismissScale: CGFloat = 1
    @State private var isDismissing = false

    private var activeSession: InAppMiniPlayerSession? {
        guard !isCovered,
              let session = miniPlayer.activeSession,
              let player = PlayerViewModel.existingShared,
              player.routeOwnership.ownsScene(appSceneID),
              player.isCurrentOwner(session.ownerLease) else {
            return nil
        }
        return session
    }

    var body: some View {
        let session = activeSession
        GeometryReader { proxy in
            if let session, let player = PlayerViewModel.existingShared {
                let isPortrait = DetailPlayerGeometry.isPortraitAspect(
                    player.chrome.videoAspectRatio,
                    fallback: session.isPortrait || player.chrome.isPortraitContent
                )
                let cardSize = InAppMiniPlayerLayoutPolicy.cardSize(
                    isPortrait: isPortrait,
                    isPad: DeviceCapability.supportsPadDetailSplit,
                    containerSize: proxy.size,
                    videoAspectRatio: player.chrome.videoAspectRatio
                )
                let anchor = InAppMiniPlayerLayoutPolicy.anchorCenter(
                    for: miniPlayer.dockPosition,
                    cardSize: cardSize,
                    containerSize: proxy.size,
                    safeArea: proxy.safeAreaInsets,
                    topBarClearance: topBarClearance,
                    bottomBarClearance: bottomBarClearance,
                    horizontalMargin: horizontalMargin
                )
                let currentCenterX = anchor.x + dragOffset.width
                let edgeProgress = isDragging
                    ? InAppMiniPlayerLayoutPolicy.dismissProgress(
                        currentCenterX: currentCenterX,
                        cardWidth: cardSize.width,
                        containerWidth: proxy.size.width
                    )
                    : 0
                let activeOpacity = dismissOpacity * (1 - Double(edgeProgress) * 0.42)
                let activeScale = dismissScale * (isDragging ? 1.02 : 1.0) * (1 - edgeProgress * 0.06)

                MiniPlayerFloatingCard(
                    player: player,
                    session: session,
                    cardSize: cardSize,
                    colorScheme: colorScheme,
                    onTapRestore: {
                        guard !isDismissing, !isDragging else { return }
                        coordinator.restoreFromMiniPlayer(session)
                    },
                    onTapClose: {
                        dismissWithFade(player: player, ownerLease: session.ownerLease)
                    }
                )
                .frame(width: cardSize.width, height: cardSize.height)
                .scaleEffect(activeScale)
                .opacity(activeOpacity)
                .position(
                    x: anchor.x + dragOffset.width + dismissSlideX,
                    y: anchor.y + dragOffset.height
                )
                .gesture(
                    dragGesture(
                        player: player,
                        ownerLease: session.ownerLease,
                        anchor: anchor,
                        cardSize: cardSize,
                        containerSize: proxy.size,
                        safeArea: proxy.safeAreaInsets
                    )
                )
                .transition(
                    motion.transition(
                        normal: .scale(scale: 0.86).combined(with: .opacity)
                    )
                )
                .onAppear {
                    resetTransientGestureState()
                    ensureMiniPlayerSurfaceLease(player: player, session: session)
                }
                .onChange(of: session.ownerLease) { _, _ in
                    resetTransientGestureState()
                    ensureMiniPlayerSurfaceLease(player: player, session: session)
                }
                .onChange(of: player.activeSurfaceLease) { _, _ in
                    ensureMiniPlayerSurfaceLease(player: player, session: session)
                }
            }
        }
        .coordinateSpace(name: "inAppMiniPlayerStage")
        .ignoresSafeArea()
        .animation(
            motion.feedbackAnimation(normal: .snappy(duration: 0.28, extraBounce: 0.04)),
            value: session?.ownerLease
        )
        .animation(
            motion.feedbackAnimation(normal: .smooth(duration: 0.25, extraBounce: 0)),
            value: topBarClearance
        )
        .animation(
            motion.feedbackAnimation(normal: .smooth(duration: 0.25, extraBounce: 0)),
            value: bottomBarClearance
        )
        .animation(
            motion.feedbackAnimation(normal: .smooth(duration: 0.22, extraBounce: 0)),
            value: PlayerViewModel.existingShared?.chrome.videoAspectRatio
        )
    }

    private func resetTransientGestureState() {
        dragOffset = .zero
        isDragging = false
        dismissSlideX = 0
        dismissOpacity = 1
        dismissScale = 1
        isDismissing = false
    }

    private func ensureMiniPlayerSurfaceLease(
        player: PlayerViewModel,
        session: InAppMiniPlayerSession
    ) {
        guard !isDismissing,
              player.miniPlayer.activeSession?.ownerLease == session.ownerLease,
              player.isCurrentOwner(session.ownerLease) else {
            return
        }
        if player.surfaceLease(matching: session.ownerLease, role: .miniPlayer) != nil {
            return
        }
        if player.activeSurfaceLease == nil {
            _ = player.claimSurfaceSlot(ownerLease: session.ownerLease, role: .miniPlayer)
        } else if player.activeSurfaceLease?.ownerLease == session.ownerLease,
                  player.activeSurfaceLease?.role != .miniPlayer {
            _ = player.handoffSurfaceSlot(ownerLease: session.ownerLease, to: .miniPlayer)
        }
    }

    private func dragGesture(
        player: PlayerViewModel,
        ownerLease: PlayerOwnerLease,
        anchor: CGPoint,
        cardSize: CGSize,
        containerSize: CGSize,
        safeArea: EdgeInsets
    ) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("inAppMiniPlayerStage"))
            .onChanged { value in
                guard !isDismissing else { return }
                if !isDragging {
                    isDragging = true
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isDismissing else { return }
                let action = InAppMiniPlayerLayoutPolicy.resolveRelease(
                    anchorCenter: anchor,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    cardSize: cardSize,
                    containerSize: containerSize,
                    safeArea: safeArea,
                    topBarClearance: topBarClearance,
                    bottomBarClearance: bottomBarClearance,
                    horizontalMargin: horizontalMargin,
                    snapsHorizontallyToCorners: true
                )
                switch action {
                case .dismiss(let direction):
                    dismissBySwipe(
                        player: player,
                        ownerLease: ownerLease,
                        direction: direction,
                        cardWidth: cardSize.width
                    )
                case .snap(let targetDock):
                    let previousEdge = miniPlayer.dockPosition.edge
                    let dragDistance = hypot(value.translation.width, value.translation.height)
                    withAnimation(
                        motion.feedbackAnimation(normal: .smooth(duration: 0.28, extraBounce: 0.03))
                    ) {
                        miniPlayer.dockPosition = targetDock
                        dragOffset = .zero
                        isDragging = false
                    }
                    if targetDock.edge != previousEdge || dragDistance > 14 {
                        triggerSoftDockImpact()
                    }
                }
            }
    }

    private func dismissBySwipe(
        player: PlayerViewModel,
        ownerLease: PlayerOwnerLease,
        direction: InAppMiniPlayerLayoutPolicy.DismissDirection,
        cardWidth: CGFloat
    ) {
        guard !isDismissing else { return }
        isDismissing = true
        isDragging = false
        triggerLightImpact()
        let slideOut = direction.rawValue * (cardWidth + 72)
        motion.settle(
            normal: .snappy(duration: 0.24, extraBounce: 0)
        ) {
            dismissSlideX = slideOut
            dismissOpacity = 0
            dismissScale = 0.92
        } completion: {
            player.dismissMiniPlayer(matching: ownerLease)
            if miniPlayer.activeSession == nil {
                resetTransientGestureState()
            }
        }
    }

    private func dismissWithFade(
        player: PlayerViewModel,
        ownerLease: PlayerOwnerLease
    ) {
        guard !isDismissing else { return }
        isDismissing = true
        isDragging = false
        triggerLightImpact()
        motion.settle(
            normal: .snappy(duration: 0.2, extraBounce: 0)
        ) {
            dismissOpacity = 0
            dismissScale = 0.84
        } completion: {
            player.dismissMiniPlayer(matching: ownerLease)
            if miniPlayer.activeSession == nil {
                resetTransientGestureState()
            }
        }
    }

    private func triggerLightImpact() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    private func triggerSoftDockImpact() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred(intensity: 0.65)
    }
}

private struct MiniPlayerFloatingCard: View {
    let player: PlayerViewModel
    let session: InAppMiniPlayerSession
    let cardSize: CGSize
    let colorScheme: ColorScheme
    let onTapRestore: () -> Void
    let onTapClose: () -> Void

    private var surfaceLease: PlayerSurfaceLease? {
        player.surfaceLease(matching: session.ownerLease, role: .miniPlayer)
    }

    var body: some View {
        let radius = InAppMiniPlayerLayoutPolicy.cornerRadius
        let cardShape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack {
            Color.black

            if let coverURL = session.coverURL, !coverURL.isEmpty,
               (!player.session.hasRenderedFirstFrame || player.backend.isPiPActive) {
                miniPlayerCover(coverURL: coverURL)
                    .allowsHitTesting(false)
            }

            if player.session.currentURL != nil, let surfaceLease {
                PlayerRenderView(
                    generation: player.routeOwnership.playerGeneration,
                    viewController: player.backend.renderViewController,
                    surfaceLease: surfaceLease,
                    presentationCornerRadius: radius
                )
                .allowsHitTesting(false)
            }

            // Subtle top & bottom edge scrims so compact controls remain legible over bright frames.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.36), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 32)
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 36)
            }
            .allowsHitTesting(false)

            // Full-card tap target beneath interactive chrome buttons.
            Color.clear
                .contentShape(cardShape)
                .onTapGesture(perform: onTapRestore)

            MiniPlayerBufferingIndicator(player: player)
                .allowsHitTesting(false)

            // Corner controls overlay.
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    if session.mode == .live {
                        MiniPlayerLivePill()
                            .padding(.top, 6)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                    Spacer(minLength: 0)
                    MiniPlayerControlButton(
                        systemImage: "xmark",
                        iconSize: 10.5,
                        diameter: 26,
                        accessibilityLabel: "Close mini player",
                        action: onTapClose
                    )
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: 0) {
                    Spacer(minLength: 0)
                    MiniPlayerPlayPauseButton(
                        player: player,
                        bottomInset: session.mode.isSeekable ? 8 : 6
                    )
                }
            }

            if session.mode.isSeekable {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MiniPlayerProgressBar(player: player)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(cardShape)
        .overlay {
            cardShape
                .strokeBorder(
                    colorScheme == .dark
                        ? AppStroke.glassBorder(for: colorScheme)
                        : Color.white.opacity(0.24),
                    lineWidth: AppStroke.hairlineWidth
                )
                .allowsHitTesting(false)
        }
        .overlay {
            cardShape
                .strokeBorder(
                    AppStroke.cardBorder(for: colorScheme),
                    lineWidth: AppStroke.hairlineWidth
                )
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.24), radius: 6, x: 0, y: 3)
        .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            session.title.isEmpty
                ? Text("In-App Mini Player")
                : Text(session.title)
        )
        .accessibilityHint(Text("Double tap to return to player"))
    }

    @ViewBuilder
    private func miniPlayerCover(coverURL: String) -> some View {
        if cardSize.height > cardSize.width {
            PortraitPagerCoverLayers(
                coverURL: coverURL,
                pageSize: cardSize,
                resolutionBudget: cardSize
            )
        } else {
            CoverImage(
                urlString: coverURL,
                displaySize: cardSize,
                contentMode: .fill,
                groundColor: .black,
                isDecorative: true,
                fillsOfferedBox: true
            )
        }
    }
}

private struct MiniPlayerControlButton: View {
    let systemImage: String
    let iconSize: CGFloat
    let diameter: CGFloat
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            iconCircle
                .padding(.top, 6)
                .padding(.trailing, 6)
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .contentShape(.interaction, Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconCircle: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .appGlass(in: Circle(), interactive: true)
            .environment(\.colorScheme, .dark)
    }
}

private struct MiniPlayerPlayPauseButton: View {
    let player: PlayerViewModel
    let bottomInset: CGFloat

    var body: some View {
        let isPlaying = player.session.isPlaying
        Button {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            player.togglePlayPause()
        } label: {
            iconCircle(isPlaying: isPlaying)
                .padding(.bottom, bottomInset)
                .padding(.trailing, 6)
                .frame(width: 44, height: 44, alignment: .bottomTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .contentShape(.interaction, Rectangle())
        .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))
    }

    private func iconCircle(isPlaying: Bool) -> some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 28, height: 28)
            .appGlass(in: Circle(), interactive: true)
            .environment(\.colorScheme, .dark)
    }
}

private struct MiniPlayerLivePill: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 5.5, height: 5.5)
            Text("Live")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

private struct MiniPlayerBufferingIndicator: View {
    let player: PlayerViewModel

    var body: some View {
        if player.clock.isBuffering && player.session.playbackIntent == .playing {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .padding(6)
                .background(Color.black.opacity(0.35), in: Circle())
        }
    }
}

private struct MiniPlayerProgressBar: View {
    let player: PlayerViewModel

    var body: some View {
        let duration = player.clock.duration
        if duration > 0 {
            let displayTime = player.resolvedDisplayTime(mediaTime: player.clock.mediaTime)
            let progress = min(max(displayTime / duration, 0), 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.24))
                    Rectangle()
                        .fill(AccentStore.shared.semanticAccent)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 2.5)
        }
    }
}
