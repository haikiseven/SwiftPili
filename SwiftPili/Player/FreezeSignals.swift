import Foundation

struct FreezePlayerSample: Sendable {
    var streamID: String
    var mode: String
    var engine: String
    var state: String
    var expectsProgress: Bool
    var mediaTime: TimeInterval
    var displayTime: TimeInterval
    var fps: Double
    var clockSource: String
    var runway: TimeInterval?
    var videoRunway: TimeInterval?
    var available: TimeInterval
    var networkKBs: Int
    var goodputKBs: Int
    var quality: String
    var host: String
    var recovery: String
}

struct FreezePlayerSignals: Sendable {
    var sample: FreezePlayerSample
    var observedAt: TimeInterval
    var mediaTimeMovedAt: TimeInterval
    var displayTimeMovedAt: TimeInterval
    var fpsLiveAt: TimeInterval

    init(first sample: FreezePlayerSample, at now: TimeInterval) {
        self.sample = sample
        observedAt = now
        mediaTimeMovedAt = now
        displayTimeMovedAt = now
        fpsLiveAt = now
    }

    static let movementEpsilon: TimeInterval = 0.001

    mutating func absorb(_ next: FreezePlayerSample, at now: TimeInterval) {
        observedAt = now
        if abs(next.mediaTime - sample.mediaTime) > Self.movementEpsilon {
            mediaTimeMovedAt = now
        }
        if abs(next.displayTime - sample.displayTime) > Self.movementEpsilon {
            displayTimeMovedAt = now
        }
        if next.fps >= 1 { fpsLiveAt = now }
        sample = next
    }
}

enum FreezeVerdict: Equatable, Sendable {
    case mainThreadFreeze
    case mainQueueStarvation
    case displayStall
    case playerStarvation

    var label: String {
        switch self {
        case .mainThreadFreeze: "main-thread-freeze"
        case .mainQueueStarvation: "main-queue-starvation"
        case .displayStall: "display-stall"
        case .playerStarvation: "player-starvation"
        }
    }

    var meaning: String {
        switch self {
        case .mainThreadFreeze:
            "main thread blocked — display link stopped with it; the whole UI is dead"
        case .mainQueueStarvation:
            "run loop alive (display ticking) but main-queue work not draining — "
                + "nested run loop / tracking mode, NOT a blocked thread"
        case .displayStall:
            "main thread responsive, display link stale — render/display pipeline, not an app freeze"
        case .playerStarvation:
            "UI and display healthy, media clock frozen — player starvation, NOT an app freeze"
        }
    }
}

enum FreezeClassifier {
    static let stallSeconds: TimeInterval = 0.5
    static let freezeSeconds: TimeInterval = 1.0
    static let displayStaleSeconds: TimeInterval = 0.5
    static let clockStaleSeconds: TimeInterval = 3.0
    static let implausibleSeconds: TimeInterval = 60

    static func classify(
        ackAge: TimeInterval,
        displayAge: TimeInterval?,
        clockAge: TimeInterval?
    ) -> FreezeVerdict? {
        if ackAge >= stallSeconds {
            guard let displayAge else { return .mainThreadFreeze }
            return displayAge >= displayStaleSeconds ? .mainThreadFreeze : .mainQueueStarvation
        }
        if let displayAge, displayAge >= displayStaleSeconds { return .displayStall }
        if let clockAge, clockAge >= clockStaleSeconds { return .playerStarvation }
        return nil
    }

    static func severity(ackAge: TimeInterval) -> String {
        ackAge >= freezeSeconds ? "freeze" : "stall"
    }
}
