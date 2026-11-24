import Foundation

enum DanmakuTrackLayout {
    struct Metrics: Equatable, Sendable {
        let width: Double
        let laneCount: Int
        let scrollLifetime: TimeInterval
        let fixedLifetime: TimeInterval
        let laneStride: Double
        let regionHeight: Double
        let topInset: Double

        init(
            width: Double,
            laneCount: Int,
            scrollLifetime: TimeInterval = 9,
            fixedLifetime: TimeInterval = 4,
            laneStride: Double = 0,
            regionHeight: Double = 0,
            topInset: Double = 0
        ) {
            self.width = max(1, width)
            self.laneCount = max(0, laneCount)
            self.scrollLifetime = max(0.001, scrollLifetime)
            self.fixedLifetime = max(0.001, fixedLifetime)
            self.laneStride = laneStride.isFinite ? max(0, laneStride) : 0
            self.regionHeight = regionHeight.isFinite ? max(0, regionHeight) : 0
            self.topInset = topInset.isFinite ? max(0, topInset) : 0
        }

        func band(kind: DanmakuRenderKind, lane: Int) -> VerticalExtent? {
            guard laneStride > 0 else { return nil }
            switch kind {
            case .bottom:
                let region = regionHeight > 0
                    ? regionHeight
                    : (topInset + Double(laneCount) * laneStride)
                let lower = region - Double(lane) * laneStride
                return VerticalExtent(top: lower - laneStride, bottom: lower)
            case .scroll, .reverse, .top, .advanced, .unsupported:
                let top = topInset + Double(lane) * laneStride
                return VerticalExtent(top: top, bottom: top + laneStride)
            }
        }
    }

    struct VerticalExtent: Equatable, Sendable {
        let top: Double
        let bottom: Double

        func overlaps(_ other: VerticalExtent) -> Bool {
            let tolerance = 1e-6
            return top < other.bottom - tolerance && bottom > other.top + tolerance
        }
    }

    struct Request: Equatable, Sendable {
        let kind: DanmakuRenderKind
        let entry: TimeInterval
        let width: Double
        let height: Double
        let forced: Bool

        init(
            kind: DanmakuRenderKind,
            entry: TimeInterval,
            width: Double,
            height: Double = 0,
            forced: Bool = false
        ) {
            self.kind = kind
            self.entry = entry
            self.width = width
            self.height = height.isFinite ? max(0, height) : 0
            self.forced = forced
        }
    }

    enum Placement: Equatable, Sendable {
        case lane(Int)
        case dropped
    }

    enum ScrollDirection: Equatable, Sendable {
        case rightToLeft
        case leftToRight

        init(kind: DanmakuRenderKind) {
            self = kind == .reverse ? .leftToRight : .rightToLeft
        }
    }

    struct Allocator: Equatable, Sendable {
        private(set) var metrics: Metrics
        private var scrollLanes: [[Occupant]]
        private var topLanes: [[Occupant]]
        private var bottomLanes: [[Occupant]]
        private var scrollBounds: [LaneBounds]
        private var topBounds: [LaneBounds]
        private var bottomBounds: [LaneBounds]
        private var earliestScrollExit: TimeInterval = .infinity
        private var nextSerial: UInt64 = 0

        static func == (lhs: Allocator, rhs: Allocator) -> Bool {
            lhs.metrics == rhs.metrics
                && lhs.scrollLanes == rhs.scrollLanes
                && lhs.topLanes == rhs.topLanes
                && lhs.bottomLanes == rhs.bottomLanes
                && lhs.nextSerial == rhs.nextSerial
        }

        private struct LaneBounds: Equatable, Sendable {
            var minTop: Double = .infinity
            var maxBottom: Double = -.infinity
            var hasUnbounded = false

            mutating func include(_ extent: VerticalExtent?) {
                if let extent {
                    if extent.top < minTop { minTop = extent.top }
                    if extent.bottom > maxBottom { maxBottom = extent.bottom }
                } else {
                    hasUnbounded = true
                }
            }

            func mayOverlap(_ candidate: VerticalExtent) -> Bool {
                if hasUnbounded { return true }
                let tolerance = 1e-6
                return candidate.top < maxBottom - tolerance && candidate.bottom > minTop + tolerance
            }

            static func compute(for occupants: [Occupant]) -> LaneBounds {
                var bounds = LaneBounds()
                for occupant in occupants {
                    bounds.include(occupant.extent)
                }
                return bounds
            }
        }

        private struct Occupant: Equatable, Sendable {
            let serial: UInt64
            let direction: ScrollDirection
            let entry: TimeInterval
            let width: Double
            let lifetime: TimeInterval
            let extent: VerticalExtent?

            var exit: TimeInterval { entry + lifetime }
        }

        init(metrics: Metrics) {
            self.metrics = metrics
            scrollLanes = Array(repeating: [], count: metrics.laneCount)
            topLanes = Array(repeating: [], count: metrics.laneCount)
            bottomLanes = Array(repeating: [], count: metrics.laneCount)
            scrollBounds = Array(repeating: LaneBounds(), count: metrics.laneCount)
            topBounds = Array(repeating: LaneBounds(), count: metrics.laneCount)
            bottomBounds = Array(repeating: LaneBounds(), count: metrics.laneCount)
        }

        mutating func reset() {
            scrollLanes = Array(repeating: [], count: metrics.laneCount)
            topLanes = Array(repeating: [], count: metrics.laneCount)
            bottomLanes = Array(repeating: [], count: metrics.laneCount)
            scrollBounds = Array(repeating: LaneBounds(), count: metrics.laneCount)
            topBounds = Array(repeating: LaneBounds(), count: metrics.laneCount)
            bottomBounds = Array(repeating: LaneBounds(), count: metrics.laneCount)
            earliestScrollExit = .infinity
        }

        mutating func apply(_ newMetrics: Metrics) {
            metrics = newMetrics
            reset()
        }

        mutating func retarget(_ newMetrics: Metrics) {
            guard newMetrics != metrics else { return }
            metrics = newMetrics
            scrollLanes = refile(scrollLanes, kind: .scroll)
            topLanes = refile(topLanes, kind: .top)
            bottomLanes = refile(bottomLanes, kind: .bottom)
            scrollBounds = scrollLanes.map(LaneBounds.compute(for:))
            topBounds = topLanes.map(LaneBounds.compute(for:))
            bottomBounds = bottomLanes.map(LaneBounds.compute(for:))
            recomputeEarliestScrollExit()
        }

        private func refile(_ lanes: [[Occupant]], kind: DanmakuRenderKind) -> [[Occupant]] {
            var seen = Set<UInt64>()
            var everyone: [Occupant] = []
            for lane in lanes {
                for occupant in lane where seen.insert(occupant.serial).inserted {
                    everyone.append(occupant)
                }
            }
            var out = Array(repeating: [Occupant](), count: metrics.laneCount)
            for index in out.indices {
                guard let band = metrics.band(kind: kind, lane: index) else {
                    if index < lanes.count { out[index] = lanes[index] }
                    continue
                }
                out[index] = everyone.filter { occupant in
                    occupant.extent.map { $0.overlaps(band) } ?? true
                }
            }
            return out
        }

        mutating func place(_ request: Request) -> Placement {
            guard metrics.laneCount > 0 else { return .dropped }
            switch request.kind {
            case .scroll, .reverse:
                return placeScroll(request)
            case .top:
                return placeFixed(request, band: .top)
            case .bottom:
                return placeFixed(request, band: .bottom)
            case .advanced, .unsupported:
                return .dropped
            }
        }

        private func candidateExtent(for request: Request, lane: Int) -> VerticalExtent? {
            guard var extent = metrics.band(kind: request.kind, lane: lane) else { return nil }
            if request.height > extent.bottom - extent.top {
                let middle = (extent.top + extent.bottom) / 2
                extent = VerticalExtent(
                    top: middle - request.height / 2,
                    bottom: middle + request.height / 2
                )
            }
            return extent
        }

        private mutating func occupant(for request: Request, lane: Int, lifetime: TimeInterval) -> Occupant {
            nextSerial &+= 1
            return Occupant(
                serial: nextSerial,
                direction: ScrollDirection(kind: request.kind),
                entry: request.entry,
                width: request.width,
                lifetime: lifetime,
                extent: candidateExtent(for: request, lane: lane)
            )
        }

        mutating func reclaimFinished(at mediaTime: TimeInterval) {
            guard mediaTime.isFinite, mediaTime >= earliestScrollExit else { return }
            var nextEarliest = TimeInterval.infinity
            for lane in scrollLanes.indices {
                guard !scrollLanes[lane].isEmpty else { continue }
                let beforeCount = scrollLanes[lane].count
                scrollLanes[lane].removeAll { $0.exit <= mediaTime }
                if scrollLanes[lane].count != beforeCount {
                    scrollBounds[lane] = LaneBounds.compute(for: scrollLanes[lane])
                }
                for occupant in scrollLanes[lane] where occupant.exit < nextEarliest {
                    nextEarliest = occupant.exit
                }
            }
            earliestScrollExit = nextEarliest
        }

        private mutating func recomputeEarliestScrollExit() {
            var nextEarliest = TimeInterval.infinity
            for lane in scrollLanes {
                for occupant in lane where occupant.exit < nextEarliest {
                    nextEarliest = occupant.exit
                }
            }
            earliestScrollExit = nextEarliest
        }

        private func scrollDelay(
            requestEntry: TimeInterval,
            requestWidth: Double,
            requestDirection: ScrollDirection,
            requestLifetime: TimeInterval,
            behind occupant: Occupant
        ) -> TimeInterval {
            let earlierIsOccupant = occupant.entry <= requestEntry
            let earlierEntry = earlierIsOccupant ? occupant.entry : requestEntry
            let earlierLifetime = earlierIsOccupant ? occupant.lifetime : requestLifetime
            let laterEntry = earlierIsOccupant ? requestEntry : occupant.entry
            if laterEntry >= earlierEntry + earlierLifetime { return 0 }
            let required: TimeInterval
            if occupant.direction == requestDirection {
                required = DanmakuTrackLayout.requiredGap(
                    leadingWidth: earlierIsOccupant ? occupant.width : requestWidth,
                    leadingLifetime: earlierLifetime,
                    trailingWidth: earlierIsOccupant ? requestWidth : occupant.width,
                    trailingLifetime: earlierIsOccupant ? requestLifetime : occupant.lifetime,
                    surfaceWidth: metrics.width
                )
            } else {
                required = earlierLifetime
            }
            let gap = laterEntry - earlierEntry
            guard gap > 0 else { return max(required, .ulpOfOne) }
            return max(0, required - gap)
        }

        private func isOverlapping(_ candidate: VerticalExtent?, lane: Int, occupant: Occupant, otherLane: Int) -> Bool {
            if let candidate, let occExtent = occupant.extent {
                return candidate.overlaps(occExtent)
            }
            return otherLane == lane
        }

        private mutating func placeScroll(_ request: Request) -> Placement {
            let requestDirection = ScrollDirection(kind: request.kind)
            let requestLifetime = metrics.scrollLifetime
            let requestEntry = request.entry
            let requestWidth = request.width
            let forced = request.forced
            var soonest: (lane: Int, delay: TimeInterval)?
            for lane in scrollLanes.indices {
                let candidate = candidateExtent(for: request, lane: lane)
                var delay: TimeInterval = 0
                var blocked = false

                // Check own lane first (most common collision site).
                for occupant in scrollLanes[lane]
                    where isOverlapping(candidate, lane: lane, occupant: occupant, otherLane: lane) {
                    let d = scrollDelay(
                        requestEntry: requestEntry,
                        requestWidth: requestWidth,
                        requestDirection: requestDirection,
                        requestLifetime: requestLifetime,
                        behind: occupant
                    )
                    if d > delay { delay = d }
                    if !forced, delay > 0 {
                        blocked = true
                        break
                    }
                }

                if !blocked, let candidate {
                    for otherLane in scrollLanes.indices where otherLane != lane {
                        guard !scrollLanes[otherLane].isEmpty,
                              scrollBounds[otherLane].mayOverlap(candidate) else { continue }
                        for occupant in scrollLanes[otherLane] {
                            guard let occExtent = occupant.extent, candidate.overlaps(occExtent) else { continue }
                            let d = scrollDelay(
                                requestEntry: requestEntry,
                                requestWidth: requestWidth,
                                requestDirection: requestDirection,
                                requestLifetime: requestLifetime,
                                behind: occupant
                            )
                            if d > delay { delay = d }
                            if !forced, delay > 0 {
                                blocked = true
                                break
                            }
                        }
                        if blocked { break }
                    }
                }

                if delay == 0 {
                    let entry = occupant(for: request, lane: lane, lifetime: requestLifetime)
                    scrollLanes[lane].append(entry)
                    scrollBounds[lane].include(entry.extent)
                    if entry.exit < earliestScrollExit { earliestScrollExit = entry.exit }
                    return .lane(lane)
                }
                if forced, soonest.map({ delay < $0.delay }) ?? true {
                    soonest = (lane, delay)
                }
            }
            guard forced, let pick = soonest else { return .dropped }
            let entry = occupant(for: request, lane: pick.lane, lifetime: requestLifetime)
            scrollLanes[pick.lane].append(entry)
            scrollBounds[pick.lane].include(entry.extent)
            if entry.exit < earliestScrollExit { earliestScrollExit = entry.exit }
            return .lane(pick.lane)
        }

        private enum FixedBand { case top, bottom }

        private mutating func placeFixed(
            _ request: Request,
            band: FixedBand
        ) -> Placement {
            let lanes = band == .top ? topLanes : bottomLanes
            let bounds = band == .top ? topBounds : bottomBounds
            let forced = request.forced
            let requestEntry = request.entry
            var soonest: (lane: Int, busyUntil: TimeInterval)?
            for lane in lanes.indices {
                let candidate = candidateExtent(for: request, lane: lane)
                var busyUntil = -TimeInterval.infinity
                var blocked = false

                for occupant in lanes[lane]
                    where isOverlapping(candidate, lane: lane, occupant: occupant, otherLane: lane) {
                    if occupant.exit > busyUntil { busyUntil = occupant.exit }
                    if !forced, requestEntry < busyUntil {
                        blocked = true
                        break
                    }
                }

                if !blocked, let candidate {
                    for otherLane in lanes.indices where otherLane != lane {
                        guard !lanes[otherLane].isEmpty,
                              bounds[otherLane].mayOverlap(candidate) else { continue }
                        for occupant in lanes[otherLane] {
                            guard let occExtent = occupant.extent, candidate.overlaps(occExtent) else { continue }
                            if occupant.exit > busyUntil { busyUntil = occupant.exit }
                            if !forced, requestEntry < busyUntil {
                                blocked = true
                                break
                            }
                        }
                        if blocked { break }
                    }
                }

                if requestEntry >= busyUntil {
                    let placed = occupant(for: request, lane: lane, lifetime: metrics.fixedLifetime)
                    store([placed], lane: lane, band: band)
                    return .lane(lane)
                }
                if forced, soonest.map({ busyUntil < $0.busyUntil }) ?? true {
                    soonest = (lane, busyUntil)
                }
            }
            guard forced, let pick = soonest else { return .dropped }
            let placed = occupant(for: request, lane: pick.lane, lifetime: metrics.fixedLifetime)
            let kept = lanes[pick.lane].filter { requestEntry < $0.exit }
            store(kept + [placed], lane: pick.lane, band: band)
            return .lane(pick.lane)
        }

        private mutating func store(_ occupants: [Occupant], lane: Int, band: FixedBand) {
            let computed = LaneBounds.compute(for: occupants)
            switch band {
            case .top:
                topLanes[lane] = occupants
                topBounds[lane] = computed
            case .bottom:
                bottomLanes[lane] = occupants
                bottomBounds[lane] = computed
            }
        }
    }

    static let minimumHorizontalGap: Double = 28

    static func requiredGap(
        leadingWidth: Double,
        trailingWidth: Double,
        metrics: Metrics
    ) -> TimeInterval {
        requiredGap(
            leadingWidth: leadingWidth,
            leadingLifetime: metrics.scrollLifetime,
            trailingWidth: trailingWidth,
            trailingLifetime: metrics.scrollLifetime,
            surfaceWidth: metrics.width
        )
    }

    static func requiredGap(
        leadingWidth: Double,
        leadingLifetime: TimeInterval,
        trailingWidth: Double,
        trailingLifetime: TimeInterval,
        surfaceWidth: Double
    ) -> TimeInterval {
        let width = max(1, surfaceWidth)
        let leadingLife = max(0.001, leadingLifetime)
        let trailingLife = max(0.001, trailingLifetime)
        let leadingSpeed = (width + max(0, leadingWidth)) / leadingLife
        let trailingSpeed = (width + max(0, trailingWidth)) / trailingLife
        let spacing = min(minimumHorizontalGap, width * 0.2)

        let tailClears = (max(0, leadingWidth) + spacing) / leadingSpeed
        let noOvertake = leadingLife - max(1, width - spacing) / trailingSpeed
        return max(tailClears, noOvertake)
    }

    static func laneCount(
        surfaceHeight: Double,
        laneHeight: Double,
        areaFraction: Double
    ) -> Int {
        guard surfaceHeight > 0, laneHeight > 0 else { return 0 }
        let fraction = min(max(areaFraction, 0), 1)
        return max(0, Int((surfaceHeight * fraction / laneHeight).rounded(.down)))
    }
}
