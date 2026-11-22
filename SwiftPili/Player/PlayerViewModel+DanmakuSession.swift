import AVFoundation
import Foundation
import UIKit

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
            if !isPlaying, applied.speed == 0 { return }
            guard DanmakuClockSync.needsResync(
                under: applied,
                mediaTime: mediaTime,
                atHostTime: host
            ) else { return }
        }
        syncDanmakuTransport()
    }

    func releaseDanmaku() {
        retireFullscreenDanmakuDraft()
        releaseDanmakuStore()
        danmakuSessionLedger.release()
        danmakuRetentionExpiry?.cancel()
        danmakuRetentionExpiry = nil
        danmakuOpenPosition = nil
    }

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

    private static func danmakuUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func armDanmakuRetentionExpiry() {
        danmakuRetentionExpiry?.cancel()
        danmakuRetentionExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DanmakuSessionLedger.retentionTTL))
            guard !Task.isCancelled else { return }
            self?.evictRetainedDanmaku(.expired)
        }
    }

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
            noteDanmakuClock(danmakuEdgeTime)
        } else {
            releaseDanmakuStore()
        }
    }

    func noteDanmakuLayoutDefaultsChange() {
        guard DanmakuFeatureGate.isEnabled() else { return }
        noteDanmakuClock(danmakuEdgeTime)
    }
}
