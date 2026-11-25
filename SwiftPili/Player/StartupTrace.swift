import Foundation
import QuartzCore

@MainActor
enum StartupTrace {
    struct Token: Hashable, Sendable {
        fileprivate let id: UInt64

        var mediaEngineTraceID: MediaEngineTraceID { MediaEngineTraceID(rawValue: id) }
    }

    struct SessionPolicy: Sendable {
        enum Decision: Equatable, Sendable {
            case ignored
            case recorded
            case completed
            case lateBracket
        }

        private(set) var nextID: UInt64 = 0
        private(set) var activeToken: Token?
        private(set) var completedToken: Token?
        private var seen: Set<String> = []

        mutating func begin() -> Token {
            nextID &+= 1
            let token = Token(id: nextID)
            activeToken = token
            completedToken = nil
            seen.removeAll(keepingCapacity: true)
            return token
        }

        static let lateBracketLabels: Set<String> = ["first-vout", "first-picture-displayed"]

        mutating func mark(_ label: String, token: Token) -> Decision {
            guard token == activeToken else {
                guard token == completedToken,
                      Self.lateBracketLabels.contains(label),
                      seen.insert(label).inserted else { return .ignored }
                return .lateBracket
            }
            guard seen.insert(label).inserted else { return .ignored }
            guard label == StartupTrace.completionLabel else { return .recorded }
            activeToken = nil
            completedToken = token
            return .completed
        }

        mutating func abort(token: Token) -> Bool {
            guard token == activeToken else { return false }
            activeToken = nil
            completedToken = nil
            return true
        }

        func hasStreamingMark(for token: Token) -> Bool {
            token == activeToken && seen.contains(StartupTrace.streamOpenLabel)
        }

        mutating func abortIfStreaming(token: Token) -> Bool {
            guard hasStreamingMark(for: token) else { return false }
            return abort(token: token)
        }
    }

    nonisolated private static let completionLabel = "first-clock-tick"
    nonisolated private static let streamOpenLabel = "stream-open-requested"
    static let measuredFirstFrameLabel = "first-picture-displayed"

    private static var sessionID: UInt64 = 0
    private static var policy = SessionPolicy()
    private static var activeToken: Token?
    private static var t0: CFTimeInterval = 0
    private static var lastMarkAt: CFTimeInterval = 0
    private static var seen: Set<String> = []
    private static var active = false
    private static var completed = false

    @discardableResult
    static func begin(_ context: String) -> Token {
        let now = CACurrentMediaTime()
        if active {
            PlayerLog.log("[Startup] sid=\(sessionID) abandoned at +\(elapsedMilliseconds(from: t0, to: now))ms")
        }
        let token = policy.begin()
        sessionID = token.id
        activeToken = token
        t0 = now
        lastMarkAt = now
        seen.removeAll(keepingCapacity: true)
        active = true
        completed = false
        PlayerLog.log("[Startup] sid=\(sessionID) T0 playback-requested (\(context))")
        return token
    }

    static func mark(_ label: String, token: Token?) {
        guard let token else { return }
        let decision = policy.mark(label, token: token)
        guard decision != .ignored else { return }
        let now = CACurrentMediaTime()
        let total = elapsedMilliseconds(from: t0, to: now)
        let delta = elapsedMilliseconds(from: lastMarkAt, to: now)
        lastMarkAt = now
        seen.insert(label)
        PlayerLog.log("[Startup] sid=\(sessionID) \(label) +\(total)ms (Δ\(delta)ms)")
        if decision == .lateBracket {
            PlayerLog.log("[Startup] sid=\(sessionID) late bracket \(label) closes at +\(total)ms")
        }
        if label == Self.measuredFirstFrameLabel {
            PlayerLog.log("[Startup] sid=\(sessionID) ttff-measured=\(total)ms (first presented frame)")
        }
        if decision == .completed {
            PlayerLog.log("[Startup] sid=\(sessionID) COMPLETE ttff-proxy=\(total)ms")
            active = false
            completed = true
            onComplete?(total)
        }
    }

    static var onComplete: (@MainActor (Int) -> Void)?

    static func abort(_ reason: String, token: Token?) {
        guard let token, active, policy.abort(token: token) else { return }
        PlayerLog.log("[Startup] sid=\(sessionID) aborted (\(reason)) at +\(elapsedMilliseconds(from: t0, to: CACurrentMediaTime()))ms")
        active = false
        completed = false
    }

    static func abortIfStreaming(_ reason: String, token: Token?) {
        guard let token, active, policy.hasStreamingMark(for: token) else { return }
        abort(reason, token: token)
    }

    private static func elapsedMilliseconds(from start: CFTimeInterval, to end: CFTimeInterval) -> Int {
        Int(((end - start) * 1000).rounded())
    }
}

@MainActor
final class StartupTraceMediaEngineTracing: MediaEngineTracing {
    func mark(_ milestone: MediaEngineTraceMilestone, token: MediaEngineTraceID?) {
        StartupTrace.mark(milestone.rawValue, token: token.map { StartupTrace.Token(id: $0.rawValue) })
    }
}
