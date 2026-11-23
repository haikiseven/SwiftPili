import SwiftUI

struct CinematicBackdrop: View {
    let coverURL: String?
    var player: PlayerViewModel?
    var ownerLease: PlayerOwnerLease?
    var isRouteActive = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private static let crossFadeDuration = 1.05
    private static let sourceBlur: CGFloat = PlayerAmbientPolicy.blurRadius
    private static let horizontalOverscan: CGFloat = 1.38

    var body: some View {
        GeometryReader { outerProxy in
            let safeTop = max(outerProxy.safeAreaInsets.top, 48)
            ZStack(alignment: .top) {
                PlayerAmbientPolicy.groundColor
                GeometryReader { proxy in
                    let envelope = ambientEnvelope(for: proxy.size, safeTop: safeTop)
                    ZStack(alignment: .top) {
                        if !reduceTransparency, let source = sourceForDisplay {
                            ZStack {
                                PlayerAmbientArtworkView(
                                    source: source,
                                    crossFadeDuration: Self.crossFadeDuration
                                )
                                    .blur(radius: Self.sourceBlur, opaque: true)
                                    .saturation(PlayerAmbientPolicy.saturation)
                                    .scaleEffect(
                                        x: scale(
                                            proxy.size.width * Self.horizontalOverscan,
                                            source: PlayerAmbientPolicy.analysisBox.width
                                        ),
                                        y: scale(
                                            envelope.height,
                                            source: PlayerAmbientPolicy.analysisBox.height
                                        )
                                    )
                                    .frame(width: proxy.size.width, height: envelope.height)
                                    .clipped()
                                AmbientLiveLayerView()
                                    .frame(
                                        width: proxy.size.width * Self.horizontalOverscan,
                                        height: envelope.height
                                    )
                                    .frame(width: proxy.size.width, height: envelope.height)
                                    .clipped()
                            }
                            .mask(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .white.opacity(0.76), location: 0.0),
                                            .init(
                                                color: .white.opacity(0.96),
                                                location: envelope.playerTopFraction
                                            ),
                                            .init(
                                                color: .white.opacity(0.92),
                                                location: envelope.playerBottomFraction
                                            ),
                                            .init(
                                                color: .white.opacity(0.46),
                                                location: envelope.midBleedFraction
                                            ),
                                            .init(color: .white.opacity(0.14), location: 0.88),
                                            .init(color: .clear, location: 1.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .mask(
                                    RadialGradient(
                                        stops: [
                                            .init(color: .white, location: 0.0),
                                            .init(color: .white.opacity(0.92), location: 0.62),
                                            .init(color: .white.opacity(0.48), location: 0.88),
                                            .init(color: .clear, location: 1.0)
                                        ],
                                        center: UnitPoint(x: 0.5, y: envelope.playerCenterFraction),
                                        startRadius: 12,
                                        endRadius: max(proxy.size.width * 0.78, envelope.height * 0.65)
                                    )
                                )
                                .opacity(PlayerAmbientPolicy.unifiedOpacity(isIncreasedContrast: contrast == .increased))
                                .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: sourceForDisplay != nil)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .clipped()
                }
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct AmbientEnvelope {
        let height: CGFloat
        let playerTopFraction: CGFloat
        let playerCenterFraction: CGFloat
        let playerBottomFraction: CGFloat
        let midBleedFraction: CGFloat
    }

    private func ambientEnvelope(for size: CGSize, safeTop: CGFloat) -> AmbientEnvelope {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return AmbientEnvelope(
                height: 410,
                playerTopFraction: 0.14,
                playerCenterFraction: 0.42,
                playerBottomFraction: 0.68,
                midBleedFraction: 0.82
            )
        }
        if size.height > size.width {
            let playerHeight = size.width * 9.0 / 16.0
            let bleedBelow = min(136, max(108, playerHeight * 0.54))
            let totalHeight = min(size.height, safeTop + playerHeight + bleedBelow)
            let topFrac = min(0.24, max(0.08, safeTop / totalHeight))
            let bottomFrac = min(0.76, max(topFrac + 0.28, (safeTop + playerHeight) / totalHeight))
            let centerFrac = (topFrac + bottomFrac) * 0.5
            let midBleedFrac = min(0.86, bottomFrac + (1.0 - bottomFrac) * 0.46)
            return AmbientEnvelope(
                height: totalHeight,
                playerTopFraction: topFrac,
                playerCenterFraction: centerFrac,
                playerBottomFraction: bottomFrac,
                midBleedFraction: midBleedFrac
            )
        }
        let landscapeHeight = size.height * 0.86
        return AmbientEnvelope(
            height: landscapeHeight,
            playerTopFraction: 0.08,
            playerCenterFraction: 0.44,
            playerBottomFraction: 0.72,
            midBleedFraction: 0.84
        )
    }

    private var isLiveAmbientEligible: Bool {
        guard isRouteActive, let player, let ownerLease else { return false }
        return player.isAmbientVideoLoaded(for: ownerLease)
            && player.ambientModeEnabled
            && ExperimentalSettingsPolicy.isAllowed(.ambient)
    }

    private var sourceForDisplay: PlayerAmbientSource? {
        guard isLiveAmbientEligible, let player else { return nil }
        if let source = player.ambientSource {
            return source
        }
        guard let cover = coverURL.flatMap(PlayerAmbientStoryboardFrame.normalizedURL)
            ?? player.ambientCoverURL else { return nil }
        return PlayerAmbientSource(artwork: PlayerAmbientArtwork(url: cover), fallbackCover: cover)
    }

    private func scale(_ dimension: CGFloat, source: CGFloat) -> CGFloat {
        guard dimension.isFinite, dimension > 0 else { return 1 }
        return dimension / source
    }
}
