import SwiftUI
import UIKit

struct PlayerStoryboardThumbnailView: View {
    let image: UIImage
    let aspectRatio: CGFloat
    let isFullscreen: Bool

    var body: some View {
        let height: CGFloat = isFullscreen ? 96 : 68
        let maxWidth: CGFloat = isFullscreen ? 184 : 132
        let targetWidth = min(max(height * aspectRatio, height * 0.6), maxWidth)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: targetWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.42), radius: 8, y: 3)
    }
}

struct PlayerScrubPreviewBubble: View {
    let player: PlayerViewModel
    let seekTime: TimeInterval

    var body: some View {
        let loader = PlayerStoryboardPreviewLoader.shared
        let chapter = player.chapter(at: seekTime)
        VStack(spacing: 4) {
            if let image = loader.previewImage {
                PlayerStoryboardThumbnailView(
                    image: image,
                    aspectRatio: loader.previewAspectRatio,
                    isFullscreen: player.isFullscreen
                )
            }

            VStack(spacing: 2) {
                Text(verbatim:
                    "\(FormatUtils.duration(Int(seekTime))) / \(FormatUtils.duration(Int(player.duration)))"
                )
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)

                if let chapter {
                    Text(chapter.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .frame(maxWidth: player.isFullscreen ? 188 : 144)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
        }
        .allowsHitTesting(false)
    }
}

struct PlayerSwipeSeekHUD: View {
    let player: PlayerViewModel
    let gestureDisplay: PlayerGestureDisplay
    let swipeSeekBase: TimeInterval

    var body: some View {
        let loader = PlayerStoryboardPreviewLoader.shared
        let targetTime = gestureDisplay.seekValue
        let offset = Int(targetTime - swipeSeekBase)
        let chapter = player.chapter(at: targetTime)
        VStack(spacing: 6) {
            if let image = loader.previewImage {
                PlayerStoryboardThumbnailView(
                    image: image,
                    aspectRatio: loader.previewAspectRatio,
                    isFullscreen: player.isFullscreen
                )
            }

            HStack(spacing: 5) {
                Image(systemName: offset < 0 ? "backward.fill" : "forward.fill")
                Text(verbatim: "\(offset < 0 ? "-" : "+")\(FormatUtils.duration(abs(offset)))")
                    .monospacedDigit()
                    .fontWeight(.bold)
                Text(verbatim:
                    "\(FormatUtils.duration(Int(targetTime))) / \(FormatUtils.duration(Int(player.duration)))"
                )
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .playerChromeCapsule()

            if let chapter {
                Text(chapter.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .frame(maxWidth: player.isFullscreen ? 260 : 200)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

struct PlayerVerticalAdjustHUD: View {
    let gestureDisplay: PlayerGestureDisplay
    let verticalAdjustIsVolume: Bool

    var body: some View {
        let pct = gestureDisplay.verticalAdjustValue
        let icon: String = verticalAdjustIsVolume
            ? (pct <= 0.001 ? "speaker.slash.fill" : pct < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
            : (pct < 0.5 ? "sun.min.fill" : "sun.max.fill")
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                GeometryReader { geo in
                    Capsule().fill(.white).frame(width: geo.size.width * CGFloat(pct))
                }
            }
            .frame(width: 96, height: 4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}
