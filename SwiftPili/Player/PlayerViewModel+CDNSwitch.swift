import Foundation
import UIKit

/// Backend/load readiness differs from native media-work advanced by a same-load PiP seek.
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

/// Captured before scheduling/awaits; a screen lease alone cannot identify quality/load/media work.
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

    /// upos playurl URLs are signed with a `deadline` (epoch seconds) — past it every mirror 403s the same
    /// bytes, and only a fresh playurl fetch helps.
    private static func url(_ url: URL, movedToHostOf other: URL) -> URL? {
        guard let host = other.host() else { return nil }
        return CDNHostPolicy.replacingAuthority(
            of: url,
            withHost: host,
            scheme: other.scheme
        )
    }

    /// CDN failover that keeps the session: the same signed playurl URL on the next host — no playurl refetch,
    /// no stop(), so danmaku, stats, subtitles, and history reporting all survive and only the input reopens.
    @discardableResult
    func switchCDN(reason: String, resumeOverride: TimeInterval? = nil) async -> CDNSwitchOutcome {
        // The absolute live rule, enforced where the network side effect is: live
        // candidates come straight from upstream and never enter VOD CDN/PCDN
        // trust, mirror rewriting or the ranking.
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
            // Actual-ready is asynchronous; an admitted open keeps its cover.
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

        // Cancel a seek reopen before its async snapshot/open can race this
        // switch. Cancellation is coordination only; no lifecycle/seek state
        // is mutated until this switch has its own current-frame cover.
        reopenSeekTask?.cancel()

        // Capture the freeze frame BEFORE any lifecycle/seek mutation and before async host probing.
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
        // Preserve the existing compositing hop; it is not a pixel guarantee.
        try? await Task.sleep(for: .milliseconds(32))
        guard ownsCDNSwitch(transaction), !Task.isCancelled else {
            refundCDNSwitch(transaction)
            return false
        }

        // `boundary=2` is the counterpart of the `[Recovery] boundary=1` lines:
        // between them every reopen in a capture is attributable to the boundary
        // that authorized it, which is the whole point of there being two.
        PlayerLog.log("[Player] 🔁 CDN switch \(budget.cdnSwitches)/\(RecoveryBudget.maxCDNSwitches) boundary=2 (\(reason))")

        // The capture was the switch admission boundary. Host ranking starts
        // only after a valid visual cover and its compositing turn exist.

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

    /// Nil alone means the existing full-reload fallback is still applicable.
    private func attemptInPlaceCDNSwitch(
        _ transaction: CDNSwitchTransaction, reason: String, resume: TimeInterval
    ) async -> Bool? {
        if transaction.authority.dash, backendKind == .demandPaced,
           resume > DemandDASHRouteResume.minimumPosition {
            if SmartCDNSelector.isEnabled, let failedHost = transaction.authority.videoURL?.host() {
                SmartCDNSelector.shared.reportPlaybackIssue(host: failedHost, reason: reason)
            }
            // The in-place path probes only video then rewrites audio blindly.
            // A covered reload resolves signed candidates for both tracks and
            // applies the same resume evidence and lease fences as initial open.
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
                // We have just blacklisted `failedHost` for starving us; leaving the DASH audio there
                // relocates only half the stream — and not the half that is the clock master.
                let nextAudio: URL? = isDASHMode
                    ? currentDASHAudioURL.flatMap { Self.url($0, movedToHostOf: admittedNext) }
                    : nil
                guard !isDASHMode || currentDASHAudioURL == nil || nextAudio != nil,
                      nextAudio.map({ Self.admittedNetworkURL($0, stage: "cdn-audio-failover") != nil }) ?? true
                else {
                    PlayerLog.log("[CDN] rejected stage=cdn-audio-failover host=invalid reason=malformed_url")
                    // Nothing was opened, so the budget owes nothing — and unlike the owner-changed exits this
                    // one leaves playback running, so a silently spent host costs a real recovery rung later.
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
            // The `resume > 2` cliff in particular was silent, and it routes every recovery in the first 2s of
            // any video (including right after a seek to the start) through a full playurl reload.
            PlayerLog.log(
                "[Player] in-place CDN switch (\(reason)) not attempted: " +
                    "resume=\(String(format: "%.1f", resume)) mode=\(mode) " +
                    "url=\(currentURL == nil ? "nil" : (currentURL.map { Self.urlStillFresh($0) } == true ? "fresh" : "expired")) — full reload"
            )
        }
        return nil
    }

    private func prepareCDNSwitchHandoff(_ transaction: CDNSwitchTransaction, resume: TimeInterval, reason: String) {
        // The swap owns transport; its open cannot settle a lifecycle epoch
        // that did not authorize it.
        relinquishLifecycleAuthority(takenOverBy: "CDN host swap", reason: reason)
        cdnFallbackActive = true
        // The resume includes a pending seek; its watchdog must not reach the
        // replacement layer. Mutate only after source/probe admission.
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        // Pin progress through the replacement's early timestamps. Buffering
        // keeps an outgoing tick from retiring the pin before the open settles.
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
        // The selected DASH video list survives retained-source reopens and
        // is cleared by source teardown, even if helpers or audio are absent.
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
        // Installing this operation's cover is its own expected image change.
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

    /// A user pick or positioning request replaces intent before its queued
    /// load/seek worker can advance backend/session identities.
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
            // A full reload spent its host once admitted even if its API/probe
            // later fails; only pre-admission refusals refund that shared rung.
            activeCDNSwitch?.budgetCommitted = true
        } else {
            retireCDNSwitch()
        }
        return preserves
    }

    /// Call sites capture before the unstructured scheduling hop too: an old
    /// observation must never become a new source's first CDN recovery.
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
            // No host left to try — the error is final after all.
            PlayerLog.log("[Player] no host left for input error (\(error.localizedDescription))")
            self.error = PlaybackFailureMessage.text(for: error)
            self.isBuffering = false
            self.pushNowPlayingPlayback()
            self.acknowledgeLifecycleReadiness(.terminalFailure)
            self.finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
        }
    }

    /// Reuse the loader's interrupted-without-successor feedback. Cancellation
    /// still revokes request admission; this grants no replacement open.
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
