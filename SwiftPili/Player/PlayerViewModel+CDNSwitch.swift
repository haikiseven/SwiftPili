import Foundation
import UIKit

struct CDNFrameCoverPolicy {
    let backendID: ObjectIdentifier
    let loadGeneration: UInt64
    private(set) var readySession: UInt64?

    @MainActor
    init(backend: any PlayerBackend) {
        backendID = ObjectIdentifier(backend)
        loadGeneration = backend.runtimeGeneration
    }

    @MainActor
    mutating func bindReady(_ backend: any PlayerBackend) {
        guard ownsLoad(backend), backend.isReadyToPlay else { return }
        readySession = backend.demandPresentationSessionGeneration
    }

    @MainActor
    func ownsLoad(_ backend: any PlayerBackend) -> Bool {
        backendID == ObjectIdentifier(backend) && loadGeneration == backend.runtimeGeneration
    }

    @MainActor
    func accepts(_ sample: DemandPresentationSample, backend: any PlayerBackend, render: Int) -> Bool {
        ownsLoad(backend) && readySession != nil && sample.rendererReady
            && sample.sessionGeneration == backend.demandPresentationSessionGeneration
            && sample.renderGeneration == render
    }
}

struct CDNSwitchAuthority: Equatable {
    let owner: PlayerOwnerLease?
    let load: Int
    let budget: UUID
    let intent: UInt64
    let mode: PlayerMode
    let aid: Int?
    let cid: Int?
    let source: PlayerViewModel.StreamSource
    let quality: Int
    let backendID: ObjectIdentifier
    let backendLoad: UInt64
    let session: UInt64
    let videoURL: URL?
    let audioURL: URL?
    let dash: Bool
    var cover: UInt64
}

enum CDNSwitchOutcome {
    case submitted
    case refused(CDNSwitchAuthority)
    case superseded
}

@MainActor
final class CDNSwitchTransaction {
    let id = UUID()
    let authority: CDNSwitchAuthority
    var coverIdentity: UInt64?
    var reloadGeneration: Int?
    var submittedOpen = false
    var budgetCharged = true
    var budgetCommitted = false

    init(authority: CDNSwitchAuthority) { self.authority = authority }
}

extension PlayerViewModel {

    // MARK: - CDN switch (in place)

    private static func url(_ url: URL, movedToHostOf other: URL) -> URL? {
        guard let host = other.host() else { return nil }
        return CDNHostPolicy.replacingAuthority(
            of: url,
            withHost: host,
            scheme: other.scheme
        )
    }

    @discardableResult
    func switchCDN(reason: String, resumeOverride: TimeInterval? = nil) async -> CDNSwitchOutcome {
        guard mode.usesOnlineVODServices else {
            PlayerLog.log("[Player] switchCDN(\(reason)) denied — source is not online VOD")
            return .refused(cdnSwitchAuthority())
        }
        guard !streamRecoveryOwnsWork else { return .refused(cdnSwitchAuthority()) }
        guard Self.cdnFallbackEnabled else {
            PlayerLog.log("[Player] switchCDN(\(reason)) denied — automatic CDN fallback is disabled")
            return .refused(cdnSwitchAuthority())
        }
        guard currentOwnerLease != nil else {
            PlayerLog.log("[Player] switchCDN(\(reason)) denied — no current owner lease")
            return .refused(cdnSwitchAuthority())
        }
        guard currentAid != nil, currentCid != nil else {
            PlayerLog.log("[Player] switchCDN(\(reason)) denied — no VOD identity")
            return .refused(cdnSwitchAuthority())
        }
        if let activeCDNSwitch, !ownsCDNSwitch(activeCDNSwitch) { retireCDNSwitch() }
        guard !cdnSwitchInFlight else {
            PlayerLog.log("[Player] switchCDN(\(reason)) skipped — another switch in flight")
            return .superseded
        }
        let transaction = CDNSwitchTransaction(authority: cdnSwitchAuthority())
        guard budget.spendCDNSwitch() else {
            PlayerLog.log("[Player] switchCDN(\(reason)) denied — CDN host budget spent")
            return .refused(cdnSwitchAuthority())
        }
        activeCDNSwitch = transaction
        let submitted = await performCDNSwitch(transaction, reason: reason, resumeOverride: resumeOverride)
        return finishCDNSwitch(transaction, submitted: submitted)
    }

    private func finishCDNSwitch(_ transaction: CDNSwitchTransaction, submitted: Bool) -> CDNSwitchOutcome {
        let retainsAuthority = ownsCDNSwitch(transaction) && !Task.isCancelled
        if activeCDNSwitch === transaction {
            if !transaction.submittedOpen || Task.isCancelled {
                settleCancelledCDNReload(transaction)
                clearCDNSwitchCover(transaction)
            }
            refundCDNSwitch(transaction)
            activeCDNSwitch = nil
        }
        if submitted { return .submitted }
        if transaction.reloadGeneration != nil { return .superseded }
        return retainsAuthority ? .refused(cdnSwitchAuthority()) : .superseded
    }

    private func performCDNSwitch(
        _ transaction: CDNSwitchTransaction, reason: String, resumeOverride: TimeInterval?
    ) async -> Bool {
        guard let aid = transaction.authority.aid, let cid = transaction.authority.cid,
              let requestOwnerLease = transaction.authority.owner else { return false }
        let resume = resumeOverride ?? recoveryPosition

        reopenSeekTask?.cancel()

        let snapshot = await backend.thumbnailAtCurrentTime()
        guard ownsCDNSwitch(transaction), !Task.isCancelled else {
            refundCDNSwitch(transaction)
            return false
        }
        guard let snapshot else {
            refundCDNSwitch(transaction)
            PlayerLog.log("[CDN-switch] switch refused — no current frame to cover pipeline replacement")
            return false
        }
        transaction.coverIdentity = installFreezeFrame(snapshot, awaitingFreshProof: true)
        try? await Task.sleep(for: .milliseconds(32))
        guard ownsCDNSwitch(transaction), !Task.isCancelled else {
            refundCDNSwitch(transaction)
            return false
        }

        PlayerLog.log("[Player] 🔁 CDN switch \(budget.cdnSwitches)/\(RecoveryBudget.maxCDNSwitches) boundary=2 (\(reason))")

        if let inPlace = await attemptInPlaceCDNSwitch(transaction, reason: reason, resume: resume) {
            return inPlace
        }
        guard ownsCDNSwitch(transaction), !Task.isCancelled else {
            refundCDNSwitch(transaction)
            return false
        }
        prepareCDNSwitchHandoff(transaction, resume: resume, reason: reason)
        await loadVOD(
            aid: aid,
            cid: cid,
            quality: transaction.authority.quality,
            source: transaction.authority.source,
            preservePlayState: true,
            ownerLease: requestOwnerLease,
            requestAdmission: { [weak self] in
                !Task.isCancelled && self?.ownsCDNSwitch(transaction) == true
            },
            cdnSwitchID: transaction.id
        )
        return transaction.submittedOpen
    }

    private func attemptInPlaceCDNSwitch(
        _ transaction: CDNSwitchTransaction, reason: String, resume: TimeInterval
    ) async -> Bool? {
        if transaction.authority.dash, backendKind == .demandPaced,
           resume > DemandDASHRouteResume.minimumPosition {
            if SmartCDNSelector.isEnabled, let failedHost = transaction.authority.videoURL?.host() {
                SmartCDNSelector.shared.reportPlaybackIssue(host: failedHost, reason: reason)
            }
            PlayerLog.log("[CDN] Demand DASH resume failover — refreshing both track routes")
            return nil
        }
        if resume > 2, mode == .vod, let current = currentURL,
           let url = Self.admittedNetworkURL(current, stage: "cdn-retry"),
           Self.urlStillFresh(url) {
            let failedHost = CDNHostPolicy.canonicalHost(url.host()) ?? ""
            if SmartCDNSelector.isEnabled, !failedHost.isEmpty {
                SmartCDNSelector.shared.reportPlaybackIssue(host: failedHost, reason: reason)
            }
            let next: URL? = if SmartCDNSelector.isEnabled {
                await smartRankedFallbackURL(from: [url.absoluteString], excluding: failedHost)
            } else {
                await lowestLatencyURL(from: [url.absoluteString], excluding: failedHost)
            }
            guard ownsCDNSwitch(transaction), !Task.isCancelled else {
                refundCDNSwitch(transaction)
                return false
            }
            if let next,
               let admittedNext = Self.admittedNetworkURL(next, stage: "cdn-failover"),
               CDNHostPolicy.canonicalHost(admittedNext.host()) != failedHost {
                let nextAudio: URL? = isDASHMode
                    ? currentDASHAudioURL.flatMap { Self.url($0, movedToHostOf: admittedNext) }
                    : nil
                guard !isDASHMode || currentDASHAudioURL == nil || nextAudio != nil,
                      nextAudio.map({ Self.admittedNetworkURL($0, stage: "cdn-audio-failover") != nil }) ?? true
                else {
                    PlayerLog.log("[CDN] rejected stage=cdn-audio-failover host=invalid reason=malformed_url")
                    refundCDNSwitch(transaction)
                    return false
                }
                let audioMoved = nextAudio?.host() != nil && nextAudio?.host() == admittedNext.host()
                PlayerLog.log("[Player] 🔁 in-place CDN switch (\(reason)): \(CDNHostPolicy.diagnosticHost(failedHost)) → \(CDNHostPolicy.diagnosticHost(admittedNext.host())), resuming at \(String(format: "%.1f", resume))\(audioMoved ? " (audio slave moved too)" : "")")
                prepareCDNSwitchHandoff(transaction, resume: resume, reason: reason)
                stats.videoURL = Self.diagnosticURL(admittedNext)
                if let h = nextAudio?.host() { stats.audioHost = h }
                playURL(admittedNext, audioURL: nextAudio, startAt: resume, cdnSwitchID: transaction.id)
                return transaction.submittedOpen
            }
            PlayerLog.log("[Player] in-place CDN switch (\(reason)): no candidate host — full reload")
        } else {
            PlayerLog.log(
                "[Player] in-place CDN switch (\(reason)) not attempted: " +
                    "resume=\(String(format: "%.1f", resume)) mode=\(mode) " +
                    "url=\(currentURL == nil ? "nil" : (currentURL.map { Self.urlStillFresh($0) } == true ? "fresh" : "expired")) — full reload"
            )
        }
        return nil
    }

    private func prepareCDNSwitchHandoff(_ transaction: CDNSwitchTransaction, resume: TimeInterval, reason: String) {
        relinquishLifecycleAuthority(takenOverBy: "CDN host swap", reason: reason)
        cdnFallbackActive = true
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        let minimumResume = transaction.authority.dash && backendKind == .demandPaced
            ? DemandDASHRouteResume.minimumPosition : 2
        pendingSeekTarget = resume > minimumResume ? resume : nil
        resumeAtTime = pendingSeekTarget
        isBuffering = true
    }

    func hasCDNSwitchAuthority(_ authority: CDNSwitchAuthority) -> Bool {
        cdnSwitchAuthority() == authority
    }

    func cdnSwitchAuthority() -> CDNSwitchAuthority {
        let dash = mode.usesOnlineVODServices && currentURL != nil && !multiConnectionVideoURLs.isEmpty
        return CDNSwitchAuthority(
            owner: currentOwnerLease, load: loadGeneration, budget: recoveryBudgetIdentity,
            intent: cdnSwitchIntentGeneration, mode: mode, aid: currentAid, cid: currentCid, source: currentSource,
            quality: currentQuality, backendID: ObjectIdentifier(backend),
            backendLoad: backend.runtimeGeneration, session: backend.demandPresentationSessionGeneration,
            videoURL: currentURL, audioURL: currentDASHAudioURL, dash: dash,
            cover: currentFreezeFrameIdentity
        )
    }

    func ownsCDNSwitch(_ transaction: CDNSwitchTransaction) -> Bool {
        guard activeCDNSwitch === transaction,
              transaction.authority.budget == recoveryBudgetIdentity,
              transaction.authority.owner == currentOwnerLease,
              transaction.authority.intent == cdnSwitchIntentGeneration,
              transaction.coverIdentity.map(isCurrentFreezeFrame) ?? true else { return false }
        if let reload = transaction.reloadGeneration {
            return loadGeneration == reload && mode == .vod
                && currentAid == transaction.authority.aid && currentCid == transaction.authority.cid
                && currentSource == transaction.authority.source
        }
        var current = cdnSwitchAuthority()
        if transaction.coverIdentity != nil { current.cover = transaction.authority.cover }
        return current == transaction.authority
    }

    func clearCDNSwitchCover(_ transaction: CDNSwitchTransaction) {
        if let identity = transaction.coverIdentity, isCurrentFreezeFrame(identity) { clearFreezeFrame() }
    }

    private func refundCDNSwitch(_ transaction: CDNSwitchTransaction) {
        guard transaction.budgetCharged, !transaction.budgetCommitted,
              transaction.authority.budget == recoveryBudgetIdentity else { return }
        transaction.budgetCharged = false
        budget.refundCDNSwitch()
    }

    func retireCDNSwitchForNewIntent() {
        retireStreamRecovery(reason: "new-intent")
        cdnSwitchIntentGeneration &+= 1
        retireCDNSwitch()
    }

    func retireCDNSwitch() {
        guard let transaction = activeCDNSwitch else { return }
        clearCDNSwitchCover(transaction)
        refundCDNSwitch(transaction)
        activeCDNSwitch = nil
    }

    func preservesCDNSwitchForReload(id: UUID?, reason: PlayerTeardownReason) -> Bool {
        let preserves = reason == .internalReload && id != nil
            && activeCDNSwitch?.id == id && activeCDNSwitch.map(ownsCDNSwitch) == true
        if preserves {
            activeCDNSwitch?.budgetCommitted = true
        } else {
            retireCDNSwitch()
        }
        return preserves
    }

    func scheduleCDNSwitch(reason: String, resumeOverride: TimeInterval? = nil) {
        let authority = cdnSwitchAuthority()
        Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.hasCDNSwitchAuthority(authority) else { return }
            _ = await self.switchCDN(reason: reason, resumeOverride: resumeOverride)
        }
    }

    func resetRecoveryBudget() {
        retireStreamRecovery(reason: "budget-reset")
        retireCDNSwitch()
        recoveryBudgetIdentity = UUID()
        budget = RecoveryBudget()
    }

    func attemptCDNSwitchAfterTransportError(_ error: Error) {
        let switchAuthority = self.cdnSwitchAuthority()
        Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  self.hasCDNSwitchAuthority(switchAuthority) else { return }
            let outcome = await self.switchCDN(reason: "transport error")
            guard case let .refused(refusalAuthority) = outcome,
                  !Task.isCancelled, !self.cdnSwitchInFlight,
                  self.hasCDNSwitchAuthority(refusalAuthority) else { return }
            PlayerLog.log("[Player] no host left for input error (\(error.localizedDescription))")
            self.error = PlaybackFailureMessage.text(for: error)
            self.isBuffering = false
            self.pushNowPlayingPlayback()
            self.acknowledgeLifecycleReadiness(.terminalFailure)
            self.finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
        }
    }

    func settleCancelledCDNReload(_ transaction: CDNSwitchTransaction) {
        guard Task.isCancelled, ownsCDNSwitch(transaction) else { return }
        isBuffering = false
        guard transaction.reloadGeneration != nil, transaction.budgetCommitted,
              !transaction.submittedOpen, currentURL == nil,
              error == nil, unavailability == nil else { return }
        StartupTrace.abort("load-cancelled", token: startupTraceToken)
        error = String(localized: "Loading was interrupted. Tap Retry.")
        PlayerLog.log("[Player] CDN load cancelled after teardown with no successor — surfacing Retry")
    }
}
