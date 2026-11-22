import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func decoderLabel(codecs: String, hardwareSupported: Bool) -> String {
        if hardwareSupported {
            return String(localized: "VideoToolbox (HW)")
        }
        if codecs.hasPrefix("av01") || codecs.hasPrefix("av1") {
            return String(localized: "Software (dav1d)")
        }
        return String(localized: "Software (FFmpeg)")
    }

    nonisolated static func selectedDASHBootstrapIdentity(
        aid: Int,
        cid: Int,
        source: StreamSource,
        track: MediaTrackKind,
        stream: PlayURLResult.DashInfo.DashStream
    ) -> MediaBootstrapIdentity {
        let sourceIdentity: String
        switch source {
        case .ugc: sourceIdentity = "ugc"
        case .pgc(let epId): sourceIdentity = "pgc:\(epId)"
        }
        let representation = "id:\(stream.id);bandwidth:\(stream.bandwidth);" +
            "codec:\(stream.codecs.utf8.count):\(stream.codecs);" +
            "mime:\(stream.mimeType.utf8.count):\(stream.mimeType)"
        return MediaBootstrapIdentity(
            asset: "\(sourceIdentity):aid:\(aid):cid:\(cid)",
            track: track,
            representation: representation
        )
    }

    static func prepareSelectedDASHBootstrapIdentities(
        for backend: PlayerBackend,
        mode: PlayerMode,
        video: MediaBootstrapIdentity?,
        audio: MediaBootstrapIdentity?
    ) {
        guard let demand = backend as? DemandPacedPlayerBackend else { return }
        demand.prepareBootstrapIdentities(
            video: mode == .vod ? video : nil,
            audio: mode == .vod ? audio : nil
        )
    }

    func loadVOD(
        aid: Int,
        cid: Int,
        bvid: String? = nil,
        quality: Int? = nil,
        source: StreamSource = .ugc,
        resumeAt: TimeInterval? = nil,
        portraitHint: Bool? = nil,
        preservePlayState: Bool = false,
        owner: String? = nil,
        ownerLease: PlayerOwnerLease? = nil,
        startupTraceToken: StartupTrace.Token? = nil,
        requestAdmission: (@MainActor @Sendable () -> Bool)? = nil,
        mediaResetID: UUID? = nil,
        recoveryCoverIdentity: UInt64? = nil,
        cdnSwitchID: UUID? = nil,
        streamRetryID: UUID? = nil
    ) async {
        let loadTask = Task {
            await performLoadVOD(
                aid: aid,
                cid: cid,
                bvid: bvid,
                quality: quality,
                source: source,
                resumeAt: resumeAt,
                portraitHint: portraitHint,
                preservePlayState: preservePlayState,
                owner: owner,
                ownerLease: ownerLease,
                startupTraceToken: startupTraceToken,
                requestAdmission: requestAdmission,
                mediaResetID: mediaResetID,
                recoveryCoverIdentity: recoveryCoverIdentity,
                cdnSwitchID: cdnSwitchID,
                streamRetryID: streamRetryID
            )
        }
        if cdnSwitchID != nil || streamRetryID != nil {
            await withTaskCancellationHandler { await loadTask.value } onCancel: { loadTask.cancel() }
        } else {
            await loadTask.value
        }
    }

    func retireStartupTraceBeforeNonVODLoad(_ targetMode: PlayerMode) {
        guard let token = PlayerStartupTraceScope.tokenToAbortBeforeLoad(
            targetMode: targetMode,
            retainedToken: startupTraceToken
        ) else { return }
        StartupTrace.abort(
            "source-transition-\(String(describing: targetMode))",
            token: token
        )
        startupTraceToken = nil
    }

    func admitsLoadRequest(
        _ admitted: Bool,
        after stage: String,
        token: StartupTrace.Token?
    ) -> Bool {
        guard !admitted else { return true }
        StartupTrace.abort("request-revoked", token: token)
        PlayerLog.log("[Player] loadVOD ended quietly after \(stage) — request withdrawn")
        return false
    }

    static func checkLoadCancellation() throws(BiliError) {
        if Task.isCancelled { throw .network(URLError(.cancelled)) }
    }

    func selectVideoStream(
        from streams: [PlayURLResult.DashInfo.DashStream],
        quality: Int,
        hardwareCapabilities: VideoHardwareCapabilities.Snapshot
    ) -> PlayURLResult.DashInfo.DashStream? {
        let pref = PlayerPlaybackPreferences.preferredCodec
        let hardwareDecodeEnabled = PlayerPlaybackPreferences.hardwareDecodeEnabled
        func pick(_ candidates: [PlayURLResult.DashInfo.DashStream]) -> PlayURLResult.DashInfo.DashStream? {
            if pref != .auto, let match = candidates.first(where: { pref.matches($0.codecs) }) {
                return match
            }
            if hardwareDecodeEnabled,
               let hw = candidates.first(where: { hardwareCapabilities.supports(codecs: $0.codecs) }) {
                return hw
            }
            return candidates.first
        }
        if let s = pick(streams.filter { $0.id == quality }) { return s }
        if let lowerID = streams.filter({ $0.id <= quality }).map(\.id).max(),
           let s = pick(streams.filter { $0.id == lowerID }) {
            return s
        }
        return pick(streams)
    }

    func codecsOffered(
        in streams: [PlayURLResult.DashInfo.DashStream],
        quality: Int
    ) -> [VideoCodecPreference] {
        [.avc, .hevc, .av1].filter { pref in
            streams.contains { $0.id == quality && pref.matches($0.codecs) }
        }
    }

    func switchCodec(_ pref: VideoCodecPreference) async {
        guard mode.usesOnlineVODServices else {
            PlayerLog.log("[Player] codec switch ignored for offline/local playback")
            return
        }
        guard PlayerPlaybackPreferences.preferredCodec != pref else { return }
        retireCDNSwitchForNewIntent()
        PlayerPlaybackPreferences.preferredCodec = pref
        guard let aid = currentAid, let cid = currentCid else { return }
        let savedTime = resumeTargetTime
        let reloadOwnerLease = currentOwnerLease
        resumeAtTime = savedTime > 2 ? savedTime : nil
        await loadVOD(
            aid: aid,
            cid: cid,
            quality: currentQuality,
            source: currentSource,
            preservePlayState: true,
            ownerLease: reloadOwnerLease
        )
    }

    func fetchPlayURL(
        aid: Int,
        cid: Int,
        quality: Int,
        fnval: Int,
        source: StreamSource
    ) async throws(BiliError) -> PlayURLResult {
        switch source {
        case .ugc:
            try await VideoAPI.getPlayURL(aid: aid, cid: cid, quality: quality, fnval: fnval)
        case .pgc(let epId):
            try await PGCAPI.getPlayURL(epId: epId, cid: cid, quality: quality, fnval: fnval)
        }
    }
}

extension PlayerViewModel {

    @discardableResult
    func handOffBackend(to kind: PlayerEngineKind, reason: String) -> Bool {
        guard kind != activeBackendKind || invalidatedBackendResources else { return false }

        let incoming: PlayerBackend
        let reusedInstance: Bool
        if let cached = backendInstances[kind] {
            incoming = cached
            reusedInstance = true
        } else {
            guard let made = PlayerBackendFactory.makeBackend(
                kind: kind,
                continuation: PlayerPlaybackPreferences.playbackContinuationConfiguration
            ) else {
                PlayerLog.diagnostic(
                    "[Player] engine hand-off refused (\(reason)): \(kind.shortLabel) unavailable, " +
                    "staying on \(activeBackendKind.shortLabel)"
                )
                return false
            }
            incoming = made
            backendInstances[kind] = made
            reusedInstance = false
        }
        revokeEqualizerMaintenancePermission()

        let outgoing = activeBackend
        let outgoingKind = activeBackendKind
        outgoing.audioMaintenanceAdmission = nil
        outgoing.setAudioOutputStateChangeHandler(nil)
        nativeAudioRepairAttempt = nil

        relinquishLifecycleAuthority(
            takenOverBy: "engine hand-off → \(kind.shortLabel)",
            reason: reason
        )
        invalidateLifecycleReadiness()
        lifecycleRecovery.invalidate()
        decoderRecoveryAdmission.invalidate()
        nonLifecycleRecoveryTicket = nil

        let outgoingHadPiPLease = outgoing.hasObservedPiPLease
        outgoing.setObservedPiPLeaseChangeHandler(nil)
        outgoing.setPiPTransportEdgeHandler(nil)
        outgoing.setDemandPiPNativeTransitionHandler(nil)
        outgoing.setDemandPiPRestoreRequestHandler(nil)
        outgoing.setDemandPresentationProofHandler(nil)
        outgoing.setDemandPresentationFailureHandler(nil)
        outgoing.setRuntimeFaultHandler(nil)
        outgoing.setStartupTraceToken(nil)
        outgoing.onStateChanged = nil
        outgoing.onTickWithGeneration = nil
        outgoing.onBufferChanged = nil
        outgoing.updateDemandVideoLivenessContext(nil)
        if outgoing.isPiPActive || outgoingHadPiPLease {
            PlayerLog.log("[Player] engine hand-off dismissing PiP on \(outgoingKind.shortLabel)")
            if outgoingKind == .demandPaced {
                outgoing.forceRetireDemandPiP()
            } else {
                outgoing.stopPiP()
            }
        }
        outgoing.stop()

        let continuation = PlayerPlaybackPreferences.playbackContinuationConfiguration
        _ = incoming.applyPlaybackContinuationConfiguration(continuation)
        activeBackend = incoming
        activeBackendKind = kind
        invalidatedBackendResources = false
        incoming.equalizerConfiguration = effectiveEqualizerConfiguration
        syncVideoEnhancementToBackend(incoming)
        setupBackendCallbacks()
        reassertMuteOnActiveBackend()
        if outgoingHadPiPLease {
            handleObservedPiPLeaseChange(false)
        }
        updateDemandVideoLivenessContext()

        advanceGeneration("backendHandOff")
        renderAttachment?.attach(
            hostedVC: incoming.renderViewController,
            generation: playerGeneration
        )
        PlayerLog.log(
            "[Player] 🔀 engine hand-off (\(reason)): " +
            "\(outgoingKind.shortLabel) → \(kind.shortLabel) " +
            "preferred=\(preferredBackendKind.shortLabel) " +
            "generation=\(playerGeneration) " +
            "reused=\(reusedInstance ? 1 : 0)"
        )
        return true
    }

    func handOffUnsupportedDemandLiveSource(_ kind: DemandLiveSourceKind) -> Bool {
        guard mode == .live, activeBackendKind == .demandPaced,
              !terminalOpenFailure, !hasStartedPresenting,
              !PlayerEngineKind.pinsLiveEngine, let url = currentURL,
              handOffBackend(to: .vlc, reason: "live unsupported source \(kind.rawValue)") else {
            return false
        }
        playURL(url)
        return true
    }

    func restorePreferredBackendForLoad(_ reason: String) {
        handOffBackend(to: preferredBackendKind, reason: reason)
    }

    static func prewarmPlaybackEngine() {
        guard PlayerEngineKind.vodPreferred == .vlc else { return }
        VLCPlayerBackend.prewarmPlaybackEngine()
    }
}

enum PlayerLoadAdmissionPolicy {
    static func allows(
        targetMode: PlayerMode,
        requestedOwner: String?,
        currentOwner: String,
        currentMode: PlayerMode,
        requestedLease: PlayerOwnerLease? = nil,
        currentLeaseGeneration: UInt64 = 0
    ) -> Bool {
        if let requestedLease {
            guard requestedLease.matches(
                currentOwner: currentOwner,
                currentGeneration: currentLeaseGeneration
            ) else { return false }
            if let requestedOwner, requestedOwner != requestedLease.owner { return false }
            return true
        }
        if let requestedOwner {
            return !requestedOwner.isEmpty && requestedOwner == currentOwner
        }
        return !currentOwner.isEmpty && currentMode == targetMode
    }
}

enum PlayerTransportControlPolicy {
    static func allowsPlay(afterTerminalOpenFailure: Bool) -> Bool {
        !afterTerminalOpenFailure
    }

    static func allowsSeek(whileUnavailable: Bool) -> Bool {
        !whileUnavailable
    }
}

enum PlayerTeardownReason: Equatable, Sendable {
    case internalReload
    case ownerExit
    case newContentOwnership

    var preservesPresentation: Bool {
        self == .internalReload
    }
}

enum PlayerReloadPresentationPolicy {
    static func reason(
        targetMode: PlayerMode,
        currentMode: PlayerMode,
        sameContent: Bool,
        newOwner: Bool
    ) -> PlayerTeardownReason {
        guard targetMode == currentMode, sameContent, !newOwner else {
            return .newContentOwnership
        }
        return .internalReload
    }
}

enum PlayerDetailReactivationPolicy {
    struct Facts: Equatable, Sendable {
        let targetMatchesLoadedContent: Bool
        let hasLoadedMetadata: Bool
        let screenAid: Int?
        let screenCid: Int?
        let screenReportedFailure: Bool
        let requestedOwner: String
        let retainedLeaseOwner: String?
        let retainedLeaseIsCurrentOwner: Bool
        let targetMode: PlayerMode
        let targetSource: PlayerViewModel.StreamSource
        let playerMode: PlayerMode
        let playerAid: Int?
        let playerCid: Int?
        let playerSource: PlayerViewModel.StreamSource
        let playerHasSource: Bool
        let playerReportedFailure: Bool
    }

    static func isAlreadyLive(_ facts: Facts) -> Bool {
        guard facts.targetMatchesLoadedContent,
              facts.hasLoadedMetadata,
              let screenAid = facts.screenAid,
              let screenCid = facts.screenCid
        else { return false }

        guard let leaseOwner = facts.retainedLeaseOwner,
              leaseOwner == facts.requestedOwner,
              facts.retainedLeaseIsCurrentOwner
        else { return false }

        guard !facts.screenReportedFailure, !facts.playerReportedFailure else {
            return false
        }

        guard facts.playerHasSource,
              let playerAid = facts.playerAid,
              let playerCid = facts.playerCid
        else { return false }

        let sameContent = playerAid == screenAid
            && playerCid == screenCid
            && facts.playerSource == facts.targetSource
        return PlayerReloadPresentationPolicy.reason(
            targetMode: facts.targetMode,
            currentMode: facts.playerMode,
            sameContent: sameContent,
            newOwner: false
        ) == .internalReload
    }
}
