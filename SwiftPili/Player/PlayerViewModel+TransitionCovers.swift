import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {
    private static let transitionCoverTimeout: Duration = .seconds(8)

    @discardableResult
    func parkOutgoingRouteStill() -> String? {
        releaseDepartedRouteStills()
        let owner = ownerKey
        guard !owner.isEmpty else { return nil }
        guard let frame = backend.currentDisplayedFrameForTransition(),
              frame.size.width > 0,
              frame.size.height > 0 else {
            clearOutgoingRouteStill(owner: owner)
            PlayerLog.log("[Player] outgoing route still capture missed owner=\(owner)")
            return owner
        }
        var stored = outgoingRouteStills
        stored[owner] = frame
        outgoingRouteStills = stored
        routeOwnership.outgoingRouteStillTasks[owner]?.cancel()
        routeOwnership.outgoingRouteStillTasks[owner] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.transitionCoverTimeout)
            guard !Task.isCancelled, let self,
                  self.outgoingRouteStills[owner] != nil else { return }
            self.clearOutgoingRouteStill(owner: owner)
            PlayerLog.log("[Player] outgoing route still expired owner=\(owner)")
        }
        PlayerLog.log(
            "[Player] outgoing route still parked owner=\(owner) " +
                "\(Int(frame.size.width))×\(Int(frame.size.height))"
        )
        return owner
    }

    func outgoingRouteStill(for owner: String) -> UIImage? {
        guard let image = outgoingRouteStills[owner],
              image.size.width > 0,
              image.size.height > 0 else { return nil }
        return image
    }

    func clearOutgoingRouteStill(owner: String) {
        routeOwnership.outgoingRouteStillTasks.removeValue(forKey: owner)?.cancel()
        guard outgoingRouteStills[owner] != nil else { return }
        var stored = outgoingRouteStills
        stored.removeValue(forKey: owner)
        outgoingRouteStills = stored
    }

    func retireDepartedRouteStill(owner: String) {
        guard !owner.isEmpty, !departedRouteStillOwners.contains(owner) else { return }
        departedRouteStillOwners.append(owner)
    }

    func clearAllOutgoingRouteStills() {
        for task in routeOwnership.outgoingRouteStillTasks.values { task.cancel() }
        routeOwnership.outgoingRouteStillTasks.removeAll()
        departedRouteStillOwners.removeAll()
        outgoingRouteStills = [:]
    }

    private func releaseDepartedRouteStills() {
        let owners = departedRouteStillOwners
        guard !owners.isEmpty else { return }
        departedRouteStillOwners.removeAll()
        for owner in owners {
            clearOutgoingRouteStill(owner: owner)
        }
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

    func prepareRecoveryCoverForSuccessorLoad() {
        guard let recoveryCover else { return }
        guard ownsRecoveryCoverAuthority(recoveryCover), isCurrentFreezeFrame(recoveryCover.identity) else {
            clearRecoveryCover(matching: recoveryCover.identity)
            return
        }
        recoveryCover.expectSuccessor(backend)
        freezeFrameExpectedSessionGeneration = nil
    }

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

    func clearFreezeFrame() {
        recoveryCover?.retire()
        recoveryCover = nil
        freezeFrameExpiryTask?.cancel()
        freezeFrameExpiryTask = nil
        freezeFrameIdentity &+= 1
        freezeFrame = nil
        freezeFrameAwaitingFreshProof = false
        freezeFrameExpectedSessionGeneration = nil
        cdnFrameCover = nil
    }

    @discardableResult
    func installFreezeFrame(
        _ frame: UIImage,
        awaitingFreshProof: Bool
    ) -> UInt64 {
        recoveryCover?.retire()
        recoveryCover = nil
        freezeFrameExpiryTask?.cancel()
        freezeFrameExpiryTask = nil
        freezeFrameIdentity &+= 1
        freezeFrame = frame
        freezeFrameAwaitingFreshProof = awaitingFreshProof
        freezeFrameExpectedSessionGeneration = nil
        cdnFrameCover = nil
        let coverIdentity = freezeFrameIdentity
        if !awaitingFreshProof {
            freezeFrameExpiryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.transitionCoverTimeout)
                guard !Task.isCancelled, let self,
                      self.isCurrentFreezeFrame(coverIdentity),
                      self.freezeFrame != nil else { return }
                self.clearFreezeFrame()
                PlayerLog.log("[Player] freeze frame expired cover=\(coverIdentity)")
            }
        }
        return coverIdentity
    }

    func isCurrentFreezeFrame(_ identity: UInt64) -> Bool {
        freezeFrameIdentity == identity
    }
}
