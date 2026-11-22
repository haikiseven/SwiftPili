import QuartzCore
import UIKit

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

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        withoutActions { updateAttachment() }
    }

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
        let keyTimes: [Double]
    }

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

    nonisolated static func transform(canvas: CGSize, bounds: CGSize, fit: VideoScaleMode) -> CGAffineTransform {
        let rect = picture(canvas: canvas, bounds: bounds, fit: fit)
        let width = max(canvas.width, 1)
        let height = max(canvas.height - 1, 1)
        return CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / width, y: rect.height / height)
    }

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
