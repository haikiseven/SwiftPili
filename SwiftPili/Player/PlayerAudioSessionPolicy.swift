import AVFoundation

/// One checked native configuration effect for App admission and engine startup.
/// The caller keeps playback intent; no error is consumed by this boundary.
@MainActor
enum PlayerAudioSessionActivation {
    static func configure() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
    }

    static func activate() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }

    static func configureAndActivate() throws {
        try configure()
        try activate()
    }
}

/// Immutable platform input. Notification dictionaries never cross an actor hop.
enum PlayerAudioSessionEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case oldDeviceUnavailable
    case mediaServicesReset

    static func interruption(type: UInt?, options: UInt?) -> Self? {
        guard let type, let value = AVAudioSession.InterruptionType(rawValue: type) else { return nil }
        switch value {
        case .began: return .interruptionBegan
        case .ended:
            return .interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(
                rawValue: options ?? 0
            ).contains(.shouldResume))
        @unknown default: return nil
        }
    }

    static func route(reason: UInt?) -> Self? {
        guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return nil }
        return .oldDeviceUnavailable
    }
}

/// App suppression authority, independent of durable user intent and transport.
/// Successful activation is the only operation that discharges activation debt.
struct PlayerAudioSessionPolicy {
    /// Snapshot of the existing App gates, shared by notification admission and
    /// constructible tests without consulting the singleton player or UIKit.
    struct InterruptionResumeContext {
        let systemPausedIntent: Bool
        let terminal: Bool
        let pendingMediaReset: Bool
        let applicationActive: Bool
        let allowsBackgroundPlayback: Bool

        var eligible: Bool {
            systemPausedIntent && !terminal && !pendingMediaReset
                && (applicationActive || allowsBackgroundPlayback)
        }
    }

    private(set) var interrupted = false
    private(set) var needsActivation = false
    private(set) var requiresUserPlay = false

    var suppressesPlayback: Bool { interrupted || needsActivation || requiresUserPlay }

    mutating func beginInterruption() {
        interrupted = true
        needsActivation = true
    }

    mutating func requireActivation() {
        needsActivation = true
    }

    mutating func requireUserPlay() {
        requiresUserPlay = true
    }

    mutating func reset() {
        interrupted = false
        needsActivation = true
        requiresUserPlay = true
    }

    /// Resolve a genuine end before attempting checked activation. A delayed
    /// end after successful explicit Play has no current interruption authority.
    /// The caller issues Play only after this mutating admission returns.
    mutating func endInterruption(
        shouldResume: Bool,
        context: InterruptionResumeContext,
        activate: () throws -> Void
    ) -> Bool {
        guard interrupted else { return false }
        interrupted = false
        if !shouldResume { requiresUserPlay = true }
        guard shouldResume, context.eligible, !requiresUserPlay else { return false }
        return authorizePlayback(activate: activate)
    }

    mutating func authorizePlayback(activate: () throws -> Void) -> Bool {
        if needsActivation {
            do { try activate() } catch { return false }
        }
        interrupted = false
        needsActivation = false
        requiresUserPlay = false
        return true
    }
}

/// A reset owns its descriptor until matching readiness, failure, or replacement.
/// The reset ID is independent from owner and load IDs: repeated resets retire
/// in-flight opens even when content and screen remain identical.
struct PlayerMediaResetRecovery<Source> {
    /// Captured after the loader binds its generation, before asynchronous work.
    /// A nil reset ID preserves ordinary loader admission without reset effects.
    struct LoadCompletion: Sendable {
        let generation: Int
        let owner: PlayerOwnerLease?
        let resetID: UUID?
    }

    struct Request {
        let id: UUID
        let owner: PlayerOwnerLease
        let source: Source
        var opening = false
        var loadGeneration: Int?
    }

    private(set) var request: Request?

    mutating func admit(owner: PlayerOwnerLease, source: Source) {
        request = Request(id: UUID(), owner: owner, source: source)
    }

    mutating func begin(owner: PlayerOwnerLease?) -> Request? {
        guard var current = request, current.owner == owner, !current.opening else { return nil }
        current.opening = true
        request = current
        return current
    }

    func accepts(_ id: UUID, owner: PlayerOwnerLease?) -> Bool {
        request?.id == id && request?.owner == owner
    }

    mutating func bind(_ id: UUID, loadGeneration: Int) {
        guard request?.id == id else { return }
        request?.loadGeneration = loadGeneration
    }

    func allowsLoadCompletion(
        _ completion: LoadCompletion,
        currentGeneration: Int,
        currentOwner: PlayerOwnerLease?
    ) -> Bool {
        guard completion.generation == currentGeneration,
              completion.owner == nil || completion.owner == currentOwner else { return false }
        guard let id = completion.resetID else { return true }
        return accepts(id, owner: currentOwner)
            && request?.opening == true
            && request?.loadGeneration == completion.generation
    }

    /// Actual pre-open failure, not successful loader return/readiness. A
    /// transient failure or current cancellation leaves debt for explicit Play;
    /// permanent refusal retires it so reset precedence cannot bypass Retry policy.
    @discardableResult
    mutating func settlePreOpenFailure(
        _ completion: LoadCompletion,
        currentGeneration: Int,
        currentOwner: PlayerOwnerLease?,
        retryable: Bool
    ) -> Bool {
        guard allowsLoadCompletion(
            completion, currentGeneration: currentGeneration, currentOwner: currentOwner
        ) else { return false }
        if completion.resetID != nil {
            if retryable { settle(loadGeneration: completion.generation, succeeded: false) } else {
                request = nil
            }
        }
        return true
    }

    mutating func settle(loadGeneration: Int, succeeded: Bool) {
        guard request?.opening == true, request?.loadGeneration == loadGeneration else { return }
        if succeeded { request = nil } else {
            request?.opening = false
            request?.loadGeneration = nil
        }
    }

    mutating func invalidate() { request = nil }
}
