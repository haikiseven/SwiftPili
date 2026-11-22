import CoreGraphics
import Foundation
import os
import QuartzCore

/// The UI-side sources that can request the existing fullscreen transition.
/// These labels are intentionally closed and contain no user/content data.
enum FullscreenTransitionSource: String, Sendable {
    case button
    case deviceOrientation
    case verticalSizeClass
}

enum FullscreenTransitionRequestDecision: Equatable, Sendable {
    case start(id: UInt64, supersededID: UInt64?)
    case coalesced(id: UInt64)
    case alreadyAtTarget
    case cancelled(id: UInt64, observedState: Bool)

    var transitionID: UInt64? {
        switch self {
        case let .start(id, _), let .coalesced(id), let .cancelled(id, _): id
        case .alreadyAtTarget: nil
        }
    }
}

enum FullscreenTransitionSettlement: Equatable, Sendable {
    case settled(id: UInt64)
    case interrupted(id: UInt64, actualState: Bool)
    case external

    var transitionID: UInt64? {
        switch self {
        case let .settled(id), let .interrupted(id, _): id
        case .external: nil
        }
    }
}

/// Pure UI request coalescing. A request remains pending until the observed
/// `isFullscreen` value settles, so device-orientation and size-class
/// callbacks that confirm the same transition do not call the VM twice.
///
/// This type deliberately has no player/backend/generation references. It
/// only returns a decision for the caller, which remains responsible for
/// invoking the existing fullscreen API.
struct FullscreenTransitionCoalescer: Equatable, Sendable {
    private(set) var pendingTarget: Bool?
    private(set) var pendingTransitionID: UInt64?
    private(set) var lastSettledTransitionID: UInt64?

    mutating func request(
        target: Bool,
        currentState: Bool,
        transitionID: UInt64
    ) -> FullscreenTransitionRequestDecision {
        if pendingTarget == target, let pendingTransitionID {
            return .coalesced(id: pendingTransitionID)
        }

        if target == currentState {
            guard let pendingTransitionID else { return .alreadyAtTarget }
            self.pendingTarget = nil
            self.pendingTransitionID = nil
            self.lastSettledTransitionID = pendingTransitionID
            return .cancelled(id: pendingTransitionID, observedState: currentState)
        }

        let supersededID = pendingTransitionID
        pendingTarget = target
        pendingTransitionID = transitionID
        return .start(id: transitionID, supersededID: supersededID)
    }

    mutating func settle(actualState: Bool) -> FullscreenTransitionSettlement {
        guard let pendingTarget, let pendingTransitionID else {
            return .external
        }

        self.pendingTarget = nil
        self.pendingTransitionID = nil
        lastSettledTransitionID = pendingTransitionID

        if pendingTarget == actualState {
            return .settled(id: pendingTransitionID)
        }
        return .interrupted(id: pendingTransitionID, actualState: actualState)
    }
}

/// Timeline value for one fullscreen transition. Remains open across `isFullscreen`
/// state settlement until `correlationWindow` closes so scene rotation, layout,
/// surface updates, and frame-interval metrics are captured together.
struct FullscreenTransitionTimeline: Equatable, Sendable {
    /// How the transition left the state machine. A closed label set, so the
    /// summary line never carries free text.
    enum Outcome: String, Equatable, Sendable {
        case open
        case settled
        case interrupted
        case cancelled
        case superseded
        case external
    }

    let id: UInt64
    let target: Bool
    let source: String
    let startedAt: Double
    let startGeneration: Int
    /// Body-eval counts at request time; the delta is taken at the SUMMARY, not
    /// at the state settlement. Empty when metering is off, which is also what
    /// the summary prints — an absent measurement, never a zero.
    let bodyCountsAtRequest: [String: Int]

    var outcome: Outcome = .open
    /// Offset of the `isFullscreen` observation. Stage "state mutation
    /// observed", not "transition finished".
    var stateSettledMs: Int?
    /// Offset of the scene geometry request — the call that starts UIKit's
    /// rotation. Before this existed, the single most expensive stage of the
    /// transition emitted no event at all.
    var sceneRequestMs: Int?
    var sceneRequestMask: String?
    /// How many geometry requests this one transition made, and how many of them
    /// found no window to send it to. More than one request per transition is
    /// the "multiple orientation state mutations" shape.
    var sceneRequests = 0
    var sceneRequestsWithoutWindow = 0
    /// Whether a later request inside the window asked for a different orientation mask
    /// (e.g., teardown calling `exitFullscreen()` during the enter correlation window).
    var sceneRequestMaskDiverged = false
    /// `geometrySamples` counts all distinct SwiftUI geometry/size-class callbacks;
    /// `geometryChanges` counts those that changed `width` or `height`.
    var geometrySamples = 0
    var geometryChanges = 0
    var lastGeometryMs: Int?
    var lastGeometryWidth = 0
    var lastGeometryHeight = 0
    /// Representable updates; a fullscreen toggle must preserve `attach=0 detach=0`.
    var renderUpdates = 0
    var attaches = 0
    var detaches = 0
    var mainThreadStalls = 0
    var worstStallMs = 0
    /// Overlapping 2 s display-link reporting windows (`frameInterval` below provides
    /// transition-aligned frame metrics for the summary line).
    var missedFrames = 0
    var displayStalls = 0
    var worstFrameGapMs = 0
    var displayWindows = 0
    /// Caller-defined `UIHitchMonitor` frame interval opened at request time and
    /// closed when this summary is emitted (`nil` when diagnostics are disabled).
    var frameIntervalToken: Int?
    var frameInterval: UIHitchMonitor.FrameInterval?
    var endGeneration: Int
    var summaryEmitted = false

    init(
        id: UInt64,
        target: Bool,
        source: String,
        startedAt: Double,
        generation: Int,
        bodyCounts: [String: Int]
    ) {
        self.id = id
        self.target = target
        self.source = source
        self.startedAt = startedAt
        startGeneration = generation
        endGeneration = generation
        bodyCountsAtRequest = bodyCounts
    }

    func offsetMs(at now: Double) -> Int {
        max(0, Int(((now - startedAt) * 1000).rounded()))
    }

    mutating func noteStateSettled(
        at now: Double,
        outcome: Outcome,
        generation: Int
    ) {
        stateSettledMs = offsetMs(at: now)
        self.outcome = outcome
        endGeneration = generation
    }

    mutating func noteSceneGeometryRequest(
        mask: String,
        windowResolved: Bool,
        at now: Double
    ) {
        sceneRequests += 1
        if !windowResolved { sceneRequestsWithoutWindow += 1 }
        // FIRST request only for the offset: the mask write, the
        // supported-orientation re-query and the geometry update are one intent,
        // and a later reconciler firing into the same window must not overwrite
        // when the rotation was actually asked for. The COUNT still rises, so a
        // transition that asked twice says so — and if the second ask was for a
        // different mask, so does that, because the two are different findings.
        guard sceneRequestMs == nil else {
            if sceneRequestMask != mask { sceneRequestMaskDiverged = true }
            return
        }
        sceneRequestMs = offsetMs(at: now)
        sceneRequestMask = mask
    }

    /// Records one geometry callback. Returns whether the SIZE changed, which is
    /// what the per-signature log line is gated on; the sample is counted either
    /// way.
    mutating func noteGeometry(width: Int, height: Int, at now: Double) -> Bool {
        geometrySamples += 1
        let changed = width != lastGeometryWidth || height != lastGeometryHeight
        lastGeometryWidth = width
        lastGeometryHeight = height
        lastGeometryMs = offsetMs(at: now)
        if changed { geometryChanges += 1 }
        return changed
    }

    mutating func noteRenderUpdate(attaches: Int, detaches: Int, generation: Int) {
        renderUpdates += 1
        self.attaches += attaches
        self.detaches += detaches
        endGeneration = generation
    }

    mutating func noteMainThreadStall(milliseconds: Int) {
        mainThreadStalls += 1
        worstStallMs = max(worstStallMs, milliseconds)
    }

    mutating func noteDisplayWindow(
        missedSlots: Int,
        stalls: Int,
        worstGapMilliseconds: Int
    ) {
        displayWindows += 1
        missedFrames += missedSlots
        displayStalls += stalls
        worstFrameGapMs = max(worstFrameGapMs, worstGapMilliseconds)
    }

    /// Every acceptance number for one tap, in one line's fields.
    ///
    /// `lastLayout` is the honest answer to "when did the transition finish":
    /// the last geometry the surface reported inside the correlation window.
    /// Nothing moved after it — that is what makes it the settled frame,
    /// rather than any threshold this type could have guessed.
    func summaryFields(bodies: String) -> String {
        var fields = "id=\(id) source=\(source) "
            + "target=\(target ? "fullscreen" : "inline") outcome=\(outcome.rawValue)"
        fields += " state=\(stateSettledMs.map { "+\($0)ms" } ?? "n/a")"
        if let sceneRequestMs {
            fields += " scene=\(sceneRequestMask ?? "?")@+\(sceneRequestMs)ms"
                + "×\(sceneRequests)"
            if sceneRequestsWithoutWindow > 0 {
                fields += " sceneNoWindow=\(sceneRequestsWithoutWindow)"
            }
            if sceneRequestMaskDiverged {
                fields += " sceneMaskDiverged=y"
            }
        } else {
            fields += " scene=none"
        }
        if let lastGeometryMs {
            fields += " lastLayout=+\(lastGeometryMs)ms"
                + " size=\(lastGeometryWidth)x\(lastGeometryHeight)"
        } else {
            fields += " lastLayout=n/a"
        }
        fields += " geom=\(geometryChanges)/\(geometrySamples)"
        fields += " render=\(renderUpdates) attach=\(attaches) detach=\(detaches)"
        fields += " generation=\(startGeneration)→\(endGeneration)"
        fields += " stallWorst=\(worstStallMs)ms stalls=\(mainThreadStalls)"
        // `frameScope=transition` marks the semantics: a capture without it
        // predates this change and its frame fields are 2 s neighbourhood
        // readings, not measurements of the transition. Do not compare across
        // that boundary.
        if let interval = frameInterval {
            fields += " missed=\(interval.missed) frameStalls=\(interval.stalls)"
                + " frameWorst=\(interval.worstMilliseconds)ms"
                + " frameSpan=\(interval.spanMilliseconds)ms frameScope=transition"
                + " frameBoundaryGaps=\(interval.boundaryGaps) frameMeter=callback-estimate-v2"
        } else {
            fields += " missed=n/a frameStalls=n/a frameWorst=n/a frameScope=off"
        }
        fields += " winMissed=\(missedFrames) winWorst=\(worstFrameGapMs)ms"
            + " frameWindows=\(displayWindows)"
        fields += " bodies=[\(bodies)]"
        return fields
    }
}

/// Correlates the UI transition boundary with layout, render-host, hitch, and
/// main-thread observations. Only numeric IDs, enum labels, dimensions, and
/// counters enter this sink; URL-bearing player state is intentionally not an
/// input to the API.
enum FullscreenTransitionDiagnostics {
    private struct State {
        var activeID: UInt64?
        var activeTarget: Bool?
        var recentID: UInt64?
        var recentTarget: Bool?
        var recentDeadline: Double = 0
        /// The open record. It spans the WHOLE transition — request through the
        /// close of the correlation window — not request through state
        /// settlement. See `FullscreenTransitionTimeline`.
        var timeline: FullscreenTransitionTimeline?
    }

    /// What a locked section hands back for logging. Logging never happens
    /// inside `withLock`: `PlayerLog.log` takes an autoclosure that interpolates
    /// arbitrary state, and one lock is not a place to run it.
    private struct Correlation: Sendable {
        let id: UInt64
        let offsetMs: Int
    }

    /// A locked section's whole answer, as one named value. `withLock` returns
    /// across an isolation boundary, and a struct states its `Sendable`
    /// conformance rather than leaning on a tuple's implicit one — the same
    /// reason the superseded `ActiveOpening` existed.
    private struct LockedOutcome: Sendable {
        var correlation: Correlation?
        /// Set when a completed record was taken out of the sink to be logged.
        var retired: FullscreenTransitionTimeline?
        var abandonedID: UInt64?
        /// Whether the geometry sample changed the surface size.
        var geometryChanged = false
        var geometrySamples = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let sequence = OSAllocatedUnfairLock(initialState: UInt64(0))
    private static let correlationWindow: Double = 2.5
    private static let signpostLog = OSLog(
        subsystem: PlayerLog.subsystem,
        category: "PlayerTransition"
    )

    static func nextTransitionID() -> UInt64 {
        sequence.withLock { value in
            value &+= 1
            return value
        }
    }

    static func recordRequest(
        decision: FullscreenTransitionRequestDecision,
        source: FullscreenTransitionSource,
        target: Bool,
        currentState: Bool,
        playerGeneration: Int,
        hasURL: Bool,
        surfaceSize: CGSize,
        verticalSizeClass: String
    ) {
        switch decision {
        case let .start(id, supersededID):
            let startedAt = CACurrentMediaTime()
            let bodyCounts = UIHitchMonitor.bodyCountSnapshot()
            // A new request retires whatever record was still open — either the
            // transition it supersedes, or one whose correlation window has
            // simply closed. Both flush here so no tap's numbers are lost to
            // the next tap.
            let retired = state.withLock { state -> FullscreenTransitionTimeline? in
                var closing: FullscreenTransitionTimeline?
                if var open = state.timeline, !open.summaryEmitted {
                    if open.id == supersededID { open.outcome = .superseded }
                    open.summaryEmitted = true
                    closing = open
                }
                state.activeID = id
                state.activeTarget = target
                state.recentID = id
                state.recentTarget = target
                state.recentDeadline = startedAt + correlationWindow
                state.timeline = FullscreenTransitionTimeline(
                    id: id,
                    target: target,
                    source: source.rawValue,
                    startedAt: startedAt,
                    generation: playerGeneration,
                    bodyCounts: bodyCounts
                )
                state.timeline?.frameIntervalToken = UIHitchMonitor.beginFrameInterval()
                return closing
            }
            if let retired {
                emitSummary(retired, bodyCountsNow: bodyCounts)
            }
            if let supersededID {
                endSignpost(
                    id: supersededID,
                    phase: "superseded",
                    fields: "source=ui"
                )
            }
            beginSignpost(
                id: id,
                phase: "request",
                fields: requestFields(
                    source: source,
                    target: target,
                    currentState: currentState,
                    playerGeneration: playerGeneration,
                    hasURL: hasURL,
                    surfaceSize: surfaceSize,
                    verticalSizeClass: verticalSizeClass
                )
            )
            PlayerLog.log(
                "[Transition] fullscreen request id=\(id) source=\(source.rawValue) "
                    + "target=\(target ? "fullscreen" : "inline") "
                    + "current=\(currentState ? "fullscreen" : "inline") "
                    + "generation=\(playerGeneration) hasURL=\(hasURL ? "y" : "n") "
                    + "size=\(Int(surfaceSize.width))x\(Int(surfaceSize.height)) "
                    + "vSize=\(verticalSizeClass)"
            )

        case let .coalesced(id):
            emitEvent(
                id: id,
                phase: "coalesced",
                fields: "source=\(source.rawValue) target=\(target ? "fullscreen" : "inline")"
            )
            PlayerLog.log(
                "[Transition] fullscreen coalesced id=\(id) source=\(source.rawValue) "
                    + "target=\(target ? "fullscreen" : "inline")"
            )

        case let .cancelled(id, observedState):
            let now = CACurrentMediaTime()
            state.withLock { state in
                state.activeID = nil
                state.activeTarget = nil
                state.recentID = id
                state.recentTarget = observedState
                state.recentDeadline = now + correlationWindow
                if state.timeline?.id == id {
                    let stateSettledMs = state.timeline?.offsetMs(at: now)
                    state.timeline?.outcome = .cancelled
                    state.timeline?.stateSettledMs = stateSettledMs
                }
            }
            endSignpost(
                id: id,
                phase: "cancelled",
                fields: "observed=\(observedState ? "fullscreen" : "inline")"
            )
            PlayerLog.log(
                "[Transition] fullscreen request cancelled id=\(id) "
                    + "observed=\(observedState ? "fullscreen" : "inline")"
            )

        case .alreadyAtTarget:
            break
        }
    }

    static func recordSettlement(
        _ settlement: FullscreenTransitionSettlement,
        actualState: Bool,
        playerGeneration: Int,
        hasURL: Bool,
        surfaceSize: CGSize,
        verticalSizeClass: String
    ) {
        let now = CACurrentMediaTime()
        switch settlement {
        case let .settled(id):
            // Keep the record open across `correlationWindow` so rotation, relayout,
            // and frame intervals after the state flip are included in the summary.
            let offset = state.withLock { state -> Int? in
                state.activeID = nil
                state.activeTarget = nil
                state.recentID = id
                state.recentTarget = actualState
                state.recentDeadline = now + correlationWindow
                guard state.timeline?.id == id else { return nil }
                state.timeline?.noteStateSettled(
                    at: now,
                    outcome: .settled,
                    generation: playerGeneration
                )
                return state.timeline?.stateSettledMs
            }
            endSignpost(
                id: id,
                phase: "settled",
                fields: settlementFields(
                    actualState: actualState,
                    playerGeneration: playerGeneration,
                    hasURL: hasURL,
                    surfaceSize: surfaceSize,
                    verticalSizeClass: verticalSizeClass
                )
            )
            PlayerLog.log(
                "[Transition] fullscreen state settled id=\(id) "
                    + "state=\(actualState ? "fullscreen" : "inline") "
                    + "at=\(offset.map { "+\($0)ms" } ?? "n/a") "
                    + "generation=\(playerGeneration) hasURL=\(hasURL ? "y" : "n") "
                    + "size=\(Int(surfaceSize.width))x\(Int(surfaceSize.height)) "
                    + "vSize=\(verticalSizeClass)"
            )

        case let .interrupted(id, actualState):
            state.withLock { state in
                state.activeID = nil
                state.activeTarget = nil
                state.recentID = id
                state.recentTarget = actualState
                state.recentDeadline = now + correlationWindow
                if state.timeline?.id == id {
                    state.timeline?.noteStateSettled(
                        at: now,
                        outcome: .interrupted,
                        generation: playerGeneration
                    )
                }
            }
            endSignpost(
                id: id,
                phase: "interrupted",
                fields: "actual=\(actualState ? "fullscreen" : "inline")"
            )
            PlayerLog.log(
                "[Transition] fullscreen interrupted id=\(id) "
                    + "state=\(actualState ? "fullscreen" : "inline")"
            )

        case .external:
            let bodyCounts = UIHitchMonitor.bodyCountSnapshot()
            let outcome = state.withLock { state -> LockedOutcome in
                var result = LockedOutcome()
                result.abandonedID = state.activeID
                state.activeID = nil
                state.activeTarget = nil
                state.recentID = nil
                state.recentTarget = nil
                state.recentDeadline = 0
                if var open = state.timeline, !open.summaryEmitted {
                    open.outcome = .external
                    open.summaryEmitted = true
                    result.retired = open
                }
                state.timeline = nil
                return result
            }
            if let abandonedID = outcome.abandonedID {
                endSignpost(
                    id: abandonedID,
                    phase: "external",
                    fields: "state=\(actualState ? "fullscreen" : "inline")"
                )
            }
            if let retired = outcome.retired {
                emitSummary(retired, bodyCountsNow: bodyCounts)
            }
            emitEvent(
                id: nil,
                phase: "external-state",
                fields: "state=\(actualState ? "fullscreen" : "inline") generation=\(playerGeneration)"
            )
            PlayerLog.log(
                "[Transition] fullscreen external state=\(actualState ? "fullscreen" : "inline") "
                    + "generation=\(playerGeneration) hasURL=\(hasURL ? "y" : "n")"
            )
        }
    }

    /// The scene geometry request that starts UIKit's rotation.
    ///
    /// This is the stage the transition map had no event for at all: the state
    /// flip was logged, the geometry that came out the other side was logged,
    /// and the call between them — the one whose animation the SwiftUI frame
    /// animation then runs against — was invisible. `mask` is a closed label
    /// supplied by the caller, so no UIKit type enters this sink.
    /// `windowResolved` is false when the filtered window probe found nothing,
    /// which is the documented way this request silently does nothing at all
    /// (see `AppWindowMetrics`). A transition whose summary shows
    /// `scene=landscape@+1ms` but never reaches a landscape geometry is a
    /// different bug from one that rotates slowly, and only this field separates
    /// them.
    static func recordSceneGeometryRequest(mask: String, windowResolved: Bool) {
        let now = CACurrentMediaTime()
        let correlation = state.withLock { state -> Correlation? in
            guard let correlation = correlate(expectedState: nil, now: now, in: &state) else {
                return nil
            }
            state.timeline?.noteSceneGeometryRequest(
                mask: mask,
                windowResolved: windowResolved,
                at: now
            )
            return correlation
        }
        guard let correlation else { return }
        let fields = "mask=\(mask) window=\(windowResolved ? "y" : "n")"
        emitEvent(id: correlation.id, phase: "scene-geometry-request", fields: fields)
        PlayerLog.log(
            "[Transition] scene geometry request id=\(correlation.id) "
                + "+\(correlation.offsetMs)ms \(fields)"
        )
    }

    static func recordGeometrySettlement(
        size: CGSize,
        isFullscreen: Bool,
        verticalSizeClass: String
    ) {
        let now = CACurrentMediaTime()
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let outcome = state.withLock { state -> LockedOutcome in
            var result = LockedOutcome()
            guard let correlation = correlate(
                expectedState: isFullscreen,
                now: now,
                in: &state
            ) else { return result }
            result.correlation = correlation
            result.geometryChanged = state.timeline?.noteGeometry(
                width: width,
                height: height,
                at: now
            ) ?? true
            result.geometrySamples = state.timeline?.geometrySamples ?? 0
            return result
        }
        guard let correlation = outcome.correlation, outcome.geometryChanged else { return }
        let samples = outcome.geometrySamples

        let fields = "width=\(width) height=\(height) pass=\(samples) "
            + "state=\(isFullscreen ? "fullscreen" : "inline") vSize=\(verticalSizeClass)"
        emitEvent(id: correlation.id, phase: "geometry-settled", fields: fields)
        PlayerLog.log(
            "[Transition] geometry id=\(correlation.id) +\(correlation.offsetMs)ms \(fields)"
        )
    }

    /// Called for every representable update, and for the actual attach/detach
    /// boundary. Updates are emitted only while a transition is current/recent
    /// (or when they reattach), keeping the normal render path quiet.
    static func recordRenderContainer(
        phase: String,
        generation: Int,
        hasController: Bool,
        reattaches: Bool
    ) {
        let now = CACurrentMediaTime()
        let correlation = state.withLock { state -> Correlation? in
            guard let correlation = correlate(expectedState: nil, now: now, in: &state) else {
                return nil
            }
            state.timeline?.noteRenderUpdate(
                attaches: phase == "attach" ? 1 : 0,
                detaches: phase == "detach" ? 1 : 0,
                generation: generation
            )
            return correlation
        }
        guard correlation != nil || reattaches else { return }
        let idText = correlation.map { String($0.id) } ?? "-"
        let at = correlation.map { "+\($0.offsetMs)ms " } ?? ""
        let fields = "transition=\(idText) phase=\(phase) generation=\(generation) "
            + "controller=\(hasController ? "y" : "n") reattach=\(reattaches ? "y" : "n")"
        emitEvent(id: correlation?.id, phase: "render-container", fields: fields)
        PlayerLog.log("[Transition] render \(at)\(fields)")
    }

    /// Returns the active/recent transition ID so the existing hitch line can
    /// carry the same correlation key without changing its counter semantics.
    ///
    /// Also the flush point for a finished transition's summary. The display
    /// link is the one periodic tick this sink can borrow, and it runs under the
    /// same Debug Logging switch that makes these lines readable in the first
    /// place — so a summary lands within one reporting window of the transition
    /// closing, with no timer of its own.
    @discardableResult
    static func recordDisplayLinkWindow(
        seconds: CFTimeInterval,
        ticks: Int,
        missedSlots: Int,
        stalls: Int,
        worstGapMilliseconds: Int
    ) -> UInt64? {
        let now = CACurrentMediaTime()
        let bodyCounts = UIHitchMonitor.bodyCountSnapshot()
        let outcome = state.withLock { state -> LockedOutcome in
            var result = LockedOutcome()
            if let correlation = correlate(expectedState: nil, now: now, in: &state) {
                result.correlation = correlation
                state.timeline?.noteDisplayWindow(
                    missedSlots: missedSlots,
                    stalls: stalls,
                    worstGapMilliseconds: worstGapMilliseconds
                )
                return result
            }
            // No correlation means the window has closed. Whatever record was
            // open is now complete: emit it once and drop it.
            if var open = state.timeline, !open.summaryEmitted {
                open.summaryEmitted = true
                result.retired = open
            }
            state.timeline = nil
            return result
        }
        if let retired = outcome.retired {
            emitSummary(retired, bodyCountsNow: bodyCounts)
        }
        guard let correlation = outcome.correlation else { return nil }
        let fields = "window=\(String(format: "%.2f", seconds)) ticks=\(ticks) "
            + "missed=\(missedSlots) stalls=\(stalls) worstMs=\(worstGapMilliseconds)"
        emitEvent(id: correlation.id, phase: "display-link", fields: fields)
        return correlation.id
    }

    static func recordMainThreadStall(
        milliseconds: Int,
        keyboardState: String
    ) {
        let now = CACurrentMediaTime()
        let correlation = state.withLock { state -> Correlation? in
            guard let correlation = correlate(expectedState: nil, now: now, in: &state) else {
                return nil
            }
            state.timeline?.noteMainThreadStall(milliseconds: milliseconds)
            return correlation
        }
        guard let correlation else { return }
        // The offset is where the stall was OBSERVED, which is where it ended:
        // `FreezeWatchdog` reports on acknowledgement, so the stall occupied
        // roughly [offset − stallMs, offset].
        let fields = "stallMs=\(milliseconds) keyboard=\(keyboardState)"
        emitEvent(id: correlation.id, phase: "main-thread-stall", fields: fields)
        PlayerLog.log(
            "[Transition] main-thread stall id=\(correlation.id) "
                + "ended=+\(correlation.offsetMs)ms \(fields)"
        )
    }

    private static func emitSummary(
        _ timeline: FullscreenTransitionTimeline,
        bodyCountsNow: [String: Int]
    ) {
        var timeline = timeline
        if let token = timeline.frameIntervalToken {
            timeline.frameInterval = UIHitchMonitor.endFrameInterval(token)
            timeline.frameIntervalToken = nil
        }
        let bodies = timeline.bodyCountsAtRequest.isEmpty
            ? "off"
            : UIHitchMonitor.bodyCountDelta(
                from: timeline.bodyCountsAtRequest,
                to: bodyCountsNow
            )
        let fields = timeline.summaryFields(bodies: bodies)
        emitEvent(id: timeline.id, phase: "summary", fields: fields)
        PlayerLog.log("[Transition] fullscreen summary \(fields)")
    }

    private static func requestFields(
        source: FullscreenTransitionSource,
        target: Bool,
        currentState: Bool,
        playerGeneration: Int,
        hasURL: Bool,
        surfaceSize: CGSize,
        verticalSizeClass: String
    ) -> String {
        "source=\(source.rawValue) target=\(target ? "fullscreen" : "inline") "
            + "current=\(currentState ? "fullscreen" : "inline") "
            + "generation=\(playerGeneration) hasURL=\(hasURL ? "y" : "n") "
            + "width=\(Int(surfaceSize.width.rounded())) height=\(Int(surfaceSize.height.rounded())) "
            + "vSize=\(verticalSizeClass)"
    }

    private static func settlementFields(
        actualState: Bool,
        playerGeneration: Int,
        hasURL: Bool,
        surfaceSize: CGSize,
        verticalSizeClass: String
    ) -> String {
        "state=\(actualState ? "fullscreen" : "inline") generation=\(playerGeneration) "
            + "hasURL=\(hasURL ? "y" : "n") "
            + "width=\(Int(surfaceSize.width.rounded())) height=\(Int(surfaceSize.height.rounded())) "
            + "vSize=\(verticalSizeClass)"
    }

    /// The active/recent transition this observation belongs to, plus how far
    /// into it the observation landed. Must be called inside `withLock`.
    private static func correlate(
        expectedState: Bool?,
        now: Double,
        in state: inout State
    ) -> Correlation? {
        guard let id = correlationID(expectedState: expectedState, now: now, in: &state) else {
            return nil
        }
        guard let timeline = state.timeline, timeline.id == id else {
            // A live routing entry with no record behind it — the sink was
            // reset, or the observation belongs to a transition older than the
            // one being kept. Correlate it, but with no offset to claim.
            return Correlation(id: id, offsetMs: 0)
        }
        return Correlation(id: id, offsetMs: timeline.offsetMs(at: now))
    }

    private static func correlationID(
        expectedState: Bool?,
        now: Double,
        in state: inout State
    ) -> UInt64? {
        if let activeID = state.activeID {
            if let expectedState, let activeTarget = state.activeTarget,
               expectedState != activeTarget {
                return nil
            }
            return activeID
        }
        guard now <= state.recentDeadline,
              let recentID = state.recentID else {
            state.recentID = nil
            state.recentTarget = nil
            state.recentDeadline = 0
            return nil
        }
        if let expectedState, state.recentTarget != expectedState {
            return nil
        }
        return recentID
    }

    private static func beginSignpost(id: UInt64, phase: String, fields: String) {
        guard signpostsEnabled else { return }
        os_signpost(
            .begin,
            log: signpostLog,
            name: "PlayerFullscreenTransition",
            signpostID: OSSignpostID(id),
            "phase=%{public}s %{public}s",
            phase,
            fields
        )
    }

    private static func endSignpost(id: UInt64, phase: String, fields: String) {
        guard signpostsEnabled else { return }
        os_signpost(
            .end,
            log: signpostLog,
            name: "PlayerFullscreenTransition",
            signpostID: OSSignpostID(id),
            "phase=%{public}s %{public}s",
            phase,
            fields
        )
    }

    private static func emitEvent(id: UInt64?, phase: String, fields: String) {
        guard signpostsEnabled else { return }
        os_signpost(
            .event,
            log: signpostLog,
            name: "PlayerFullscreenTransition",
            signpostID: id.map { OSSignpostID($0) } ?? .exclusive,
            "phase=%{public}s %{public}s",
            phase,
            fields
        )
    }

    private static var signpostsEnabled: Bool {
        // Keep signposts independent from textual Debug Logging so an
        // Instruments run can compare logging-on and logging-off behavior.
        // Callers still gate their existing PlayerLog lines as before.
        signpostLog.signpostsEnabled
    }
}
