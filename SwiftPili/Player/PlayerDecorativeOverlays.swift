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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isAppForeground = UIApplication.shared.applicationState != .background

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
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
                            stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white.opacity(0.92), location: 0.68),
                                .init(color: .white.opacity(0.58), location: 0.92),
                                .init(color: .white.opacity(0.32), location: 1.0)
                            ],
                            center: .center,
                            startRadius: 16,
                            endRadius: max(size.width, size.height) * 0.66
                        )
                    )
                    .opacity(PlayerAmbientPolicy.unifiedOpacity(isIncreasedContrast: contrast == .increased))
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

    var body: some View {
        if let source = sourceForDisplay {
            PlayerAmbientBackdrop(source: source)
        }
    }

    private var sourceForDisplay: PlayerAmbientSource? {
        guard let lease = player.currentOwnerLease,
              player.isAmbientVideoLoaded(for: lease),
              player.ambientModeEnabled,
              ExperimentalSettingsPolicy.isAllowed(.ambient),
              (player.mode == .vod || player.mode == .live) else { return nil }
        if let source = player.ambientSource,
           PlayerAmbientPolicy.isEligible(
               mode: player.mode,
               isEnabled: player.ambientModeEnabled,
               hasSource: true
           ) {
            return source
        }
        return PlayerAmbientSource(
            artwork: PlayerAmbientArtwork(url: player.ambientCoverURL ?? "ambient://live-frame"),
            fallbackCover: player.ambientCoverURL
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
        enabled: Bool
    ) -> Bool {
        guard enabled, isOwner, hasSurfaceLease, mode.usesOnlineVODServices,
              let source, !source.isFileURL else { return false }
        return true
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

struct PlayerDanmakuOverlay: View {
    let player: PlayerViewModel

    var body: some View {
        GeometryReader { proxy in
            DanmakuOverlayView(
                scaleMode: player.scaleMode,
                picture: PlayerDanmakuPicture.rect(
                    in: proxy.size,
                    scaleMode: player.scaleMode,
                    resolution: player.videoResolution,
                    isPortraitContent: player.isPortraitContent,
                    portraitHint: player.danmakuPortraitHint
                )
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}
