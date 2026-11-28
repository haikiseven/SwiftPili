import SwiftUI
import UIKit

enum PlayerAmbientPolicy {
    static let analysisBox = CGSize(width: 64, height: 36)
    static let blurRadius: CGFloat = 7.5
    static let saturation: Double = 1.14
    static let groundColor = Color(white: 0.035)
    static let crossFadeDuration: Double = 0.65

    static func unifiedOpacity(isIncreasedContrast: Bool) -> Double {
        isIncreasedContrast ? 0.22 : 0.34
    }

    static func storyImmersiveOpacity(isIncreasedContrast: Bool) -> Double {
        isIncreasedContrast ? 0.68 : 0.92
    }

    static func isEligible(
        mode: PlayerMode,
        isEnabled: Bool,
        hasSource: Bool
    ) -> Bool {
        mode == .vod && isEnabled && hasSource
    }

    static func backdropOpacity(isDarkAppearance: Bool) -> Double {
        isDarkAppearance ? 0.36 : 0.26
    }

    static func scrimOpacity(isDarkAppearance: Bool, isIncreasedContrast: Bool = false) -> Double {
        if isIncreasedContrast {
            return isDarkAppearance ? 0.66 : 0.44
        }
        return isDarkAppearance ? 0.46 : 0.24
    }

    static func scale(from source: CGSize, toCover target: CGSize) -> CGFloat {
        guard source.width > 0, source.height > 0,
              target.width > 0, target.height > 0,
              source.width.isFinite, source.height.isFinite,
              target.width.isFinite, target.height.isFinite else { return 1 }
        return max(target.width / source.width, target.height / source.height)
    }

    static func sourceURL(
        at time: TimeInterval,
        storyboard: [PlayerAmbientStoryboardFrame],
        fallback: String?
    ) -> String? {
        guard time.isFinite, time >= 0 else { return fallback }
        if let current = storyboard.first(where: { time >= $0.from && time < $0.to }) {
            return current.url
        }
        if let previous = storyboard.last(where: { $0.from <= time }) {
            return previous.url
        }
        return fallback
    }
}

struct PlayerAmbientBackdrop: View {
    let source: PlayerAmbientSource
    var isPortraitImmersive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isAppForeground = UIApplication.shared.applicationState != .background

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let effectiveOpacity = isPortraitImmersive
                ? PlayerAmbientPolicy.storyImmersiveOpacity(isIncreasedContrast: contrast == .increased)
                : PlayerAmbientPolicy.unifiedOpacity(isIncreasedContrast: contrast == .increased)
            let maskStops: [Gradient.Stop] = isPortraitImmersive
                ? [
                    .init(color: .white, location: 0.0),
                    .init(color: .white.opacity(0.96), location: 0.75),
                    .init(color: .white.opacity(0.86), location: 1.0)
                ]
                : [
                    .init(color: .white, location: 0.0),
                    .init(color: .white.opacity(0.92), location: 0.68),
                    .init(color: .white.opacity(0.58), location: 0.92),
                    .init(color: .white.opacity(0.32), location: 1.0)
                ]
            ZStack {
                PlayerAmbientPolicy.groundColor
                if isAppForeground, !reduceTransparency {
                    ZStack {
                        PlayerAmbientArtworkView(source: source)
                            .blur(radius: PlayerAmbientPolicy.blurRadius, opaque: true)
                            .saturation(PlayerAmbientPolicy.saturation)
                            .scaleEffect(
                                PlayerAmbientPolicy.scale(
                                    from: PlayerAmbientPolicy.analysisBox,
                                    toCover: size
                                )
                            )
                            .frame(width: size.width, height: size.height)
                            .clipped()
                        AmbientLiveLayerView()
                            .frame(width: size.width, height: size.height)
                    }
                    .mask(
                        RadialGradient(
                            stops: maskStops,
                            center: .center,
                            startRadius: 16,
                            endRadius: max(size.width, size.height) * 0.66
                        )
                    )
                    .opacity(effectiveOpacity)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            isAppForeground = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            isAppForeground = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isAppForeground = false
        }
    }
}

struct PlayerFullscreenAmbientBackdrop: View {
    let player: PlayerViewModel
    var isPortraitImmersive = false
    var fallbackCoverURL: String? = nil

    var body: some View {
        if let source = sourceForDisplay {
            PlayerAmbientBackdrop(
                source: source,
                isPortraitImmersive: isPortraitImmersive
            )
        }
    }

    private var sourceForDisplay: PlayerAmbientSource? {
        guard let lease = player.currentOwnerLease,
              player.isAmbientVideoLoaded(for: lease),
              player.ambientModeEnabled,
              ExperimentalSettingsPolicy.isAllowed(.ambient),
              (player.mode == .vod
                || player.mode == .live
                || (isPortraitImmersive && player.mode == .offline)) else { return nil }
        if let source = player.ambientSource,
           PlayerAmbientPolicy.isEligible(
               mode: player.mode,
               isEnabled: player.ambientModeEnabled,
               hasSource: true
           ) {
            return source
        }
        let cover = player.ambientCoverURL ?? fallbackCoverURL
        return PlayerAmbientSource(
            artwork: PlayerAmbientArtwork(url: cover ?? "ambient://live-frame"),
            fallbackCover: cover
        )
    }
}

struct OutgoingRouteStillView: View {
    let image: UIImage
    let height: CGFloat

    var body: some View {
        Color.black
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum PlayerDanmakuMountPolicy {
    static func shouldMount(
        mode: PlayerMode,
        source: URL?,
        isOwner: Bool,
        hasSurfaceLease: Bool,
        enabled: Bool,
        hasOfflineDanmaku: Bool = false
    ) -> Bool {
        guard enabled, isOwner, hasSurfaceLease, let source else { return false }
        if mode.usesOnlineVODServices {
            return !source.isFileURL
        }
        if mode == .offline {
            return hasOfflineDanmaku && source.isFileURL
        }
        return false
    }
}

enum PlayerDanmakuPicture {
    static func rect(
        in playerSize: CGSize,
        scaleMode: VideoScaleMode,
        resolution: String,
        isPortraitContent: Bool,
        portraitHint: Bool? = nil
    ) -> CGRect {
        guard playerSize.width > 0, playerSize.height > 0,
              playerSize.width.isFinite, playerSize.height.isFinite
        else { return .zero }

        switch scaleMode {
        case .fill, .stretch:
            return CGRect(origin: .zero, size: playerSize)
        case .fit:
            break
        }

        let video = sourceSize(
            resolution: resolution,
            isPortraitContent: isPortraitContent,
            portraitHint: portraitHint
        )
        let scale = min(
            playerSize.width / video.width,
            playerSize.height / video.height
        )
        let fitted = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(
            x: (playerSize.width - fitted.width) / 2,
            y: (playerSize.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private static func sourceSize(
        resolution: String,
        isPortraitContent: Bool,
        portraitHint: Bool?
    ) -> CGSize {
        let parts = resolution.split(whereSeparator: { $0 == "×" || $0 == "x" || $0 == "X" })
        if parts.count == 2,
           let width = Double(parts[0]),
           let height = Double(parts[1]),
           width > 0, height > 0,
           width.isFinite, height.isFinite {
            let codedPortrait = height > width
            if let portraitHint, codedPortrait != portraitHint {
                return CGSize(width: height, height: width)
            }
            return CGSize(width: width, height: height)
        }
        let portrait = portraitHint ?? isPortraitContent
        return portrait ? CGSize(width: 9, height: 16) : CGSize(width: 16, height: 9)
    }
}

struct DanmakuSymbolIcon: View {
    static let activeSymbolName = "bubble.left.and.text.bubble.right.fill"
    static let inactiveSymbolName = "bubble.left.and.text.bubble.right"

    let isOn: Bool
    var fontSize: CGFloat = 13.2
    var matchesSubheadlineCapsuleMetrics = false
    var activeColor: Color = .biliAccent
    var inactiveColor: Color = .white.opacity(0.90)

    var body: some View {
        if matchesSubheadlineCapsuleMetrics {
            Image(systemName: "captions.bubble")
                .font(.subheadline.weight(.semibold))
                .hidden()
                .overlay {
                    renderedGlyph
                }
        } else {
            renderedGlyph
        }
    }

    @ViewBuilder
    private var renderedGlyph: some View {
        if isOn {
            Image(systemName: Self.activeSymbolName)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(activeColor)
        } else {
            let slashSpan = fontSize * 1.34
            Image(systemName: Self.inactiveSymbolName)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(inactiveColor)
                .compositingGroup()
                .mask {
                    ZStack {
                        Rectangle()
                            .fill(.white)
                            .padding(-4)
                        Capsule()
                            .fill(.black)
                            .frame(width: slashSpan * 1.06, height: max(2.8, fontSize * 0.21))
                            .rotationEffect(.degrees(-42))
                    }
                    .compositingGroup()
                    .luminanceToAlpha()
                }
                .overlay {
                    Capsule()
                        .fill(inactiveColor)
                        .frame(width: slashSpan, height: max(1.35, fontSize * 0.105))
                        .rotationEffect(.degrees(-42))
                }
        }
    }
}

struct PlayerDanmakuOverlay: View {
    let player: PlayerViewModel
    var topSafeInset: CGFloat = 0

    static func topInsetViewportHeight(totalHeight: CGFloat, topSafeInset: CGFloat) -> CGFloat {
        let clampedTop = min(max(0, topSafeInset), max(0, totalHeight - 1))
        return max(0, totalHeight - clampedTop)
    }

    var body: some View {
        GeometryReader { proxy in
            let clampedTop = min(max(0, topSafeInset), max(0, proxy.size.height - 1))
            let safeHeight = Self.topInsetViewportHeight(
                totalHeight: proxy.size.height,
                topSafeInset: clampedTop
            )
            let fullPicture = PlayerDanmakuPicture.rect(
                in: proxy.size,
                scaleMode: player.scaleMode,
                resolution: player.videoResolution,
                isPortraitContent: player.isPortraitContent,
                portraitHint: player.danmakuPortraitHint
            )
            let shiftedPicture = clampedTop > 0
                ? fullPicture.offsetBy(dx: 0, dy: -clampedTop)
                : fullPicture
            DanmakuOverlayView(
                scaleMode: player.scaleMode,
                picture: shiftedPicture
            )
            .frame(width: proxy.size.width, height: safeHeight)
            .offset(y: clampedTop)
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}
