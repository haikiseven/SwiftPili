import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    private static func danmakuVisibleLookback() -> TimeInterval {
        let fixedLifetime = DanmakuTrackLayout.Metrics(width: 1, laneCount: 1).fixedLifetime
        let scrollLifetime = DanmakuRenderPreferences.load().scrollLifetime
        return max(scrollLifetime, fixedLifetime, danmakuMode7LifetimeCeiling)
    }

    func attachDanmakuSink(_ sink: DanmakuTimelineSink) {
        let fresh = danmakuSink !== sink
        danmakuSink = sink
        danmakuTiming = nil
        if !danmakuCanDoVisibleWork { sink.teardown() }
        syncDanmakuTransport()
        if fresh { pushDanmakuMask() }
        guard fresh || danmakuRefillVisibleWindow else { return }
        if fresh {
            danmakuRefillVisibleWindow = true
            danmakuAdmittedIDs.removeAll()
        }
        guard DanmakuFeatureGate.isEnabled(), mode == .vod, currentCid != nil else { return }
        noteDanmakuClock(danmakuEdgeTime)
    }

    func echoDanmaku(_ item: DanmakuElem) {
        var own = item
        own.isSelfSent = true
        danmakuStore?.insertSelfSent(own)
        settleDanmakuNaturalEndHold()
        guard danmakuCanDoVisibleWork else { return }
        danmakuSink?.reclaimFinished(at: danmakuTransportTime)
        admitDanmakuItems([own], at: danmakuTransportTime, replacingServerCopy: true)
    }

    func detachDanmakuSink(_ sink: DanmakuTimelineSink) {
        guard danmakuSink === sink else { return }
        suspendDanmakuVisibleWork()
        danmakuSink = nil
    }

    static func danmakuVisibleWorkAdmits(_ state: PlaybackTerminalState) -> Bool {
        switch state {
        case .active, .ended: true
        case .terminalFailure, .stopped: false
        }
    }

    func noteDanmakuApplicationActivityChanged(isActive: Bool) {
        danmakuApplicationActive = isActive
        guard isActive else {
            suspendDanmakuVisibleWork()
            return
        }
        guard danmakuCanDoVisibleWork else { return }
        noteDanmakuClock(danmakuTransportTime)
    }

    func noteDanmakuTerminalPlaybackEdge() {
        settleDanmakuNaturalEndHold()
        if !danmakuCanDoVisibleWork { suspendDanmakuVisibleWork() }
    }

    func settleDanmakuNaturalEndHold() {
        if currentPlaybackTerminalState.isNaturalEnd {
            danmakuHeldAtNaturalEnd = true
        } else if danmakuHeldAtNaturalEnd {
            danmakuHeldAtNaturalEnd = false
            suspendDanmakuVisibleWork()
        }
    }

    func suspendDanmakuVisibleWork() {
        guard !danmakuVisibleWorkSuspended else { return }
        danmakuVisibleWorkSuspended = true
        danmakuStore?.suspend()
        danmakuMaskStore?.suspend()
        danmakuSink?.teardown()
        danmakuAdmittedIDs.removeAll()
        danmakuRealignPending = true
        danmakuTiming = nil
    }

    func noteDanmakuVisibleSetWiped() {
        danmakuRefillVisibleWindow = true
        danmakuAdmittedIDs.removeAll()
    }

    func noteDanmakuMediaTick(_ currentTime: TimeInterval) {
        danmakuOpenPosition = nil
        noteDanmakuClock(currentTime)
    }

    func noteDanmakuSeekSettled(at position: TimeInterval) {
        guard position.isFinite, position >= 0 else { return }
        danmakuOpenPosition = position
        danmakuRealignPending = true
        noteDanmakuClock(position)
    }

    func noteDanmakuClock(_ mediaTime: TimeInterval) {
        guard DanmakuFeatureGate.isEnabled(), mode == .vod else {
            if danmakuStore != nil {
                releaseDanmakuStore()
            }
            return
        }
        settleDanmakuNaturalEndHold()
        guard danmakuCanDoVisibleWork else {
            suspendDanmakuVisibleWork()
            return
        }
        danmakuVisibleWorkSuspended = false
        guard let session = danmakuSessionLedger.liveSession(for: currentCid) else { return }
        let store: DanmakuSegmentStore
        if let existing = danmakuStore {
            store = existing
        } else {
            store = DanmakuSegmentStore()
            store.reset(oid: session.oid)
            danmakuStore = store
            wireDanmakuMetadataCallbacks(store)
            danmakuRealignPending = true
        }
        var alignedPart = false
        if danmakuRealignPending {
            danmakuRealignPending = false
            danmakuAdmittedUntil = mediaTime - Self.danmakuVisibleLookback()
            danmakuSpecialAdmittedUntil = danmakuAdmittedUntil
            danmakuAdmittedIDs.removeAll()
            danmakuTiming = nil
            danmakuRefillVisibleWindow = false
            danmakuSink?.seeked(to: mediaTime)
            alignedPart = true
            pushDanmakuMask()
        }
        store.advance(to: mediaTime, duration: duration)
        advanceDanmakuMask(oid: session.oid, mediaTime: mediaTime)
        if !alignedPart, mediaTime + 1 < danmakuAdmittedUntil {
            danmakuAdmittedUntil = mediaTime - Self.danmakuVisibleLookback()
            danmakuSpecialAdmittedUntil = danmakuAdmittedUntil
            danmakuAdmittedIDs.removeAll()
            danmakuTiming = nil
            danmakuRefillVisibleWindow = false
            danmakuSink?.seeked(to: mediaTime)
        }
        if danmakuRefillVisibleWindow {
            danmakuAdmittedUntil = mediaTime - Self.danmakuVisibleLookback()
            danmakuSpecialAdmittedUntil = danmakuAdmittedUntil
            danmakuRefillVisibleWindow = false
        }
        danmakuSink?.reclaimFinished(at: mediaTime)
        let from = danmakuAdmittedUntil
        let end = store.admitCursor(from: from, to: mediaTime)
        admitVisibleDanmaku(store, from: from, to: end, at: mediaTime)
        danmakuAdmittedUntil = end
        syncDanmakuTransportIfNeeded(mediaTime)
    }

    private func admitVisibleDanmaku(
        _ store: DanmakuSegmentStore, from: TimeInterval, to resolved: TimeInterval, at mediaTime: TimeInterval
    ) {
        let regular = store.elements(from: from, to: resolved)
        let special = store.specialElements(from: danmakuSpecialAdmittedUntil, to: mediaTime)
        danmakuSpecialAdmittedUntil = mediaTime
        let own = store.selfSent.filter {
            $0.progress >= mediaTime - Self.danmakuVisibleLookback() && $0.progress <= mediaTime
        }
        let ordered = (regular + special + own).sorted { $0.progress < $1.progress }
        admitDanmakuItems(ordered, at: mediaTime, replacingServerCopy: true)
    }

    private func wireDanmakuMetadataCallbacks(_ store: DanmakuSegmentStore) {
        store.onSegmentsLoaded = { [weak self, weak store] in
            guard let self, let store, self.danmakuStore === store,
                  self.danmakuSessionLedger.liveSession(for: self.currentCid)?.oid == store.oid,
                  self.danmakuCanDoVisibleWork else { return }
            let position = self.pausedPinnedDanmakuTime ?? self.danmakuTransportTime
            self.danmakuAdmittedUntil = position - Self.danmakuVisibleLookback()
            self.noteDanmakuClock(position)
        }
        store.onMetadataChanged = { [weak self, weak store] in
            guard let self, let store, self.danmakuStore === store,
                  self.danmakuSessionLedger.liveSession(for: self.currentCid)?.oid == store.oid else { return }
            if store.isServerClosed {
                self.suspendDanmakuVisibleWork()
                self.releaseDanmakuMask()
                return
            }
            guard self.danmakuCanDoVisibleWork else { return }
            self.danmakuRealignPending = true
            self.noteDanmakuClock(self.pausedPinnedDanmakuTime ?? self.danmakuTransportTime)
        }
        store.onSpecialLoaded = { [weak self, weak store] in
            guard let self, let store, self.danmakuStore === store,
                  self.danmakuSessionLedger.liveSession(for: self.currentCid)?.oid == store.oid,
                  self.danmakuCanDoVisibleWork else { return }
            let position = self.pausedPinnedDanmakuTime ?? self.danmakuTransportTime
            self.danmakuSpecialAdmittedUntil = position - Self.danmakuVisibleLookback()
            self.noteDanmakuClock(position)
        }
    }

    private var pausedPinnedDanmakuTime: TimeInterval? {
        guard !isPlaying, danmakuOpenPosition == nil,
              let timing = danmakuTiming, timing.speed == 0 else { return nil }
        return timing.timeOffset
    }

    private func admitDanmakuItems(
        _ items: [DanmakuElem], at mediaTime: TimeInterval, replacingServerCopy: Bool = false
    ) {
        let oldestVisible = mediaTime - Self.danmakuVisibleLookback()
        danmakuAdmittedIDs = danmakuAdmittedIDs.filter { $0.value.progress >= oldestVisible }
        let unique = items.filter { item in
            guard let key = item.identityKey else { return true }
            if let admitted = danmakuAdmittedIDs[key] {
                guard replacingServerCopy, item.isSelfSent, !admitted.isSelfSent else { return false }
            }
            danmakuAdmittedIDs[key] = DanmakuVisibleIdentity(progress: item.progress, isSelfSent: item.isSelfSent)
            return true
        }
        if !unique.isEmpty { danmakuSink?.admit(unique, laneHeight: 28) }
    }
}

extension PlayerViewModel {

    // MARK: - Person mask

    func noteDanmakuMaskSource(_ info: DanmakuMaskInfo?, cid: Int) {
        guard mode == .vod else { return }
        if let url = info?.maskURL {
            danmakuMaskSource = (cid, url)
            PlayerLog.log("[DanmakuMask] cid=\(cid) source fps=\(info?.fps.map(String.init) ?? "-")")
        } else if danmakuMaskSource?.cid == cid {
            danmakuMaskSource = nil
        }
        guard DanmakuFeatureGate.isEnabled(),
              let session = danmakuSessionLedger.liveSession(for: currentCid),
              session.oid == cid else { return }
        advanceDanmakuMask(oid: cid, mediaTime: danmakuEdgeTime)
    }

    private func advanceDanmakuMask(oid: Int, mediaTime: TimeInterval) {
        guard danmakuCanDoVisibleWork else { return }
        guard DanmakuRenderPreferences.smartMaskEnabled(),
              let source = danmakuMaskSource, source.cid == oid else {
            if danmakuMaskStore != nil { releaseDanmakuMask() }
            return
        }
        let store: DanmakuMaskStore
        if let existing = danmakuMaskStore, existing.cid == oid, existing.url == source.url {
            store = existing
        } else {
            releaseDanmakuMask()
            store = DanmakuMaskStore(cid: oid, url: source.url)
            store.onChange = { [weak self] in self?.pushDanmakuMask() }
            danmakuMaskStore = store
        }
        store.advance(to: mediaTime)
    }

    private func pushDanmakuMask() {
        guard danmakuCanDoVisibleWork else { return }
        guard let store = danmakuMaskStore else { return }
        danmakuSink?.syncMask(store.segments)
    }

    func releaseDanmakuMask() {
        danmakuMaskStore?.suspend()
        danmakuMaskStore?.onChange = nil
        danmakuMaskStore = nil
        danmakuSink?.clearMask()
    }
}
