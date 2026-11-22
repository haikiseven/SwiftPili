import QuartzCore
import UIKit

/// Pushed from the player clock. Not observed by SwiftUI.
@MainActor
protocol DanmakuTimelineSink: AnyObject {
    func applyTiming(_ timing: DanmakuClockSync.LayerTiming, mediaTime: TimeInterval)
    func resync(mediaTime: TimeInterval, rate: Float, isPlaying: Bool)
    func seeked(to mediaTime: TimeInterval)
    func admit(_ items: [DanmakuElem], laneHeight: CGFloat)
    /// Finished bullets stay on screen (`isRemovedOnCompletion = false`) until
    /// this returns their layers to the pool. Called even when nothing new is due.
    func reclaimFinished(at mediaTime: TimeInterval)
    func teardown()
    /// The person-mask segments the player currently holds (Phase C). The
    /// whole set each time; the renderer diffs it.
    func syncMask(_ segments: [Int: DanmakuMaskSegment])
    func clearMask()
}

/// Layer pool and clock for scroll / top / bottom and mode-7 bullets.
///
/// Mode 7 is placed by `DanmakuAdvancedPlacement`, not by the lane allocator.
/// `.unsupported` (mode 8, mode 9, anything unknown) is still dropped. The
/// container's local time is media time, so each bullet's animation `beginTime`
/// is `DanmakuElem.progress` with no conversion. No `CADisplayLink` — the
/// container clock already carries rate, pause, and seek.
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

    /// Cheap admission guard used before dispatching CoreText work. The
    /// post-raster placement checks remain authoritative because the clock can
    /// advance while a raster is being produced.
    nonisolated static func animationIsLive(
        progress: TimeInterval, lifetime: TimeInterval, at mediaTime: TimeInterval
    ) -> Bool {
        guard progress.isFinite, lifetime.isFinite, mediaTime.isFinite, lifetime >= 0 else {
            return false
        }
        return progress + lifetime > mediaTime
    }

    let container = CALayer()
    /// Person-mask anti-occlusion on `container` (Phase C).
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
    /// Media time of the last clock or seek. A raster that lands after its
    /// bullet has already ended must not take a layer out of the pool.
    private var clockMediaTime: TimeInterval = 0
    private var allocator: DanmakuTrackLayout.Allocator
    typealias Rasterize = (
        DanmakuTextRasterizer.Key,
        @escaping @Sendable (CGFloat) -> Bool,
        @escaping @Sendable (DanmakuTextRasterizer.Image?) -> Void
    ) -> Void

    private let rasterize: Rasterize
    /// Read at completion time: an image produced while visible must not
    /// create a layer after UIKit deactivates the app. Tests can control this
    /// environment edge without depending on simulator activation timing.
    private let canDisplay: @MainActor () -> Bool
    // The raster queue may test cancellation without hopping to MainActor.
    private let rasterWork = DanmakuRasterWorkState()
    private var metrics: DanmakuTrackLayout.Metrics
    /// Last size `resize` actually applied. Compared instead of `container.bounds`
    /// because the host writes that frame before asking, which would hide a real
    /// bounds change and skip the reclaim.
    private var appliedViewport: CGSize
    /// Where the video sits in the container. The container is the whole
    /// player, so ordinary bullets fly over letterbox bars; mode 7 is authored
    /// against the video frame and is placed and sized in this rectangle.
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

    /// One on-screen bullet and the media time at which its motion ends.
    private struct LiveBullet {
        let layer: CALayer
        let endsAt: TimeInterval
        let isSelfSent: Bool
    }

    /// Presentation the last `resize` applied. Ordinary bullets are sized by
    /// it (B1), so a change is a wipe like a viewport change.
    private(set) var presentation: DanmakuPresentation = .inline

    /// `true` when the live set was wiped: the viewport or the presentation
    /// changed, or `force`. A change in the preferences alone is NOT a wipe —
    /// it retargets like `retargetLayout`, so a layout pass that happens to
    /// read new defaults before their notification arrives cannot clear the
    /// screen for a setting change (B3). Fixed lifetime stays 4.
    ///
    /// `picture` is the video's rectangle in the container (nil: all of it).
    /// A picture change alone is not a wipe: it only moves mode 7 admitted
    /// after it, the same rule as a preference change.
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

    /// Lane geometry and scroll lifetime for bullets admitted after this call
    /// (B3, option a).
    ///
    /// Layers already on screen keep their animations, their size and their
    /// lane: the raster generation stays put, nothing is reclaimed, and the
    /// allocator re-files their occupancy under the new lanes their drawn
    /// span overlaps (`Allocator.retarget`), so a bullet placed afterwards
    /// cannot land on one of them. A real viewport change still goes through
    /// `resize`, which wipes.
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
        // A host that has not been laid out reports a zero (or non-finite)
        // rect. Rasterizing now would substitute the 720 stage for a
        // non-positive picture height and park those glyphs in that rect;
        // the next real resize wipes them. Returning leaves the items
        // unclaimed. Layout already refills through the wipe flag and
        // `noteDanmakuLayoutDefaultsChange` — no second timer.
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else {
            return
        }
        let preferences = DanmakuRenderPreferences.load()
        setContainerOpacity(preferences.opacity)
        // Ordinary bullets are sized by presentation, not by any height
        // (B1). Mode 7 reads the picture's — its glyph and its stage both
        // scale with the video — and keeps the preference stride as its gate.
        let pictureHeight = appliedPicture.height
        let advancedGate = CGFloat(preferences.laneHeight(presentation: presentation))
        // Inline and fullscreen each have their own scale; mode 7 is drawn in
        // the same presentation, so it takes the same one.
        let fontScale = preferences.fontScale(for: presentation)
        // Raster completion follows dispatch order. Keep each batch in timeline
        // order for deterministic lane priority; the allocator also checks safe
        // late arrivals from separate batches against every retained occupant.
        // Equal progress stays in feed order (`sorted` is stable).
        let ordered = items.sorted { $0.progress < $1.progress }
        for item in ordered {
            if let existing = live[item.id], !item.isSelfSent || existing.isSelfSent {
                continue
            }
            // Filtered kinds never rasterize and never take a lane or a
            // mode-7 layer. The viewer's own bullet is exempt (B4).
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
        // Self-sent scroll starts earlier by its measured tail-clear time.
        // progress + lifetime is a safe upper bound here; the raster queue
        // checks the exact entry with the measured width before drawing.
        guard Self.animationIsLive(progress: item.progress, lifetime: lifetime, at: clockMediaTime) else {
            return
        }
        guard let admissionTicket = claimRaster(for: item) else { return }
        let key = DanmakuTextRasterizer.Key(
            text: item.content,
            fontSize: item.fontSize,
            colorRGB: item.color,
            // Ordinary bullets always take the 1pt black rim. Mode 7 still
            // decides from its own stroke flag. A fill with only a blurred
            // drop shadow is what made phone text look unstroked.
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

    /// A nil parse drops the whole bullet. No lane, and no scroll substitute.
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
        // Reset `beginTime` to 0 before transitioning from paused (`speed == 0`)
        // to active (`speed > 0`) so CoreAnimation commits a clean timeline step.
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

    /// A local echo replaces a waiting ordinary/special copy. All other
    /// duplicate identities stay with their first submitted raster job.
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
        // Lifetime and lane geometry are the metrics in force NOW, the same
        // ones the allocator decides with. The bullet keeps them for its whole
        // flight; a later preference change applies only to later bullets.
        let lifetime: TimeInterval
        switch kind {
        case .scroll, .reverse:
            lifetime = metrics.scrollLifetime
        case .top, .bottom:
            lifetime = metrics.fixedLifetime
        case .advanced, .unsupported:
            // Advanced bullets never ask the lane allocator. `admit` routes
            // them to `placeAdvanced`; landing here would be a leak if a layer
            // had already been taken. It has not.
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
        // Bottom sits at the bottom of the display-area region, not the
        // picture. Top still starts at the top. The container clips overflow.
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
            // Unreachable: those kinds returned before a layer was taken.
            // Assigning keeps a later edit from returning a pooled layer.
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

    /// The media time a laned bullet's motion begins at.
    ///
    /// Everyone's: its `progress`, so it enters at the right edge then. The
    /// viewer's own scroll bullet begins one "tail-clear" earlier —
    /// `bulletWidth / speed`, with `speed = (surface + bullet) / lifetime` —
    /// so at `progress` it already sits wholly inside the right edge. That is
    /// what makes a bullet sent while paused visible at once instead of parked
    /// off screen until play resumes (B4); a refill of the same bullet uses
    /// the same rule, so it lands where it was first shown. Fixed bullets are
    /// visible at `progress` already.
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

    /// Mode-7 x/y is the text's top-left. The layer anchor stays at the center,
    /// so half the raster is added once here and again on the animation's end.
    private func placeAdvanced(
        item: DanmakuElem,
        script: DanmakuAdvancedScript,
        image: DanmakuTextRasterizer.Image,
        laneHeight: CGFloat
    ) {
        let id = item.id
        let progress = item.progress
        let selfSent = item.isSelfSent
        // Mode 7 is not stacked in a lane. The same stride still gates it, so a
        // font-scale change cannot leave this path on a different constant.
        guard laneHeight.isFinite, laneHeight > 0 else { return }
        let placed = DanmakuAdvancedPlacement.place(
            script,
            viewport: DanmakuAdvancedPlacement.Viewport(
                width: Double(appliedPicture.width),
                height: Double(appliedPicture.height)
            )
        )
        let endsAt = progress + placed.lifetimeSeconds
        // A raster that lands after the bullet has ended must not take a layer.
        guard endsAt > clockMediaTime else { return }
        guard replaceOrdinaryLiveCopy(id: id, withSelfSent: selfSent),
              let layer = pool.popLast() else { return }
        // The stage is the picture; the container is the player around it.
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

    /// Echo wins even if the ordinary copy already landed. Its old layer is
    /// recycled; allocator occupancy may finish naturally, while the own
    /// bullet's existing forced-lane rule guarantees admission.
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
        // Mode 7 writes a 3D transform and an opacity. A scroll bullet that
        // reuses the layer never sets either, so they have to come off here.
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        pool.append(layer)
    }
}

/// CoreAnimation values for one mode-7 bullet.
///
/// Lives outside the controller so the pool class does not also own the
/// transform math. Index 14 (`path`) is not an animation.
private enum DanmakuAdvancedMotion {
    /// `m34` is the perspective divisor: after `rotateY` pushes part of the
    /// glyph in z, x and y are scaled by `1 / (1 + z * m34)`. Zero leaves that
    /// rotation orthographic — the text only gets narrower. A small negative
    /// value puts the camera in front of the layer. 1/500pt is enough to read
    /// as a turn and not enough to fling the glyph out of the viewport.
    static let perspectiveM34: CGFloat = CGFloat(-1) / CGFloat(500)

    /// Mode-7 x/y is the text's top-left. `CALayer.position` is the anchor
    /// (the center), so half the raster size is added to both ends.
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
        // `CATransform3DRotate` pre-multiplies (`t' = rotation * t`), so the
        // last call is the first one applied to a point. Z is the in-plane
        // turn; Y then tips that result into depth. Degrees become radians
        // here, not in the placement value.
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
        // A zero move holds the model position, which is `start`. An animation
        // of duration 0 completes immediately and is not a hold.
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

/// Small thread-safe cancellation/clock snapshot; this is not a second player
/// clock. The controller updates it only on existing media/transport edges.
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
