import QuartzCore
import UIKit

@MainActor
protocol DanmakuTimelineSink: AnyObject {
    func applyTiming(_ timing: DanmakuClockSync.LayerTiming, mediaTime: TimeInterval)
    func resync(mediaTime: TimeInterval, rate: Float, isPlaying: Bool)
    func seeked(to mediaTime: TimeInterval)
    func admit(_ items: [DanmakuElem], laneHeight: CGFloat)
    func reclaimFinished(at mediaTime: TimeInterval)
    func teardown()
    func syncMask(_ segments: [Int: DanmakuMaskSegment])
    func clearMask()
}

@MainActor
final class DanmakuRenderController: DanmakuTimelineSink {
    static let poolCapacity = 700

    private static let disabledLayerActions: [String: CAAction] = [
        "position": NSNull(),
        "bounds": NSNull(),
        "frame": NSNull(),
        "opacity": NSNull(),
        "contents": NSNull(),
        "transform": NSNull(),
        "sublayers": NSNull(),
        "onOrderIn": NSNull(),
        "onOrderOut": NSNull(),
    ]

    nonisolated static func animationIsLive(
        progress: TimeInterval, lifetime: TimeInterval, at mediaTime: TimeInterval
    ) -> Bool {
        guard progress.isFinite, lifetime.isFinite, mediaTime.isFinite, lifetime >= 0 else {
            return false
        }
        return progress + lifetime > mediaTime
    }

    let container = CALayer()
    private(set) lazy var mask = DanmakuMaskRenderer(
        container: container,
        enabled: DanmakuRenderPreferences.smartMaskEnabled()
    )
    private var pool: [CALayer] = []
    private var live: [Int64: LiveBullet] = [:]
    private struct PendingBullet {
        let ticket: UInt64
        let isSelfSent: Bool
    }
    private var pending: [Int64: PendingBullet] = [:]
    private var nextAdmissionTicket: UInt64 = 0
    private var clockMediaTime: TimeInterval = 0
    private var allocator: DanmakuTrackLayout.Allocator
    typealias Rasterize = (
        DanmakuTextRasterizer.Key,
        @escaping @Sendable (CGFloat) -> Bool,
        @escaping @Sendable (DanmakuTextRasterizer.Image?) -> Void
    ) -> Void

    private let rasterize: Rasterize
    private let canDisplay: @MainActor () -> Bool
    private let rasterWork = DanmakuRasterWorkState()
    private var metrics: DanmakuTrackLayout.Metrics
    private var appliedViewport: CGSize
    private var appliedPicture: CGRect
    private var generation: UInt64 = 0

    init(
        viewport: CGSize = CGSize(width: 1, height: 1),
        laneCount: Int = 8,
        rasterize: Rasterize? = nil,
        canDisplay: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.canDisplay = canDisplay
        let rasterizer = DanmakuTextRasterizer()
        self.rasterize = rasterize ?? { key, canRender, completion in
            rasterizer.image(for: key, canRender: canRender, completion: completion)
        }
        let size = CGSize(width: max(viewport.width, 1), height: max(viewport.height, 1))
        appliedViewport = size
        appliedPicture = CGRect(origin: .zero, size: size)
        metrics = DanmakuTrackLayout.Metrics(
            width: Double(size.width),
            laneCount: laneCount
        )
        allocator = DanmakuTrackLayout.Allocator(metrics: metrics)
        updateRasterClock(0)
        container.masksToBounds = true
        container.actions = Self.disabledLayerActions
        for _ in 0..<Self.poolCapacity {
            let layer = CALayer()
            layer.contentsScale = UIScreen.main.scale
            layer.actions = Self.disabledLayerActions
            pool.append(layer)
        }
    }

    private struct LiveBullet {
        let layer: CALayer
        let endsAt: TimeInterval
        let isSelfSent: Bool
    }

    private(set) var presentation: DanmakuPresentation = .inline

    @discardableResult
    func resize(
        viewport: CGSize,
        picture: CGRect? = nil,
        presentation: DanmakuPresentation,
        preferences: DanmakuRenderPreferences,
        maskFit: VideoScaleMode = .fit,
        force: Bool = false
    ) -> Bool {
        let size = CGSize(width: max(viewport.width, 1), height: max(viewport.height, 1))
        let next = preferences.trackMetrics(
            width: Double(size.width),
            height: Double(size.height),
            presentation: presentation
        )
        defer { mask.setGeometry(bounds: CGRect(origin: .zero, size: size), fit: maskFit) }
        appliedPicture = Self.usablePicture(picture, in: size)
        let sameViewport = abs(appliedViewport.width - size.width) < 0.5
            && abs(appliedViewport.height - size.height) < 0.5
        if !force, sameViewport, self.presentation == presentation {
            if appliedViewport != size {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                container.frame = CGRect(origin: .zero, size: size)
                CATransaction.commit()
            }
            retarget(next)
            return false
        }
        appliedViewport = size
        self.presentation = presentation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        metrics = next
        allocator.apply(metrics)
        invalidateRasterWork()
        reclaimAll()
        return true
    }

    func retargetLayout(preferences: DanmakuRenderPreferences) {
        retarget(preferences.trackMetrics(
            width: Double(appliedViewport.width),
            height: Double(appliedViewport.height),
            presentation: presentation
        ))
    }

    private static func usablePicture(_ picture: CGRect?, in size: CGSize) -> CGRect {
        guard let picture, picture.width.isFinite, picture.height.isFinite,
              picture.minX.isFinite, picture.minY.isFinite,
              picture.width > 0, picture.height > 0
        else { return CGRect(origin: .zero, size: size) }
        return picture
    }

    private func retarget(_ next: DanmakuTrackLayout.Metrics) {
        guard next != metrics else { return }
        metrics = next
        allocator.retarget(next)
        updateRasterClock(clockMediaTime)
    }

    func setContainerOpacity(_ opacity: Double) {
        let unit = opacity.isFinite ? min(1, max(0, opacity)) : 1
        container.opacity = Float(unit)
    }

    func admit(_ items: [DanmakuElem], laneHeight _: CGFloat) {
        let viewport = container.bounds.size
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else {
            return
        }
        let preferences = DanmakuRenderPreferences.load()
        setContainerOpacity(preferences.opacity)
        let pictureHeight = appliedPicture.height
        let advancedGate = CGFloat(preferences.laneHeight(presentation: presentation))
        let fontScale = preferences.fontScale(for: presentation)
        let ordered = items.sorted { $0.progress < $1.progress }
        for item in ordered {
            if let existing = live[item.id], !item.isSelfSent || existing.isSelfSent {
                continue
            }
            guard preferences.admitsElement(item) else { continue }
            switch item.renderKind {
            case .unsupported:
                continue
            case .advanced:
                admitAdvanced(
                    item,
                    laneHeight: advancedGate,
                    fontScale: fontScale,
                    pictureHeight: pictureHeight
                )
            case .scroll, .top, .bottom, .reverse:
                admitLaned(item, fontScale: fontScale)
            }
        }
    }

    private func admitLaned(_ item: DanmakuElem, fontScale: Double) {
        let lifetime: TimeInterval = switch item.renderKind {
        case .scroll, .reverse: metrics.scrollLifetime
        case .top, .bottom: metrics.fixedLifetime
        case .advanced, .unsupported: 0
        }
        guard Self.animationIsLive(progress: item.progress, lifetime: lifetime, at: clockMediaTime) else {
            return
        }
        guard let admissionTicket = claimRaster(for: item) else { return }
        let key = DanmakuTextRasterizer.Key(
            text: item.content,
            fontSize: item.fontSize,
            colorRGB: item.color,
            hasStroke: true,
            scale: UIScreen.main.scale,
            fontScale: CGFloat(fontScale),
            presentation: presentation,
            selfSentFrame: item.isSelfSent
        )
        let itemID = item.id
        let progress = item.progress
        let kind = item.renderKind
        let selfSent = item.isSelfSent
        let ticket = generation
        let work = rasterWork
        let surfaceWidth = Double(container.bounds.width)
        rasterize(key, { width in
            work.accepts(generation: ticket, id: itemID, ticket: admissionTicket) { timing in
                let lifetime = (kind == .scroll || kind == .reverse)
                    ? timing.scrollLifetime : timing.fixedLifetime
                let entry = Self.entryTime(
                    progress: progress, kind: kind, selfSent: selfSent,
                    surfaceWidth: surfaceWidth, bulletWidth: Double(width),
                    scrollLifetime: lifetime
                )
                return Self.animationIsLive(progress: entry, lifetime: lifetime, at: timing.mediaTime)
            }
        }, { [weak self] image in
            Task { @MainActor in
                guard let self, self.generation == ticket,
                      self.pending[itemID]?.ticket == admissionTicket else { return }
                self.pending.removeValue(forKey: itemID)
                self.rasterWork.finish(id: itemID, ticket: admissionTicket)
                guard let image, self.canDisplay() else { return }
                self.place(
                    id: itemID,
                    progress: progress,
                    kind: kind,
                    image: image,
                    selfSent: selfSent
                )
            }
        })
    }

    private func admitAdvanced(
        _ item: DanmakuElem,
        laneHeight: CGFloat,
        fontScale: Double,
        pictureHeight: CGFloat
    ) {
        guard let script = DanmakuAdvancedScript.parse(item.content) else { return }
        guard !DanmakuRenderPreferences.load().blocks(script.text) else { return }
        let placed = DanmakuAdvancedPlacement.place(
            script,
            viewport: DanmakuAdvancedPlacement.Viewport(
                width: Double(appliedPicture.width), height: Double(appliedPicture.height)
            )
        )
        guard Self.animationIsLive(
            progress: item.progress, lifetime: placed.lifetimeSeconds, at: clockMediaTime
        ) else { return }
        guard let admissionTicket = claimRaster(for: item) else { return }
        let key = DanmakuTextRasterizer.Key(
            text: script.text,
            fontSize: item.fontSize,
            colorRGB: item.color,
            hasStroke: DanmakuAdvancedStroke.isEnabled(script.stroke),
            scale: UIScreen.main.scale,
            fontPostScriptName: DanmakuAdvancedFontMapping.postScriptName(for: script.fontName),
            fontScale: CGFloat(fontScale),
            pictureHeight: pictureHeight
        )
        let itemID = item.id
        let progress = item.progress
        let ticket = generation
        let work = rasterWork
        rasterize(key, { _ in
            work.accepts(generation: ticket, id: itemID, ticket: admissionTicket) { timing in
                Self.animationIsLive(
                    progress: progress, lifetime: placed.lifetimeSeconds, at: timing.mediaTime
                )
            }
        }, { [weak self] image in
            Task { @MainActor in
                guard let self, self.generation == ticket,
                      self.pending[itemID]?.ticket == admissionTicket else { return }
                self.pending.removeValue(forKey: itemID)
                self.rasterWork.finish(id: itemID, ticket: admissionTicket)
                guard let image, self.canDisplay() else { return }
                self.placeAdvanced(
                    item: item,
                    script: script,
                    image: image,
                    laneHeight: laneHeight
                )
            }
        })
    }

    func applyTiming(_ timing: DanmakuClockSync.LayerTiming, mediaTime: TimeInterval) {
        updateRasterClock(mediaTime)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if timing.speed > 0, container.speed == 0 {
            container.timeOffset = 0
            container.beginTime = 0
        }
        container.speed = Float(timing.speed)
        container.timeOffset = timing.timeOffset
        container.beginTime = timing.beginTime
    }

    func resync(mediaTime: TimeInterval, rate: Float, isPlaying: Bool) {
        let timing = DanmakuClockSync.timing(
            mediaTime: mediaTime,
            rate: Double(rate),
            isPlaying: isPlaying,
            hostTime: CACurrentMediaTime()
        )
        applyTiming(timing, mediaTime: mediaTime)
    }

    func seeked(to mediaTime: TimeInterval) {
        updateRasterClock(mediaTime)
        invalidateRasterWork()
        allocator.reset()
        reclaimAll()
        resync(mediaTime: mediaTime, rate: Float(container.speed), isPlaying: container.speed > 0)
    }

    func reclaimFinished(at mediaTime: TimeInterval) {
        updateRasterClock(mediaTime)
        guard !live.isEmpty else { return }
        var finished: [Int64] = []
        for (id, bullet) in live where bullet.endsAt <= mediaTime {
            finished.append(id)
        }
        for id in finished {
            guard let bullet = live.removeValue(forKey: id) else { continue }
            recycle(bullet.layer)
        }
    }

    private func claimRaster(for item: DanmakuElem) -> UInt64? {
        if let existing = pending[item.id], !item.isSelfSent || existing.isSelfSent {
            return nil
        }
        nextAdmissionTicket &+= 1
        let ticket = nextAdmissionTicket
        pending[item.id] = PendingBullet(ticket: ticket, isSelfSent: item.isSelfSent)
        rasterWork.claim(id: item.id, ticket: ticket)
        return ticket
    }

    private func updateRasterClock(_ mediaTime: TimeInterval) {
        clockMediaTime = mediaTime
        allocator.reclaimFinished(at: mediaTime)
        rasterWork.update(
            generation: generation, mediaTime: mediaTime,
            scrollLifetime: metrics.scrollLifetime, fixedLifetime: metrics.fixedLifetime
        )
    }

    private func invalidateRasterWork() {
        generation &+= 1
        pending.removeAll()
        rasterWork.update(
            generation: generation, mediaTime: clockMediaTime,
            scrollLifetime: metrics.scrollLifetime, fixedLifetime: metrics.fixedLifetime
        )
    }

    func teardown() {
        invalidateRasterWork()
        reclaimAll()
        allocator.reset()
        mask.clear()
    }

    func syncMask(_ segments: [Int: DanmakuMaskSegment]) {
        mask.sync(segments)
    }

    func clearMask() {
        mask.clear()
    }
}

extension DanmakuRenderController {
    private func place(
        id: Int64,
        progress: TimeInterval,
        kind: DanmakuRenderKind,
        image: DanmakuTextRasterizer.Image,
        selfSent: Bool
    ) {
        let lifetime: TimeInterval
        switch kind {
        case .scroll, .reverse:
            lifetime = metrics.scrollLifetime
        case .top, .bottom:
            lifetime = metrics.fixedLifetime
        case .advanced, .unsupported:
            return
        }
        let entry = Self.entryTime(
            progress: progress,
            kind: kind,
            selfSent: selfSent,
            surfaceWidth: Double(container.bounds.width),
            bulletWidth: Double(image.width),
            scrollLifetime: lifetime
        )
        let endsAt = entry + lifetime
        guard endsAt > clockMediaTime else { return }
        guard replaceOrdinaryLiveCopy(id: id, withSelfSent: selfSent),
              let layer = pool.popLast() else { return }
        let placement = allocator.place(
            DanmakuTrackLayout.Request(
                kind: kind,
                entry: entry,
                width: Double(image.width),
                height: Double(image.height),
                forced: selfSent
            )
        )
        guard case .lane(let lane) = placement,
              let band = metrics.band(kind: kind, lane: lane) else {
            pool.append(layer)
            return
        }
        let centerY = CGFloat((band.top + band.bottom) / 2)
        let x: CGFloat
        switch kind {
        case .top, .bottom:
            x = container.bounds.midX
        case .reverse:
            x = -image.width / 2
        case .scroll:
            x = container.bounds.width + image.width / 2
        case .advanced, .unsupported:
            x = container.bounds.midX
        }
        layer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        layer.contentsScale = image.scale
        layer.contents = image.contents
        layer.position = CGPoint(x: x, y: centerY)
        container.addSublayer(layer)
        live[id] = LiveBullet(layer: layer, endsAt: endsAt, isSelfSent: selfSent)
        attachMotion(layer, kind: kind, beginTime: entry, width: image.width, lifetime: lifetime)
    }

    nonisolated static func entryTime(
        progress: TimeInterval,
        kind: DanmakuRenderKind,
        selfSent: Bool,
        surfaceWidth: Double,
        bulletWidth: Double,
        scrollLifetime: TimeInterval
    ) -> TimeInterval {
        guard selfSent, kind == .scroll else { return progress }
        let width = max(0, bulletWidth)
        let speed = (max(1, surfaceWidth) + width) / max(0.001, scrollLifetime)
        return progress - width / speed
    }

    private func attachMotion(
        _ layer: CALayer,
        kind: DanmakuRenderKind,
        beginTime: TimeInterval,
        width: CGFloat,
        lifetime: TimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: "position")
        let y = layer.position.y
        switch kind {
        case .scroll, .reverse:
            let startX = container.bounds.width + width / 2
            let endX = -width / 2
            let from = kind == .reverse ? endX : startX
            let to = kind == .reverse ? startX : endX
            animation.fromValue = CGPoint(x: from, y: y)
            animation.toValue = CGPoint(x: to, y: y)
        case .top, .bottom:
            animation.fromValue = layer.position
            animation.toValue = layer.position
        case .advanced, .unsupported:
            return
        }
        animation.duration = lifetime
        animation.beginTime = beginTime
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "danmaku")
    }

    private func reclaimAll() {
        for bullet in live.values {
            recycle(bullet.layer)
        }
        live.removeAll()
    }

    private func placeAdvanced(
        item: DanmakuElem,
        script: DanmakuAdvancedScript,
        image: DanmakuTextRasterizer.Image,
        laneHeight: CGFloat
    ) {
        let id = item.id
        let progress = item.progress
        let selfSent = item.isSelfSent
        guard laneHeight.isFinite, laneHeight > 0 else { return }
        let placed = DanmakuAdvancedPlacement.place(
            script,
            viewport: DanmakuAdvancedPlacement.Viewport(
                width: Double(appliedPicture.width),
                height: Double(appliedPicture.height)
            )
        )
        let endsAt = progress + placed.lifetimeSeconds
        guard endsAt > clockMediaTime else { return }
        guard replaceOrdinaryLiveCopy(id: id, withSelfSent: selfSent),
              let layer = pool.popLast() else { return }
        let origin = appliedPicture.origin
        let start = DanmakuAdvancedMotion.center(placed.start, image: image).offset(by: origin)
        let end = DanmakuAdvancedMotion.center(placed.end, image: image).offset(by: origin)
        layer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        layer.contentsScale = image.scale
        layer.contents = image.contents
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = start
        layer.opacity = Float(placed.alphaFrom)
        layer.transform = DanmakuAdvancedMotion.transform(rotZ: placed.rotZ, rotY: placed.rotY)
        for animation in DanmakuAdvancedMotion.animations(
            progress: progress,
            placed: placed,
            start: start,
            end: end
        ) {
            layer.add(animation, forKey: animation.keyPath)
        }
        container.addSublayer(layer)
        live[id] = LiveBullet(layer: layer, endsAt: endsAt, isSelfSent: selfSent)
    }

    private func replaceOrdinaryLiveCopy(id: Int64, withSelfSent selfSent: Bool) -> Bool {
        guard let existing = live[id] else { return true }
        guard selfSent, !existing.isSelfSent else { return false }
        live.removeValue(forKey: id)
        recycle(existing.layer)
        return true
    }

    private func recycle(_ layer: CALayer) {
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
        layer.contents = nil
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        pool.append(layer)
    }
}

private enum DanmakuAdvancedMotion {
    static let perspectiveM34: CGFloat = CGFloat(-1) / CGFloat(500)

    static func center(
        _ point: DanmakuAdvancedPlacement.Point,
        image: DanmakuTextRasterizer.Image
    ) -> CGPoint {
        CGPoint(
            x: CGFloat(point.left) + image.width / 2,
            y: CGFloat(point.top) + image.height / 2
        )
    }

    static func transform(rotZ: Double, rotY: Double) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = perspectiveM34
        transform = CATransform3DRotate(transform, radians(rotZ), 0, 0, 1)
        transform = CATransform3DRotate(transform, radians(rotY), 0, 1, 0)
        return transform
    }

    static func animations(
        progress: TimeInterval,
        placed: DanmakuAdvancedPlacement,
        start: CGPoint,
        end: CGPoint
    ) -> [CABasicAnimation] {
        var animations: [CABasicAnimation] = []
        if placed.moveDurationSeconds > 0 {
            animations.append(animation(
                keyPath: "position",
                from: start,
                destination: end,
                duration: placed.moveDurationSeconds,
                beginTime: progress
            ))
        }
        if placed.lifetimeSeconds > 0 {
            animations.append(animation(
                keyPath: "opacity",
                from: NSNumber(value: Float(placed.alphaFrom)),
                destination: NSNumber(value: Float(placed.alphaTo)),
                duration: placed.lifetimeSeconds,
                beginTime: progress
            ))
        }
        return animations
    }

    private static func radians(_ degrees: Double) -> CGFloat {
        CGFloat(degrees * Double.pi / Double(180))
    }

    private static func animation(
        keyPath: String,
        from: Any,
        destination: Any,
        duration: TimeInterval,
        beginTime: TimeInterval
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = destination
        animation.duration = duration
        animation.beginTime = beginTime
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        return animation
    }
}

private extension CGPoint {
    func offset(by origin: CGPoint) -> CGPoint {
        CGPoint(x: x + origin.x, y: y + origin.y)
    }
}

private final class DanmakuRasterWorkState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending: [Int64: UInt64] = [:]
    struct Timing {
        let mediaTime: TimeInterval
        let scrollLifetime: TimeInterval
        let fixedLifetime: TimeInterval
    }
    private var timing = Timing(mediaTime: 0, scrollLifetime: 8, fixedLifetime: 4)

    func update(
        generation: UInt64, mediaTime: TimeInterval,
        scrollLifetime: TimeInterval, fixedLifetime: TimeInterval
    ) {
        lock.lock()
        if self.generation != generation { pending.removeAll() }
        self.generation = generation
        timing = Timing(
            mediaTime: mediaTime, scrollLifetime: scrollLifetime, fixedLifetime: fixedLifetime
        )
        lock.unlock()
    }

    func claim(id: Int64, ticket: UInt64) {
        lock.lock()
        pending[id] = ticket
        lock.unlock()
    }

    func finish(id: Int64, ticket: UInt64) {
        lock.lock()
        if pending[id] == ticket { pending.removeValue(forKey: id) }
        lock.unlock()
    }

    func accepts(generation: UInt64, id: Int64, ticket: UInt64, isLive: (Timing) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation && pending[id] == ticket && isLive(timing)
    }
}
