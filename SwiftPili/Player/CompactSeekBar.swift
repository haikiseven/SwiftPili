import SwiftUI

struct SeekBarSegment: Identifiable {
    let id: String
    let start: Double
    let end: Double
    let color: Color
    let isPOI: Bool
}

struct CompactSeekBar: View {
    let progress: Double
    var buffered: Double = 0
    var segments: [SeekBarSegment] = []
    var chapterFractions: [Double] = []
    let isScrubbing: Bool
    var prominent = true
    let onScrub: (Double) -> Void
    let onCommit: () -> Void

    @AppMotion private var motion
    @GestureState private var isTouching = false

    private var scrubChromeAnimation: Animation? {
        motion.animation(normal: .easeInOut(duration: 0.15))
    }

    var body: some View {
        strip
    }

    private var strip: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fills = FillWidths(
                progress: progress,
                buffered: buffered,
                width: width,
                isScrubbing: isScrubbing
            )
            let barHeight: CGFloat = isScrubbing ? 6 : 2
            let knobSize: CGFloat = isScrubbing ? 14 : 10
            ZStack(alignment: .leading) {
                chromeAnimated(Capsule().fill(.white.opacity(prominent || isScrubbing ? 0.3 : 0.2)))
                timingFills(fills)
                ForEach(segments) { seg in
                    sponsorBand(seg, width: width)
                }
                .transaction(value: width) { $0.animation = nil }
                ForEach(chapterFractions.indices, id: \.self) { index in
                    chapterTick(chapterFractions[index], width: width)
                }
                .transaction(value: width) { $0.animation = nil }
            }
            .clipShape(Capsule())
            .frame(height: barHeight)
            .animation(scrubChromeAnimation, value: isScrubbing)
            .overlay(alignment: .leading) {
                playheadKnob(position: fills.played, size: knobSize)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouching) { _, touching, _ in touching = true }
                    .onChanged { gesture in
                        onScrub(min(max(gesture.location.x / width, 0), 1))
                    }
            )
        }
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text("\(Int(((progress.isFinite ? min(max(progress, 0), 1) : 0) * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            let current = progress.isFinite ? min(max(progress, 0), 1) : 0
            let next: Double
            switch direction {
            case .increment:
                next = min(1, current + 0.05)
            case .decrement:
                next = max(0, current - 0.05)
            @unknown default:
                return
            }
            onScrub(next)
            onCommit()
        }
        .onChange(of: isTouching) { _, touching in
            if !touching { onCommit() }
        }
    }

    private func timingFills(_ fills: FillWidths) -> some View {
        ZStack(alignment: .leading) {
            chromeAnimated(Rectangle().fill(.white.opacity(prominent || isScrubbing ? 0.5 : 0.35)))
                .frame(width: max(0, fills.buffered - fills.played))
                .offset(x: fills.played)
            chromeAnimated(Rectangle().fill(Color.biliAccent.opacity(prominent || isScrubbing ? 1 : 0.85)))
                .frame(width: fills.played)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction(value: fills) { $0.animation = nil }
    }

    private func playheadKnob(position: CGFloat, size: CGFloat) -> some View {
        Color.clear
            .frame(width: 0)
            .overlay {
                chromeAnimated(
                    Circle()
                        .fill(.white)
                        .frame(width: size, height: size)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .opacity(prominent || isScrubbing ? 1 : 0)
                )
            }
            .offset(x: position)
            .transaction(value: position) { $0.animation = nil }
    }

    private func chromeAnimated<Content: View>(_ content: Content) -> some View {
        content
            .animation(scrubChromeAnimation, value: isScrubbing)
            .animation(motion.animation(normal: .easeInOut(duration: 0.2)), value: prominent)
    }

    private struct FillWidths: Equatable {
        let played: CGFloat
        let buffered: CGFloat

        init(progress: Double, buffered: Double, width: CGFloat, isScrubbing: Bool) {
            let playhead = Self.normalized(progress)
            let bufferedFraction = Self.normalized(buffered)
            played = playhead * width
            self.buffered = (isScrubbing ? bufferedFraction : max(playhead, bufferedFraction)) * width
        }

        private static func normalized(_ fraction: Double) -> Double {
            fraction.isFinite ? min(max(fraction, 0), 1) : 0
        }
    }

    @ViewBuilder
    private func sponsorBand(_ seg: SeekBarSegment, width: CGFloat) -> some View {
        let start = min(max(seg.start, 0), 1) * width
        if seg.isPOI {
            chromeAnimated(Capsule().fill(seg.color.opacity(prominent || isScrubbing ? 1 : 0.85)))
                .frame(width: 2)
                .offset(x: start - 1)
        } else {
            let end = min(max(seg.end, 0), 1) * width
            chromeAnimated(Capsule().fill(seg.color.opacity(prominent || isScrubbing ? 0.95 : 0.75)))
                .frame(width: max(end - start, 1.5))
                .offset(x: start)
        }
    }

    @ViewBuilder
    private func chapterTick(_ fraction: Double, width: CGFloat) -> some View {
        let clamped = min(max(fraction, 0), 1)
        if clamped > 0.005, clamped < 0.995 {
            let tickWidth: CGFloat = isScrubbing ? 2 : 1.5
            Rectangle()
                .fill(Color.black.opacity(prominent || isScrubbing ? 0.7 : 0.48))
                .frame(width: tickWidth)
                .offset(x: clamped * width - tickWidth * 0.5)
        }
    }
}
