import SwiftUI

struct PlayerBottomControlBar: View {
    let player: PlayerViewModel
    let owner: String
    let gestureDisplay: PlayerGestureDisplay
    let chromeInsets: PlayerChromeInsets
    @AppStorage(DanmakuFeatureGate.defaultsKey) private var danmakuEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            PlayerTransportTimeRow(player: player, owner: owner, gestureDisplay: gestureDisplay)

            HStack(spacing: 4) {
                // Episode navigation (anime): present whenever the owning
                // screen installed the callbacks — auto-play off must not
                // strand the user without a "next episode" control.
                if let previousEpisode = player.onPreviousEpisode {
                    Button(action: previousEpisode) {
                        Image(systemName: "backward.end.fill")
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Previous Episode"))
                }

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .accessibilityIdentifier("player.playPause")
                .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))

                if let nextEpisode = player.onNextEpisode {
                    Button(action: nextEpisode) {
                        Image(systemName: "forward.end.fill")
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Next Episode"))
                }

                if player.mode.isSeekable {
                    Button { player.seek(to: max(0, player.displayTime - 10)) } label: {
                        Image(systemName: "gobackward.10")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }

                    Button { player.seek(to: min(player.duration, player.displayTime + 10)) } label: {
                        Image(systemName: "goforward.10")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }

                if DetailDanmakuEntryPolicy.chromeShowsSendEntry(
                    usesOnlineVODServices: player.mode.usesOnlineVODServices,
                    danmakuEnabled: danmakuEnabled,
                    isLoggedIn: AuthManager.shared.isLoggedIn,
                    isFullscreen: player.isFullscreen
                ) {
                    Button {
                        player.fullscreenDanmakuComposerPresented = true
                    } label: {
                        Text("Send danmaku")
                            .playerChromeCapsule(minHeight: 44)
                    }
                    .accessibilityIdentifier("player.danmakuComposer")
                    .accessibilityLabel(Text("Send danmaku"))
                } else if DetailDanmakuEntryPolicy.chromeShowsLoginToSend(
                    usesOnlineVODServices: player.mode.usesOnlineVODServices,
                    danmakuEnabled: danmakuEnabled,
                    isLoggedIn: AuthManager.shared.isLoggedIn,
                    isFullscreen: player.isFullscreen
                ) {
                    Button {
                        player.requestLoginFromFullscreen()
                    } label: {
                        Text("Log in to send danmaku")
                            .playerChromeCapsule(minHeight: 44)
                    }
                    .accessibilityIdentifier("player.danmakuLoginToSend")
                }

                Spacer()

                if player.isPortraitContent, !player.isFullscreen, player.mode.isSeekable {
                    Button {
                        player.togglePortraitExpand()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityHidden(true)
                    }
                    .accessibilityIdentifier("player.portraitWindow")
                    .accessibilityLabel(Text("Player Window"))
                    .accessibilityValue(Text(verbatim: player.inlineCondensed ? "condensed" : "expanded"))
                }

                Button {
                    player.requestFullscreenTransition(target: !player.isFullscreen, source: .button)
                } label: {
                    Image(systemName: player.isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .accessibilityIdentifier("player.fullscreen")
                .accessibilityLabel(
                    player.isFullscreen ? Text("Exit fullscreen") : Text("Enter fullscreen")
                )
            }
        }
        .padding(.horizontal, (player.isFullscreen ? 0 : 12) + chromeInsets.horizontal)
        // Maintain equal visual spacing above the scrubber in inline (`14`) and
        // fullscreen (`20`, accounting for the outer 8pt overlay padding and +14pt seek lift).
        .padding(.bottom, (player.isFullscreen ? 20 : 14) + chromeInsets.bottom)
        .padding(.top, player.isFullscreen ? 0 : 2)
    }
}
