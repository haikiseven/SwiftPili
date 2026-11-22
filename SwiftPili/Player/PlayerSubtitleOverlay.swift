import SwiftUI

struct PlayerSubtitleOverlay: View {
    let player: PlayerViewModel

    var body: some View {
        if let subtitle = player.subtitleText, !subtitle.isEmpty {
            Text(subtitle)
                .font(player.isFullscreen ? .title3 : .footnote)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 24)
                .padding(.bottom, player.isFullscreen ? 52 : 28)
                .allowsHitTesting(false)
        }
    }
}
