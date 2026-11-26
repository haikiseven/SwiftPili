import SwiftUI

struct PlayerControlsScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.46), location: 0),
                .init(color: .black.opacity(0.12), location: 0.12),
                .init(color: .clear, location: 0.28),
                .init(color: .clear, location: 0.72),
                .init(color: .black.opacity(0.4), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PlayerControlsOverlay: View {
    let player: PlayerViewModel
    let owner: String
    let screenLease: PlayerOwnerLease?
    let presentationReceipt: PlayerPresentationReceipt?
    let fullscreenHostIdentity: UUID?
    let gestureDisplay: PlayerGestureDisplay
    let liveQualityControl: LiveQualityControl?
    let pageNavigationActions: PlayerPageNavigationActions?
    let showsAnimeOptions: Bool
    let chromeInsets: PlayerChromeInsets
    let transportPlacement: PlayerTransportPlacement
    let suppressTransportRow: Bool
    @Binding var danmakuPanelPresented: Bool
    @Binding var subtitlePanelPresented: Bool
    @Binding var showSponsorBlock: Bool

    var body: some View {
        ZStack {
            PlayerControlsScrim()

            VStack(spacing: 0) {
                PlayerTopControlBar(
                    player: player, screenLease: screenLease,
                    presentationReceipt: presentationReceipt, fullscreenHostIdentity: fullscreenHostIdentity,
                    liveQualityControl: liveQualityControl,
                    pageNavigationActions: pageNavigationActions,
                    showsAnimeOptions: showsAnimeOptions,
                    chromeInsets: chromeInsets,
                    danmakuPanelPresented: $danmakuPanelPresented,
                    subtitlePanelPresented: $subtitlePanelPresented,
                    showSponsorBlock: $showSponsorBlock
                )
                Spacer()
                if transportPlacement == .playerBottomEdge, !suppressTransportRow {
                    PlayerBottomControlBar(
                        player: player, owner: owner, gestureDisplay: gestureDisplay, chromeInsets: chromeInsets
                    )
                }
            }
            .padding(.top, player.isFullscreen ? 8 : 0)
            .padding(.bottom, player.isFullscreen ? 8 : 0)
        }
        .ignoresSafeArea(.keyboard, edges: .all)
        .transition(.opacity)
    }
}
