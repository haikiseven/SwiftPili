import AVFoundation
import Foundation
import UIKit

/// The token lives here so `PlayerViewModel`'s nonisolated `deinit` never touches a `@MainActor` property.
final class DanmakuGateObserverToken: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter = .default, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}

extension PlayerViewModel {

    /// Play, pause, and rate changes. Always writes the container clock.
    /// The media tick only calls this when drift exceeds the threshold,
    /// and a pause produces no further ticks.
    func syncDanmakuTransport() {
        settleDanmakuNaturalEndHold()
        guard danmakuCanDoVisibleWork else { return }
        let mediaTime = danmakuTransportTime
        let host = CACurrentMediaTime()
        let next = DanmakuClockSync.transitionTiming(
            previous: danmakuTiming,
            mediaTime: mediaTime,
            rate: Double(playbackRate),
            isPlaying: isPlaying,
            hostTime: host
        )
        if next == danmakuTiming { return }
        let anchorTime = DanmakuClockSync.localTime(under: next, atHostTime: host)
        danmakuSink?.applyTiming(next, mediaTime: anchorTime)
        danmakuTiming = next
    }

    func syncDanmakuTransportIfNeeded(_ mediaTime: TimeInterval) {
        let host = CACurrentMediaTime()
        if let applied = danmakuTiming {
            // A paused container stays pinned at its frozen offset across
            // trailing ticks, segment completions, and preference reloads;
            // explicit seek/realign clears `danmakuTiming` first.
            if !isPlaying, applied.speed == 0 { return }
            guard DanmakuClockSync.needsResync(
                under: applied,
                mediaTime: mediaTime,
                atHostTime: host
            ) else { return }
        }
        syncDanmakuTransport()
    }

    /// Content gone for good — the mode left VOD, or the part was cleared.
    /// Store, identity and screen all go.
    func releaseDanmaku() {
        retireFullscreenDanmakuDraft()
        releaseDanmakuStore()
        danmakuSessionLedger.release()
        danmakuRetentionExpiry?.cancel()
        danmakuRetentionExpiry = nil
        danmakuOpenPosition = nil
    }

    /// Drop the store and the on-screen set, keep the session identity. The
    /// feature switch going off lands here: the stream is still playing, and
    /// switching back on must resume it without waiting for another load.
    func releaseDanmakuStore() {
        danmakuHeldAtNaturalEnd = false
        danmakuStore?.onMetadataChanged = nil
        danmakuStore?.onSpecialLoaded = nil
        danmakuStore?.onSegmentsLoaded = nil
        danmakuStore?.reset(oid: nil)
        danmakuStore = nil
        releaseDanmakuMask()
        danmakuRealignPending = false
        danmakuAdmittedUntil = 0
        danmakuSpecialAdmittedUntil = 0
        danmakuAdmittedIDs.removeAll()
        danmakuRefillVisibleWindow = false
        danmakuTiming = nil
        danmakuSink?.teardown()
    }

    /// Suspend visible work while retaining the bounded same-source session for possible reuse.
    func suspendDanmakuSession(reason: PlayerTeardownReason) {
        if !reason.preservesPresentation { retireFullscreenDanmakuDraft() }
        let wasLive = danmakuSessionLedger.isLive
        danmakuHeldAtNaturalEnd = false
        danmakuSessionLedger.suspend(at: Self.danmakuUptime())
        danmakuStore?.suspend()
        danmakuMaskStore?.suspend()
        danmakuRealignPending = false
        danmakuOpenPosition = nil
        danmakuAdmittedUntil = 0
        danmakuSpecialAdmittedUntil = 0
        danmakuAdmittedIDs.removeAll()
        danmakuRefillVisibleWindow = false
        danmakuTiming = nil
        danmakuSink?.teardown()
        if wasLive, let retained = danmakuSessionLedger.retained {
            PlayerLog.log(
                "[Danmaku] session suspended oid=\(retained.oid) reason=\(reason) "
                    + "kept=\(danmakuStore?.segments.count ?? 0) segments "
                    + "ttl=\(Int(DanmakuSessionLedger.retentionTTL))s"
            )
            armDanmakuRetentionExpiry()
        }
    }

    /// Monotonic seconds, the clock the ledger's TTL and the store's backoff
    /// share: a wall-clock change must not expire or extend either.
    private static func danmakuUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// One timer per suspend. Re-arming replaces the previous one; the fire
    /// asks the ledger, which answers nil for a live session or a retention
    /// still inside its TTL.
    private func armDanmakuRetentionExpiry() {
        danmakuRetentionExpiry?.cancel()
        danmakuRetentionExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DanmakuSessionLedger.retentionTTL))
            guard !Task.isCancelled else { return }
            self?.evictRetainedDanmaku(.expired)
        }
    }

    /// Evict only suspended retention; a live session is never removed by this path.
    private func evictRetainedDanmaku(_ reason: DanmakuSessionLedger.Eviction) {
        guard let dropped = danmakuSessionLedger.evictRetained(reason, at: Self.danmakuUptime()) else {
            return
        }
        danmakuRetentionExpiry?.cancel()
        danmakuRetentionExpiry = nil
        let kept = danmakuStore?.segments.count ?? 0
        releaseDanmakuStore()
        danmakuOpenPosition = nil
        PlayerLog.log(
            "[Danmaku] retained session released oid=\(dropped.oid) reason=\(reason) "
                + "dropped=\(kept) segments"
        )
    }

    /// A new network route makes retryable segment failures eligible again.
    func noteDanmakuNetworkPathChanged(from previous: String, to signature: String) {
        danmakuMaskStore?.resetRetryableFailures()
        guard let store = danmakuStore else { return }
        let reopened = store.resetRetryableFailures()
        guard reopened > 0 else { return }
        PlayerLog.log(
            "[Danmaku] network path changed \(previous) → \(signature): "
                + "reopened \(reopened) failed segments"
        )
    }

    /// That observer is to `DemandPacedPlayerBackend` and exists only on that engine, so the retention
    /// — which exists on both engines — carries its own.
    func installDanmakuMemoryWarningObserver() {
        let token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PlayerViewModel.shared.evictRetainedDanmaku(.memoryPressure)
            }
        }
        danmakuMemoryWarningObserver = DanmakuGateObserverToken(token: token)
    }

    /// The admitted stream open alone decides whether the danmaku session continues, resumes or starts
    /// fresh.
    func admitDanmakuSession(openingAt startAt: TimeInterval) {
        guard mode == .vod, let cid = currentCid else { return }
        let identity = DanmakuSessionIdentity(oid: cid, owner: ownerKey)
        let admission = danmakuSessionLedger.admit(identity, at: Self.danmakuUptime())
        danmakuRetentionExpiry?.cancel()
        danmakuRetentionExpiry = nil
        let previousPosition = danmakuEdgeTime
        danmakuOpenPosition = startAt
        switch admission {
        case .continuing:
            if startAt != previousPosition { danmakuRealignPending = true }
            return
        case .resumed:
            danmakuRealignPending = true
        case .fresh:
            releaseDanmakuStore()
        }
        PlayerLog.log(
            "[Danmaku] session \(admission) oid=\(cid) owner=\(ownerKey.isEmpty ? "-" : ownerKey) "
                + "openAt=\(String(format: "%.1f", startAt))s "
                + "kept=\(danmakuStore?.segments.count ?? 0) segments"
        )
    }

    /// Standard-suite changes only. The enabled bit is the filter: this key is
    /// the only one that can move it. A same-value write does not re-enter the
    /// enable path; it notifies the layout refill instead.
    func installDanmakuGateObserver() {
        danmakuGateEnabled = DanmakuFeatureGate.isEnabled()
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PlayerViewModel.shared.noteDanmakuGateDefaultsChange()
            }
        }
        danmakuGateObserver = DanmakuGateObserverToken(token: token)
    }

    private func noteDanmakuGateDefaultsChange() {
        let enabled = DanmakuFeatureGate.isEnabled()
        guard enabled != danmakuGateEnabled else {
            noteDanmakuLayoutDefaultsChange()
            return
        }
        danmakuGateEnabled = enabled
        if enabled {
            // A live VOD session: one lookback admit, including while paused.
            // No live session (stopped, not yet admitted): nothing happens —
            // the switch re-applies to a session, it never creates one.
            noteDanmakuClock(danmakuEdgeTime)
        } else {
            // The stream keeps playing; only its danmaku goes.
            releaseDanmakuStore()
        }
    }

    /// The host calls this after wiping for a layout change, which refills a paused VOD screen: there is no
    /// media tick to consume that wipe.
    func noteDanmakuLayoutDefaultsChange() {
        guard DanmakuFeatureGate.isEnabled() else { return }
        noteDanmakuClock(danmakuEdgeTime)
    }
}
