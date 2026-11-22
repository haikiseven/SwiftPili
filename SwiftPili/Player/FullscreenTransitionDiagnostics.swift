import CoreGraphics
import Foundation
import os
import QuartzCore

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

struct FullscreenTransitionTimeline: Equatable, Sendable {
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
    let bodyCountsAtRequest: [String: Int]

    var outcome: Outcome = .open
    var stateSettledMs: Int?
    var sceneRequestMs: Int?
    var sceneRequestMask: String?
    var sceneRequests = 0
    var sceneRequestsWithoutWindow = 0
    var sceneRequestMaskDiverged = false
    var geometrySamples = 0
    var geometryChanges = 0
    var lastGeometryMs: Int?
    var lastGeometryWidth = 0
    var lastGeometryHeight = 0
    var renderUpdates = 0
    var attaches = 0
    var detaches = 0
    var mainThreadStalls = 0
    var worstStallMs = 0
    var missedFrames = 0
    var displayStalls = 0
    var worstFrameGapMs = 0
    var displayWindows = 0
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
        guard sceneRequestMs == nil else {
            if sceneRequestMask != mask { sceneRequestMaskDiverged = true }
            return
        }
        sceneRequestMs = offsetMs(at: now)
        sceneRequestMask = mask
    }

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

enum FullscreenTransitionDiagnostics {
    private struct State {
        var activeID: UInt64?
        var activeTarget: Bool?
        var recentID: UInt64?
        var recentTarget: Bool?
        var recentDeadline: Double = 0
        var timeline: FullscreenTransitionTimeline?
    }

    private struct Correlation: Sendable {
        let id: UInt64
        let offsetMs: Int
    }

    private struct LockedOutcome: Sendable {
        var correlation: Correlation?
        var retired: FullscreenTransitionTimeline?
        var abandonedID: UInt64?
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

    private static func correlate(
        expectedState: Bool?,
        now: Double,
        in state: inout State
    ) -> Correlation? {
        guard let id = correlationID(expectedState: expectedState, now: now, in: &state) else {
            return nil
        }
        guard let timeline = state.timeline, timeline.id == id else {
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
        signpostLog.signpostsEnabled
    }
}
