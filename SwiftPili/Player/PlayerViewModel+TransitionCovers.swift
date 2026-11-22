import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Capture pixels for the departing owner; a capture miss clears any older image for that same owner.
    @discardableResult
    func parkOutgoingRouteStill() -> String? {
        let costSpan = UIHitchMonitor.beginSpan("nav.still")
        defer { UIHitchMonitor.endSpan(costSpan) }
        releaseDepartedRouteStills()
        let owner = ownerKey
        guard !owner.isEmpty else { return nil }
        guard let frame = backend.currentDisplayedFrameForTransition(),
              frame.size.width > 0,
              frame.size.height > 0 else {
            // A miss must drop this owner's previous still. Keeping it would
            // let a historical route paint an image from an earlier transition
            // after a later stack mutation failed to capture a new pixel.
            var stored = outgoingRouteStills
            stored.removeValue(forKey: owner)
            outgoingRouteStills = stored
            outgoingRouteStillExpiry.cancel(owner: owner)
            if outgoingRouteStill?.owner == owner {
                outgoingRouteStill = nil
            }
            PlayerLog.log("[Player] outgoing route still capture missed owner=\(owner)")
            return owner
        }
        var stored = outgoingRouteStills
        stored[owner] = frame
        outgoingRouteStills = stored
        outgoingRouteStill = OutgoingRouteStill(owner: owner, image: frame)
        _ = outgoingRouteStillExpiry.arm(owner: owner) { [weak self] owner, expiryIdentity in
            self?.expireOutgoingRouteStill(owner: owner, expiryIdentity: expiryIdentity)
        }
        PlayerLog.log(
            "[Player] outgoing route still parked owner=\(owner) " +
                "\(Int(frame.size.width))×\(Int(frame.size.height))"
        )
        return owner
    }

    /// Still for one owner. Nil is a miss, not a cue to borrow another
    /// owner's image or `freezeFrame`.
    func outgoingRouteStill(for owner: String) -> UIImage? {
        guard let image = outgoingRouteStills[owner],
              image.size.width > 0,
              image.size.height > 0 else { return nil }
        return image
    }

    func clearOutgoingRouteStill(owner: String) {
        guard outgoingRouteStills[owner] != nil || outgoingRouteStill?.owner == owner else {
            return
        }
        outgoingRouteStillExpiry.cancel(owner: owner)
        var stored = outgoingRouteStills
        stored.removeValue(forKey: owner)
        outgoingRouteStills = stored
        if outgoingRouteStill?.owner == owner {
            outgoingRouteStill = nil
        }
    }

    /// The route has already been removed. Keep the pixels until the next
    /// path mutation so the pop transition can read them; a push must not
    /// come through here, because its from-view is still in the stack.
    func retireDepartedRouteStill(owner: String) {
        guard !owner.isEmpty, !departedRouteStillOwners.contains(owner) else { return }
        departedRouteStillOwners.append(owner)
    }

    func clearAllOutgoingRouteStills() {
        outgoingRouteStillExpiry.cancelAll()
        departedRouteStillOwners.removeAll()
        outgoingRouteStills = [:]
        outgoingRouteStill = nil
    }

    private func releaseDepartedRouteStills() {
        let owners = departedRouteStillOwners
        guard !owners.isEmpty else { return }
        departedRouteStillOwners.removeAll()
        for owner in owners {
            clearOutgoingRouteStill(owner: owner)
        }
    }

    private func expireOutgoingRouteStill(owner: String, expiryIdentity: UInt64) {
        guard outgoingRouteStillExpiry.isCurrent(owner: owner, expiryIdentity),
              outgoingRouteStills[owner] != nil else {
            return
        }
        clearOutgoingRouteStill(owner: owner)
        PlayerLog.log("[Player] outgoing route still expired owner=\(owner)")
    }

    func ownsRecoveryCoverAuthority(_ cover: PlayerRecoveryCover) -> Bool {
        guard usesDemandPresentationContinuity, mode == .vod,
              case .vod = cover.authority.source,
              ownerKey == cover.authority.owner,
              ownerLeaseGeneration == cover.authority.ownerLeaseGeneration,
              let source = decoderRecoverySource() else { return false }
        return source.hasSameAuthority(as: cover.authority.source)
    }

    func retainsRecoveryRenderContainer(owner: String) -> Bool {
        guard let recoveryCover, freezeFrame != nil,
              isCurrentFreezeFrame(recoveryCover.identity),
              owner == recoveryCover.authority.owner,
              activeSurfaceLease?.ownerLease == currentOwnerLease else { return false }
        return ownsRecoveryCoverAuthority(recoveryCover)
    }

    /// Mount a cover only under current source, recovery and render-attachment authority.
    @discardableResult
    func installRecoveryFreezeFrame(
        _ image: UIImage,
        token: UInt64,
        authority: DecoderRecoveryAdmission.Context
    ) -> UInt64? {
        guard usesDemandPresentationContinuity, mode == .vod, error == nil,
              case .vod = authority.source,
              ownerKey == authority.owner,
              ownerLeaseGeneration == authority.ownerLeaseGeneration,
              let source = decoderRecoverySource(), source.hasSameAuthority(as: authority.source),
              let attachment = renderAttachment,
              renderAttachmentSurfaceLease == activeSurfaceLease,
              activeSurfaceLease?.ownerLease == currentOwnerLease else { return nil }
        let identity = installFreezeFrame(image, awaitingFreshProof: true)
        let cover = PlayerRecoveryCover(identity: identity, recoveryToken: token, authority: authority)
        guard case .mounted = cover.mount(image, on: attachment) else {
            if isCurrentFreezeFrame(identity) { clearFreezeFrame() }
            return nil
        }
        recoveryCover = cover
        return identity
    }

    func clearRecoveryCover(matching identity: UInt64) {
        guard let recoveryCover, recoveryCover.identity == identity else { return }
        if isCurrentFreezeFrame(identity) {
            clearFreezeFrame()
        } else {
            recoveryCover.retire()
            self.recoveryCover = nil
        }
    }

    func retireRecoveryCoverIfAuthorityChanged() {
        guard let recoveryCover, !ownsRecoveryCoverAuthority(recoveryCover) else { return }
        clearRecoveryCover(matching: recoveryCover.identity)
    }

    /// Keep the successor session unbound until its actual ready callback identifies it.
    func prepareRecoveryCoverForSuccessorLoad() {
        guard let recoveryCover else { return }
        guard ownsRecoveryCoverAuthority(recoveryCover), isCurrentFreezeFrame(recoveryCover.identity) else {
            clearRecoveryCover(matching: recoveryCover.identity)
            return
        }
        recoveryCover.expectSuccessor(backend)
        freezeFrameExpectedSessionGeneration = nil
    }

    /// Bind the cover to the actual ready successor session.
    func bindRecoveryCoverFromReadyBackend() {
        guard let recoveryCover else { return }
        guard ownsRecoveryCoverAuthority(recoveryCover), isCurrentFreezeFrame(recoveryCover.identity) else {
            clearRecoveryCover(matching: recoveryCover.identity)
            return
        }
        if let session = recoveryCover.bindReadyActualSession(backend) {
            freezeFrameExpectedSessionGeneration = session
        }
    }

    /// Release the cover only when current-session rendered-picture evidence is accepted.
    @discardableResult
    func consumeRecoveryCoverPresentationSample(_ sample: DemandPresentationSample) -> Bool {
        guard let recoveryCover, ownsRecoveryCoverAuthority(recoveryCover),
              isCurrentFreezeFrame(recoveryCover.identity),
              recoveryCover.consumePresentationSample(
                  sample, expectedSession: freezeFrameExpectedSessionGeneration,
                  backend: backend, renderGeneration: playerGeneration
              ) else { return false }
        clearRecoveryCover(matching: recoveryCover.identity)
        return true
    }

    func finishRecoveryCoverSubmission(_ identity: UInt64?) {
        guard let identity, Task.isCancelled || terminalOpenFailure else { return }
        clearRecoveryCover(matching: identity)
    }

    /// Revalidate source, native generation and recovery ticket after asynchronous capture.
    func captureAdmittedRecoveryCover(
        token: UInt64,
        authority: DecoderRecoveryAdmission.Context
    ) async -> RecoveryCoverCapture {
        guard usesDemandPresentationContinuity else { return .unavailable }
        let outgoing = backend
        let generation = outgoing.runtimeGeneration
        let session = outgoing.demandPresentationSessionGeneration
        let image = await outgoing.thumbnailAtCurrentTime()
        guard !Task.isCancelled, backend === outgoing,
              usesDemandPresentationContinuity,
              backend.runtimeGeneration == generation,
              backend.demandPresentationSessionGeneration == session,
              let context = decoderRecoveryContext(), context.hasSameAuthority(as: authority),
              decoderRecoveryAdmission.authoritativeTicket(for: token, matchingAuthority: authority) != nil else {
            return .stale
        }
        guard let image,
              let identity = installRecoveryFreezeFrame(image, token: token, authority: authority) else {
            return .unavailable
        }
        return .mounted(identity)
    }

    func retireCDNFrameCover() {
        if cdnFrameCover != nil { clearFreezeFrame() }
    }

    /// Retire cover identity and expiry together so a late timer cannot remove a newer cover.
    func clearFreezeFrame() {
        recoveryCover?.retire()
        recoveryCover = nil
        transitionCoverExpiry.cancel()
        freezeFrameIdentity &+= 1
        freezeFrame = nil
        freezeFrameSetAt = 0
        freezeFrameAwaitingFreshProof = false
        freezeFrameExpectedSessionGeneration = nil
        cdnFrameCover = nil
    }

    /// Seek covers expire without ticks; recovery/CDN covers wait for successor picture proof.
    @discardableResult
    func installFreezeFrame(
        _ frame: UIImage,
        awaitingFreshProof: Bool
    ) -> UInt64 {
        recoveryCover?.retire()
        recoveryCover = nil
        transitionCoverExpiry.cancel()
        freezeFrameIdentity &+= 1
        freezeFrame = frame
        freezeFrameSetAt = CACurrentMediaTime()
        freezeFrameAwaitingFreshProof = awaitingFreshProof
        freezeFrameExpectedSessionGeneration = nil
        cdnFrameCover = nil
        let coverIdentity = freezeFrameIdentity
        // A hung seek with no ticks must still expire.
        if !awaitingFreshProof {
            _ = transitionCoverExpiry.arm { [weak self] expiryIdentity in
                self?.expireInstalledCover(
                    expiryIdentity: expiryIdentity,
                    coverIdentity: coverIdentity
                )
            }
        }
        return coverIdentity
    }

    func isCurrentFreezeFrame(_ identity: UInt64) -> Bool {
        freezeFrameIdentity == identity
    }

    private func expireInstalledCover(expiryIdentity: UInt64, coverIdentity: UInt64) {
        guard transitionCoverExpiry.isCurrent(expiryIdentity),
              isCurrentFreezeFrame(coverIdentity),
              freezeFrame != nil else {
            return
        }
        clearFreezeFrame()
        PlayerLog.log("[Player] freeze frame expired cover=\(coverIdentity)")
    }
}

/// Pixels the outgoing route keeps after a different owner takes the single
/// renderer. Not a playback cover: the successor's player must not draw it.
struct OutgoingRouteStill {
    let owner: String
    let image: UIImage
}

/// The identity is part of the cleanup contract: a sleeper that wakes after its cover was superseded can only
/// report its own token, and the owner checks the token before touching the current cover.
@MainActor
final class PlayerTransitionCoverExpiry {
    typealias Sleeper = @MainActor @Sendable (Duration) async -> Bool
    typealias Expiration = @MainActor @Sendable (UInt64) -> Void

    private let timeout: Duration
    private let sleeper: Sleeper
    private var task: Task<Void, Never>?
    private(set) var identity: UInt64 = 0

    init(
        timeout: Duration = .seconds(8),
        sleeper: @escaping Sleeper = { duration in
            do {
                try await Task.sleep(for: duration)
                return true
            } catch {
                return false
            }
        }
    ) {
        self.timeout = timeout
        self.sleeper = sleeper
    }

    @discardableResult
    func arm(_ onExpire: @escaping Expiration) -> UInt64 {
        task?.cancel()
        identity &+= 1
        let armedIdentity = identity
        let timeout = self.timeout
        let sleeper = self.sleeper
        task = Task { @MainActor in
            guard await sleeper(timeout), !Task.isCancelled else { return }
            onExpire(armedIdentity)
        }
        return armedIdentity
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        identity == candidate
    }

    func cancel() {
        task?.cancel()
        task = nil
        identity &+= 1
    }
}

/// Gives each owner-keyed route still its own bounded wall-clock lifetime.
/// A single global identity sequence prevents a late callback from an older
/// owner or an older still from colliding with a newly armed callback.
@MainActor
final class PlayerOutgoingRouteStillExpiry {
    typealias Sleeper = @MainActor @Sendable (Duration) async -> Bool
    typealias Expiration = @MainActor @Sendable (String, UInt64) -> Void

    private let timeout: Duration
    private let sleeper: Sleeper
    private var tasks: [String: Task<Void, Never>] = [:]
    private var identities: [String: UInt64] = [:]
    private var nextIdentity: UInt64 = 0

    init(
        timeout: Duration = .seconds(8),
        sleeper: @escaping Sleeper = { duration in
            do {
                try await Task.sleep(for: duration)
                return true
            } catch {
                return false
            }
        }
    ) {
        self.timeout = timeout
        self.sleeper = sleeper
    }

    @discardableResult
    func arm(owner: String, _ onExpire: @escaping Expiration) -> UInt64 {
        tasks[owner]?.cancel()
        nextIdentity &+= 1
        let identity = nextIdentity
        identities[owner] = identity
        let timeout = self.timeout
        let sleeper = self.sleeper
        tasks[owner] = Task { @MainActor in
            guard await sleeper(timeout), !Task.isCancelled else { return }
            onExpire(owner, identity)
        }
        return identity
    }

    func isCurrent(owner: String, _ identity: UInt64) -> Bool {
        identities[owner] == identity
    }

    func cancel(owner: String) {
        tasks[owner]?.cancel()
        tasks.removeValue(forKey: owner)
        identities.removeValue(forKey: owner)
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        nextIdentity &+= 1
        identities.removeAll()
    }
}
