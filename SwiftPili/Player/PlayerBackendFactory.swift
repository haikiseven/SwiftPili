import Foundation

@MainActor
enum PlayerBackendFactory {
    static func isAvailable(_ kind: PlayerEngineKind) -> Bool {
        switch kind {
        case .vlc: VLCPlayerBackend.isEngineAvailable
        case .demandPaced: true
        }
    }

    static func makeBackend(
        kind: PlayerEngineKind,
        continuation: PlaybackContinuationConfiguration
    ) -> PlayerBackend? {
        let backend: PlayerBackend
        switch kind {
        case .vlc:
            PlayerLog.log("[Player] backend factory → VLCPlayerBackend (push / legacy)")
            guard let vlc = VLCPlayerBackend() else {
                PlayerLog.diagnostic("[Player] backend factory: libVLC engine unavailable")
                return nil
            }
            backend = vlc
        case .demandPaced:
            PlayerLog.log(
                "[Player] backend factory → DemandPacedPlayerBackend " +
                "(Path A; product default: demand)"
            )
            backend = DemandPacedPlayerBackend(
                session: DemandMediaEngineAssembly.makeDemandBringUp()
            )
        }
        _ = backend.applyPlaybackContinuationConfiguration(continuation)
        return backend
    }
}
