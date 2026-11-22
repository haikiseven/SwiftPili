import QuartzCore
import UIKit

/// Person-mask anti-occlusion on the danmaku container (Phase C).
///
/// The mask is a `CAShapeLayer` on `container.mask`. Each loaded 10s segment
/// becomes ONE discrete keyframe animation of the mask's `path`, whose
/// `beginTime` is the segment's start in media seconds. The mask runs on the
/// container's clock — `DanmakuClockSync` makes that clock media time, and
/// `DanmakuMaskTimingTests` renders through the render server to prove the
/// mask inherits it — so the render server switches frames, and play, pause,
/// rate and seek need nothing here. There is no display link and no per-frame
/// main-thread work.
///
/// The mask's model path is the full container, so any time no segment covers
/// (not loaded yet, a gap, before the first frame) shows every bullet: a
/// missing mask degrades to "no anti-occlusion", never to "no danmaku".
@MainActor
final class DanmakuMaskRenderer {
    private let container: CALayer
    private let maskLayer = CAShapeLayer()
    private var segments: [Int: DanmakuMaskSegment] = [:]
    private var bounds: CGRect = .zero
    private var fit: VideoScaleMode = .fit
    private(set) var isEnabled: Bool

    init(container: CALayer, enabled: Bool) {
        self.container = container
        isEnabled = enabled
        maskLayer.fillColor = UIColor.black.cgColor
        maskLayer.fillRule = .nonZero
    }

    var segmentCount: Int { segments.count }

    /// The full set the store holds. New indices get an animation, missing
    /// ones lose theirs; a segment's content never changes under one store,
    /// and a new store starts from `clear()`.
    func sync(_ next: [Int: DanmakuMaskSegment]) {
        for index in segments.keys where next[index] == nil {
            maskLayer.removeAnimation(forKey: Self.key(index))
        }
        let added = next.filter { segments[$0.key] == nil }
        segments = next
        withoutActions {
            for segment in added.values { install(segment) }
            updateAttachment()
        }
    }

    func clear() {
        segments.removeAll()
        withoutActions {
            maskLayer.removeAllAnimations()
            updateAttachment()
        }
    }

    /// The Smart Anti-Occlusion switch. Off detaches the mask and keeps the
    /// segments, so turning it back on is immediate.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        withoutActions { updateAttachment() }
    }

    /// The container's bounds or the scale mode changed: every animation's
    /// paths are in container points, so all of them are rebuilt.
    func setGeometry(bounds newBounds: CGRect, fit newFit: VideoScaleMode) {
        guard newBounds != bounds || newFit != fit else { return }
        bounds = newBounds
        fit = newFit
        withoutActions {
            maskLayer.removeAllAnimations()
            maskLayer.frame = newBounds
            maskLayer.path = CGPath(rect: CGRect(origin: .zero, size: newBounds.size), transform: nil)
            for segment in segments.values { install(segment) }
            updateAttachment()
        }
    }

    /// Attached only with something to show AND a real size: a zero-size mask
    /// would hide the whole container, which is worse than no mask at all.
    private func updateAttachment() {
        let wanted = isEnabled && !segments.isEmpty && bounds.width > 0 && bounds.height > 0
        if wanted, container.mask !== maskLayer {
            maskLayer.frame = bounds
            maskLayer.path = CGPath(rect: CGRect(origin: .zero, size: bounds.size), transform: nil)
            container.mask = maskLayer
        } else if !wanted, container.mask != nil {
            container.mask = nil
        }
    }

    private func install(_ segment: DanmakuMaskSegment) {
        guard !segment.frames.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let transform = Self.transform(canvas: segment.canvas, bounds: bounds.size, fit: fit)
        let bars = Self.letterbox(canvas: segment.canvas, bounds: bounds.size, fit: fit)
        let paths: [CGPath] = segment.frames.map { frame in
            let visible = CGMutablePath()
            visible.addPath(frame.path, transform: transform)
            for bar in bars { visible.addRect(bar) }
            return visible
        }
        guard let timing = Self.timing(for: segment) else { return }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = paths
        animation.keyTimes = timing.keyTimes.map { NSNumber(value: $0) }
        animation.calculationMode = .discrete
        animation.beginTime = timing.beginTime
        animation.duration = timing.duration
        // Outside its own 10s the segment must not apply: the model path (the
        // full rect) shows through, and a neighbour's animation takes over.
        animation.fillMode = .removed
        animation.isRemovedOnCompletion = false
        maskLayer.add(animation, forKey: Self.key(segment.index))
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static func key(_ index: Int) -> String { "mask.\(index)" }

    // MARK: - Pure geometry and timing

    struct Timing: Equatable, Sendable {
        let beginTime: TimeInterval
        let duration: TimeInterval
        /// One more entry than frames, as `.discrete` requires: frame k shows
        /// from `keyTimes[k]` to `keyTimes[k + 1]`.
        let keyTimes: [Double]
    }

    /// A `beginTime` of exactly 0 means "now" to Core Animation, which would
    /// start the video's first segment at whatever media time it is added —
    /// so a segment starting at 0 begins a microsecond later instead.
    nonisolated static let earliestBeginTime: TimeInterval = 0.000_001

    nonisolated static func timing(for segment: DanmakuMaskSegment) -> Timing? {
        let begin = max(segment.start, earliestBeginTime)
        let duration = segment.end - begin
        guard duration > 0, !segment.frames.isEmpty else { return nil }
        var keyTimes: [Double] = [0]
        var previous = 0.0
        for frame in segment.frames.dropFirst() {
            let fraction = min(1, max(previous, (frame.time - begin) / duration))
            keyTimes.append(fraction)
            previous = fraction
        }
        keyTimes.append(1)
        return Timing(beginTime: begin, duration: duration, keyTimes: keyTimes)
    }

    /// The picture inside the container: where the video actually is.
    ///
    /// The container is the whole player (bullets fly over letterbox bars, as
    /// in PiliPlus and wiliwili), so the mask places the picture itself, from
    /// the canvas — which has the video's aspect — the way wiliwili's
    /// `drawMask` does: `.fit` is the aspect-fit rectangle, centred; `.fill`
    /// the aspect-fill one, centred and overflowing; `.stretch` the container.
    ///
    /// The canvas's bottom pixel row is never filled (potrace paths start one
    /// pixel up), so the mapped canvas is `W × (H − 1)` — stretched over the
    /// picture the way wiliwili stretches its texture, or the bottom row of
    /// every bullet would be cut.
    nonisolated static func picture(canvas: CGSize, bounds: CGSize, fit: VideoScaleMode) -> CGRect {
        let width = max(canvas.width, 1)
        let height = max(canvas.height - 1, 1)
        let scale: CGFloat
        switch fit {
        case .stretch:
            return CGRect(origin: .zero, size: bounds)
        case .fit:
            scale = min(bounds.width / width, bounds.height / height)
        case .fill:
            scale = max(bounds.width / width, bounds.height / height)
        }
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Canvas (SVG viewBox, y down) → container points.
    nonisolated static func transform(canvas: CGSize, bounds: CGSize, fit: VideoScaleMode) -> CGAffineTransform {
        let rect = picture(canvas: canvas, bounds: bounds, fit: fit)
        let width = max(canvas.width, 1)
        let height = max(canvas.height - 1, 1)
        return CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / width, y: rect.height / height)
    }

    /// The container outside the picture. No person is there, so each frame
    /// adds these to its visible region: a letterbox bar never hides bullets.
    nonisolated static func letterbox(canvas: CGSize, bounds: CGSize, fit: VideoScaleMode) -> [CGRect] {
        let container = CGRect(origin: .zero, size: bounds)
        let rect = picture(canvas: canvas, bounds: bounds, fit: fit).intersection(container)
        guard !rect.isNull, !rect.isEmpty else { return [container] }
        return [
            CGRect(x: 0, y: 0, width: bounds.width, height: rect.minY),
            CGRect(x: 0, y: rect.maxY, width: bounds.width, height: bounds.height - rect.maxY),
            CGRect(x: 0, y: rect.minY, width: rect.minX, height: rect.height),
            CGRect(x: rect.maxX, y: rect.minY, width: bounds.width - rect.maxX, height: rect.height),
        ].filter { $0.width > 0.5 && $0.height > 0.5 }
    }
}
