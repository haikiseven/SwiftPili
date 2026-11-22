import UIKit

enum PlayerRecoveryCoverMount {
    case mounted, unavailable
}

@MainActor
final class PlayerRecoveryCover {
    let identity: UInt64
    let recoveryToken: UInt64
    let authority: DecoderRecoveryAdmission.Context
    private weak var attachment: (any PlayerRenderAttachment)?
    private var successorBackendID: ObjectIdentifier?
    private var successorBackendGeneration: UInt64?

    init(identity: UInt64, recoveryToken: UInt64, authority: DecoderRecoveryAdmission.Context) {
        self.identity = identity
        self.recoveryToken = recoveryToken
        self.authority = authority
    }

    @discardableResult
    func mount(_ image: UIImage, on destination: any PlayerRenderAttachment) -> PlayerRecoveryCoverMount {
        if attachment === destination {
            return destination.installRecoveryCover(image, identity: identity)
        }
        attachment?.removeRecoveryCover(identity: identity)
        attachment = nil
        let result = destination.installRecoveryCover(image, identity: identity)
        if case .mounted = result { attachment = destination }
        return result
    }

    func detach(from destination: any PlayerRenderAttachment) {
        guard attachment === destination else { return }
        destination.removeRecoveryCover(identity: identity)
        attachment = nil
    }

    func retire() {
        attachment?.removeRecoveryCover(identity: identity)
        attachment = nil
    }

    func expectSuccessor(_ backend: any PlayerBackend) {
        successorBackendID = ObjectIdentifier(backend)
        successorBackendGeneration = backend.runtimeGeneration
    }

    private func ownsSuccessor(_ backend: any PlayerBackend) -> Bool {
        successorBackendID == ObjectIdentifier(backend)
            && successorBackendGeneration == backend.runtimeGeneration
    }

    func bindReadyActualSession(_ backend: any PlayerBackend) -> UInt64? {
        guard ownsSuccessor(backend), backend.isReadyToPlay else { return nil }
        return backend.demandPresentationSessionGeneration
    }

    @discardableResult
    func consumePresentationSample(
        _ sample: DemandPresentationSample,
        expectedSession: UInt64?,
        backend: any PlayerBackend,
        renderGeneration: Int
    ) -> Bool {
        guard ownsSuccessor(backend),
              expectedSession != nil,
              sample.sessionGeneration == backend.demandPresentationSessionGeneration,
              sample.renderGeneration == renderGeneration,
              sample.rendererReady else { return false }
        retire()
        return true
    }
}

extension PlayerRenderAttachment {
    func installRecoveryCover(_ image: UIImage, identity: UInt64) -> PlayerRecoveryCoverMount { .unavailable }
    func removeRecoveryCover(identity: UInt64) {}
}
