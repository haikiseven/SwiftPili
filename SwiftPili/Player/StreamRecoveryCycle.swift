import Foundation

/// One episode spanning real source requests and actual installed backend loads.
/// Budget debt stays in RecoveryBudget; this object owns only operation identity.
@MainActor
final class StreamRecoveryCycle {
    struct Installed {
        let backend: ObjectIdentifier
        let generation: UInt64
        var readySession: UInt64?
    }

    let id = UUID()
    let owner: PlayerOwnerLease
    let budgetID: UUID
    let aid: Int
    let cid: Int
    let source: PlayerViewModel.StreamSource
    let quality: Int
    let audio: AudioQualityTier?
    let requestAdmission: (@MainActor @Sendable () -> Bool)?
    var loadGeneration: Int
    var target: TimeInterval
    var failure: StreamTransportFailure
    var requestID: UUID?
    var attemptSerial = 0
    var issued = false
    var ticket: UInt64?
    var installed: Installed?
    var outputSession: UInt64?
    var lastProgress: TimeInterval?
    var recovering = true
    var suspended = false
    var operation: Task<Void, Never>?
    var deadline: Task<Void, Never>?

    init(owner: PlayerOwnerLease, budgetID: UUID, aid: Int, cid: Int,
         source: PlayerViewModel.StreamSource, quality: Int, audio: AudioQualityTier?,
         requestAdmission: (@MainActor @Sendable () -> Bool)?, loadGeneration: Int,
         target: TimeInterval, failure: StreamTransportFailure) {
        self.owner = owner
        self.budgetID = budgetID
        self.aid = aid
        self.cid = cid
        self.source = source
        self.quality = quality
        self.audio = audio
        self.requestAdmission = requestAdmission
        self.loadGeneration = loadGeneration
        self.target = target
        self.failure = failure
    }
}
