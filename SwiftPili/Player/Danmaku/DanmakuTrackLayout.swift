import Foundation

/// Where a bullet goes, and whether it goes at all.
///
/// Pure geometry and arithmetic over a lane table — no view, no layer, no clock.
/// That is deliberate: lane assignment is where a danmaku renderer's visible
/// defects live (bullets overlapping, bullets vanishing, a screen that fills up
/// and never drains), and all of them are decidable without drawing anything.
/// It is also the half of phase 2 that can be executed on a machine with no iOS
/// SDK, so it carries as much of the logic as it can.
///
/// **Scroll collision, derived rather than tuned.** A scroll bullet's left edge
/// travels from the container's right edge to just past its left edge — a
/// distance of `width + bulletWidth` — over `scrollLifetime`, so a WIDER bullet
/// moves FASTER. Two bullets sharing a lane must satisfy both of:
///
///   1. the earlier one's tail is fully on screen before the later one enters,
///   2. the later one never catches it before it leaves.
///
/// With A the earlier and B the later, `Δ` their entry gap, and `v = (W+w)/L`:
///
///     ① Δ ≥ wA / vA
///     ② Δ ≥ L − W / vB
///
/// For equal widths those two coincide exactly, which is the self-check on the
/// derivation; for `wB > wA` the second is stricter, which is the overtaking
/// case the first one cannot see. A tuned "minimum gap" constant would get the
/// equal-width case right and the overtaking case wrong, silently.
enum DanmakuTrackLayout {
    /// Everything the layout needs about the surface and the settings.
    ///
    /// Geometry is `Double` rather than `CGFloat` because nothing here is a view
    /// — the caller converts once at the boundary, and this stays compilable
    /// where `CoreGraphics` is not.
    struct Metrics: Equatable, Sendable {
        /// Container width in points.
        let width: Double
        /// How many lanes the display-area setting allows.
        let laneCount: Int
        /// How long a scroll bullet takes to cross, at 1× rate.
        let scrollLifetime: TimeInterval
        /// How long a top/bottom bullet stays put.
        let fixedLifetime: TimeInterval
        /// Points from one lane's top to the next. Zero means the caller did
        /// not say, and occupancy is then carried across a geometry change by
        /// lane index instead of by vertical extent.
        let laneStride: Double
        /// Height of the display-area region, from the top. Bottom bullets
        /// stack upward from its lower edge. Zero means `laneCount × laneStride`.
        let regionHeight: Double
        /// Safe top margin in points so lane 0 does not hug the top edge.
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

        /// The vertical span lane `lane` of `kind` covers, in container
        /// points from the top. Nil when the stride is unknown.
        ///
        /// Scroll and top lanes count down from the top edge. Bottom lanes count
        /// up from the region's lower edge. The renderer draws a bullet centered
        /// in this band, so this is the one place the two agree on where a lane is.
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

    /// A closed vertical span in container points, top < bottom.
    struct VerticalExtent: Equatable, Sendable {
        let top: Double
        let bottom: Double

        /// Strict: two spans that only touch at an edge do not overlap.
        func overlaps(_ other: VerticalExtent) -> Bool {
            let tolerance = 1e-6
            return top < other.bottom - tolerance && bottom > other.top + tolerance
        }
    }

    /// One bullet asking for a lane.
    struct Request: Equatable, Sendable {
        let kind: DanmakuRenderKind
        /// Absolute media seconds at which it should appear.
        let entry: TimeInterval
        /// Rendered width in points.
        let width: Double
        /// Rendered height in points. A raster taller than the lane overhangs
        /// it, and the occupancy records the overhang so a later geometry
        /// change cannot put a bullet under it. Zero means "fits the lane".
        let height: Double
        /// The viewer's own bullet. It is never dropped for a full screen; see
        /// `Allocator.place` for which lane it takes then.
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

    /// Lane numbering runs from the TOP for scroll and top bullets and from the
    /// BOTTOM for bottom bullets, which is what the two `.bottom` cases mean
    /// when they say lane 0.
    enum Placement: Equatable, Sendable {
        /// Lane index, 0-based from the edge that kind grows out of.
        case lane(Int)
        /// Every lane this kind can use is occupied. The bullet is dropped —
        /// which is what a real player does, and is better than letting the
        /// screen fill without bound.
        case dropped
    }

    enum ScrollDirection: Equatable, Sendable {
        case rightToLeft
        case leftToRight

        init(kind: DanmakuRenderKind) {
            self = kind == .reverse ? .leftToRight : .rightToLeft
        }
    }

    /// Lane occupancy, advanced one bullet at a time.
    ///
    /// A struct with `mutating` methods rather than a class: the renderer owns
    /// exactly one, a copy is a cheap snapshot for a test, and nothing else can
    /// hold a reference to it and mutate it behind the renderer's back.
    ///
    /// **Occupants remember their own geometry.** Each records the lifetime it
    /// was animated with and the vertical span it was drawn in. A preference
    /// change (`retarget`) changes the lane stride, the region, the lane count
    /// and the scroll lifetime for bullets placed AFTER it, while the bullets
    /// already flying keep theirs; the allocator re-files every occupant under
    /// each new lane its span overlaps, so a new bullet is checked against
    /// everything it could touch. Only a resize (`apply`) or a seek (`reset`)
    /// forgets occupants, and both of those also clear the screen.
    struct Allocator: Equatable, Sendable {
        private(set) var metrics: Metrics
        /// Every still-relevant scroll occupant keeps its own geometry. Late
        /// data can be earlier than the newest occupant, so neither arrival
        /// order nor the newest short lifetime can stand in for this book.
        /// The renderer's actual media clock retires expired occupancy.
        private var scrollLanes: [[Occupant]]
        private var topLanes: [[Occupant]]
        private var bottomLanes: [[Occupant]]
        private var nextSerial: UInt64 = 0

        private struct Occupant: Equatable, Sendable {
            /// Identity across lanes. A bullet overlapping two new lanes is filed
            /// under both, and a second geometry change must not count it twice.
            let serial: UInt64
            let direction: ScrollDirection
            let entry: TimeInterval
            let width: Double
            /// Scroll: crossing time. Fixed: time on screen. Its own, not the
            /// current metrics'.
            let lifetime: TimeInterval
            /// Nil when the stride was unknown at placement. Such an occupant is
            /// kept by lane index, or — when the new geometry is known — under
            /// every lane, which is the conservative answer.
            let extent: VerticalExtent?

            var exit: TimeInterval { entry + lifetime }
        }

        init(metrics: Metrics) {
            self.metrics = metrics
            scrollLanes = Array(repeating: [], count: metrics.laneCount)
            topLanes = Array(repeating: [], count: metrics.laneCount)
            bottomLanes = Array(repeating: [], count: metrics.laneCount)
        }

        /// Drop everything. Called on a seek and on a content change: lanes
        /// describe what is currently on screen, and after either of those
        /// nothing is.
        mutating func reset() {
            scrollLanes = Array(repeating: [], count: metrics.laneCount)
            topLanes = Array(repeating: [], count: metrics.laneCount)
            bottomLanes = Array(repeating: [], count: metrics.laneCount)
        }

        /// A resize changes how many lanes exist and invalidates the geometry
        /// every occupant was placed with, so it resets as well. The renderer
        /// clears the screen on the same edge.
        mutating func apply(_ newMetrics: Metrics) {
            metrics = newMetrics
            reset()
        }

        /// A preference change: new lane stride, region, lane count or scroll
        /// lifetime for bullets placed from now on. Nothing on screen moves,
        /// so nothing is forgotten — every occupant is re-filed under each new
        /// lane whose band its recorded span overlaps.
        ///
        /// A different width is not a preference change: every scroll speed
        /// derives from it, so that is a resize and goes through `apply`.
        mutating func retarget(_ newMetrics: Metrics) {
            guard newMetrics != metrics else { return }
            guard newMetrics.width == metrics.width else {
                apply(newMetrics)
                return
            }
            metrics = newMetrics
            scrollLanes = refile(scrollLanes, kind: .scroll)
            topLanes = refile(topLanes, kind: .top)
            bottomLanes = refile(bottomLanes, kind: .bottom)
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
                    // No geometry to compare: keep the old book for this index.
                    if index < lanes.count { out[index] = lanes[index] }
                    continue
                }
                out[index] = everyone.filter { occupant in
                    occupant.extent.map { $0.overlaps(band) } ?? true
                }
            }
            return out
        }

        /// Assign a lane, or refuse.
        ///
        /// Lanes are searched from index 0 up, so bullets settle toward the edge
        /// they grow from and the middle of the screen stays clearer — the same
        /// behaviour the reference player has.
        ///
        /// A `forced` request (the viewer's own bullet) takes the first lane
        /// that admits it like any other. When none does, it is NOT dropped: it
        /// takes the lane that would have admitted it soonest — the smallest
        /// extra delay before every occupant there is cleared — ties going to
        /// the lower index. It may overlap that lane's tail; that is the price
        /// of the bullet the user just typed never vanishing on a busy video.
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
                // Advanced bullets carry their own coordinates and do not take a
                // lane; unsupported ones are filtered before they reach here.
                // Neither is a lane failure, and neither may consume one.
                return .dropped
            }
        }

        private mutating func occupant(for request: Request, lane: Int, lifetime: TimeInterval) -> Occupant {
            nextSerial &+= 1
            var extent = metrics.band(kind: request.kind, lane: lane)
            if let band = extent, request.height > band.bottom - band.top {
                let middle = (band.top + band.bottom) / 2
                extent = VerticalExtent(
                    top: middle - request.height / 2,
                    bottom: middle + request.height / 2
                )
            }
            return Occupant(
                serial: nextSerial,
                direction: ScrollDirection(kind: request.kind),
                entry: request.entry,
                width: request.width,
                lifetime: lifetime,
                extent: extent
            )
        }

        /// Retire only at the renderer's actual expiry edge. A late request's
        /// authored entry is not a clock and cannot retire newer live records.
        mutating func reclaimFinished(at mediaTime: TimeInterval) {
            guard mediaTime.isFinite else { return }
            for lane in scrollLanes.indices {
                scrollLanes[lane].removeAll { $0.exit <= mediaTime }
            }
        }

        /// Collision admission uses chronological roles, independently of the
        /// order in which normal segments and special packages were delivered.
        private func scrollDelay(_ request: Request, behind occupant: Occupant) -> TimeInterval {
            let requestDirection = ScrollDirection(kind: request.kind)
            let requestLifetime = metrics.scrollLifetime
            let earlierIsOccupant = occupant.entry <= request.entry
            let earlierEntry = earlierIsOccupant ? occupant.entry : request.entry
            let earlierLifetime = earlierIsOccupant ? occupant.lifetime : requestLifetime
            let laterEntry = earlierIsOccupant ? request.entry : occupant.entry
            if laterEntry >= earlierEntry + earlierLifetime { return 0 }
            let required: TimeInterval
            if occupant.direction == requestDirection {
                required = DanmakuTrackLayout.requiredGap(
                    leadingWidth: earlierIsOccupant ? occupant.width : request.width,
                    leadingLifetime: earlierLifetime,
                    trailingWidth: earlierIsOccupant ? request.width : occupant.width,
                    trailingLifetime: earlierIsOccupant ? requestLifetime : occupant.lifetime,
                    surfaceWidth: metrics.width
                )
            } else {
                // Opposite-direction scroll paths cross the full viewport in
                // opposite senses, so overlapping visible intervals always meet.
                required = earlierLifetime
            }
            let gap = laterEntry - earlierEntry
            guard gap > 0 else { return max(required, .ulpOfOne) }
            return max(0, required - gap)
        }

        private mutating func placeScroll(_ request: Request) -> Placement {
            var soonest: (lane: Int, delay: TimeInterval)?
            for lane in scrollLanes.indices {
                var delay: TimeInterval = 0
                for occupant in scrollLanes[lane] {
                    delay = max(delay, scrollDelay(request, behind: occupant))
                }
                if delay == 0 {
                    scrollLanes[lane].append(occupant(for: request, lane: lane, lifetime: metrics.scrollLifetime))
                    return .lane(lane)
                }
                if soonest.map({ delay < $0.delay }) ?? true {
                    soonest = (lane, delay)
                }
            }
            guard request.forced, let pick = soonest else { return .dropped }
            // Forced echo still joins the same retained book; its authored
            // entry cannot retire older or newer occupants either.
            let entry = occupant(for: request, lane: pick.lane, lifetime: metrics.scrollLifetime)
            scrollLanes[pick.lane].append(entry)
            return .lane(pick.lane)
        }

        /// Which fixed table to place into.
        ///
        /// A band selector rather than an `inout [[Occupant]]` because
        /// passing `&self.topLanes` into a `mutating` method of the same value
        /// is an overlapping access to `self` and does not compile. Swift is
        /// right to refuse it, and this is the shape that says which table
        /// without borrowing `self` twice.
        private enum FixedBand { case top, bottom }

        private mutating func placeFixed(
            _ request: Request,
            band: FixedBand
        ) -> Placement {
            let lanes = band == .top ? topLanes : bottomLanes
            var soonest: (lane: Int, busyUntil: TimeInterval)?
            for lane in lanes.indices {
                let busyUntil = lanes[lane].map(\.exit).max() ?? -.infinity
                if request.entry >= busyUntil {
                    let placed = occupant(for: request, lane: lane, lifetime: metrics.fixedLifetime)
                    store([placed], lane: lane, band: band)
                    return .lane(lane)
                }
                if soonest.map({ busyUntil < $0.busyUntil }) ?? true {
                    soonest = (lane, busyUntil)
                }
            }
            guard request.forced, let pick = soonest else { return .dropped }
            let placed = occupant(for: request, lane: pick.lane, lifetime: metrics.fixedLifetime)
            let kept = lanes[pick.lane].filter { request.entry < $0.exit }
            store(kept + [placed], lane: pick.lane, band: band)
            return .lane(pick.lane)
        }

        private mutating func store(_ occupants: [Occupant], lane: Int, band: FixedBand) {
            switch band {
            case .top: topLanes[lane] = occupants
            case .bottom: bottomLanes[lane] = occupants
            }
        }
    }

    /// Minimum horizontal breathing room (in points) maintained between the
    /// tail of a leading scroll bullet and the head of a trailing scroll bullet
    /// in the same lane.
    static let minimumHorizontalGap: Double = 28

    /// The minimum entry gap two scroll bullets may share a lane with.
    ///
    /// Exposed rather than private so the derivation above can be tested
    /// directly — including the equal-width identity, which is what says the
    /// two conditions were combined correctly rather than merely both applied.
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

    /// The same two conditions when the two bullets cross at different
    /// lifetimes — a scroll-speed change leaves the ones already flying on
    /// the old lifetime while new ones use the new one.
    ///
    /// ① is the leading bullet's own tail plus `minimumHorizontalGap`, so it
    /// reads only A's speed. ② is "B's left edge stays at least
    /// `minimumHorizontalGap` behind A's tail when A leaves", so it reads A's
    /// lifetime and B's speed.
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

        // ① the leading bullet's tail + breathing spacing clears the right edge
        let tailClears = (max(0, leadingWidth) + spacing) / leadingSpeed
        // ② the trailing bullet does not close within `spacing` before A leaves
        let noOvertake = leadingLife - max(1, width - spacing) / trailingSpeed
        return max(tailClears, noOvertake)
    }

    /// How many lanes fit, given the surface and the user's display-area choice.
    ///
    /// Floors rather than rounds: a partial lane at the bottom would place
    /// bullets that are clipped, and a clipped bullet reads as a rendering bug
    /// rather than as a full screen.
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
