import SwiftUI

struct PlayerSwipeSeekHUD: View {
    let player: PlayerViewModel
    let gestureDisplay: PlayerGestureDisplay
    let swipeSeekBase: TimeInterval

    var body: some View {
        let offset = Int(gestureDisplay.seekValue - swipeSeekBase)
        HStack(spacing: 5) {
            Image(systemName: offset < 0 ? "backward.fill" : "forward.fill")
            Text(verbatim: "\(offset < 0 ? "-" : "+")\(FormatUtils.duration(abs(offset)))")
                .monospacedDigit()
                .fontWeight(.bold)
            Text(verbatim:
                "\(FormatUtils.duration(Int(gestureDisplay.seekValue))) / \(FormatUtils.duration(Int(player.duration)))"
            )
                .monospacedDigit()
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.75))
        }
        .playerChromeCapsule()
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
