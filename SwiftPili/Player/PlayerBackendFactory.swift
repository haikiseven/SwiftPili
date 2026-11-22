import Foundation

/// Constructs `PlayerBackend` instances for `PlayerViewModel`.
///
/// Demand is the shared player's default in every build configuration.
/// An explicit preference or launch override may select VLC; live capability
/// routing can still hand incompatible input to VLC without changing that
/// preference.
///
/// No longer strictly "the process-wide backend": `PlayerViewModel` caches at
/// most one instance per kind and hands the transport between them when a live
/// room's container is one the selected engine cannot demux
/// (`PlayerViewModel.handOffBackend`). It is still true that only ONE instance
/// is ever active, and that a kind is constructed at most once per process.
@MainActor
enum PlayerBackendFactory {
    /// Whether `kind` can be constructed in this process. Demand always can;
    /// libVLC cannot when `libvlc_new` rejects the app's instance arguments.
    static func isAvailable(_ kind: PlayerEngineKind) -> Bool {
        switch kind {
        case .vlc: VLCPlayerBackend.isEngineAvailable
        case .demandPaced: true
        }
    }

    /// Construct and configure the backend before exposing its render/PiP
    /// surface. Requiring the complete snapshot at this boundary keeps initial
    /// construction aligned with cached hand-offs and Settings changes.
    ///
    /// `nil` only when `isAvailable(kind)` is false.
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
