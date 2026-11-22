import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// `[now - lookback, now)` for a fresh layer, a seek, or a wiped visible set.
    /// Read at refill time: scroll lifetime is the current preference, and fixed
    /// lifetime is whatever layout metrics already expose (4s unless that changes).
    private static func danmakuVisibleLookback() -> TimeInterval {
        let fixedLifetime = DanmakuTrackLayout.Metrics(width: 1, laneCount: 1).fixedLifetime
        let scrollLifetime = DanmakuRenderPreferences.load().scrollLifetime
        return max(scrollLifetime, fixedLifetime, danmakuMode7LifetimeCeiling)
    }

    /// The new sink becomes the media clock immediately.
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
        // The clock's failure path releases the store. A handoff must not.
        guard DanmakuFeatureGate.isEnabled(), mode == .vod, currentCid != nil else { return }
        noteDanmakuClock(danmakuEdgeTime)
    }

    /// The renderer frames it, never drops it for a full screen, and ignores the sender's own kind switches and
    /// block words for it.
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
        // Invalidate queued raster jobs while this is still the attached
        // sink, then cancel requests without releasing data/session identity.
        suspendDanmakuVisibleWork()
        danmakuSink = nil
    }

    /// Whether a playback terminal state still has a picture worth annotating.
    static func danmakuVisibleWorkAdmits(_ state: PlaybackTerminalState) -> Bool {
        switch state {
        case .active, .ended: true
        case .terminalFailure, .stopped: false
        }
    }

    /// Visibility is distinct from session lifetime: background audio/PiP can
    /// keep playing, while danmaku downloads and queued renders remain inert.
    func noteDanmakuApplicationActivityChanged(isActive: Bool) {
        danmakuApplicationActive = isActive
        guard isActive else {
            suspendDanmakuVisibleWork()
            return
        }
        guard danmakuCanDoVisibleWork else { return }
        noteDanmakuClock(danmakuTransportTime)
    }

    /// Stopped/failed playback (or a natural end with nothing visible to hold) suspends as before.
    func noteDanmakuTerminalPlaybackEdge() {
        settleDanmakuNaturalEndHold()
        if !danmakuCanDoVisibleWork { suspendDanmakuVisibleWork() }
    }

    /// Hold visible bullets at natural end and clear them before a replay rewinds their clock.
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

    /// The renderer dropped every on-screen bullet (bounds or lane count changed).
    /// Consumed once, on the next clock edge. A no-op resize must not call this.
    func noteDanmakuVisibleSetWiped() {
        danmakuRefillVisibleWindow = true
        danmakuAdmittedIDs.removeAll()
    }

    /// The media tick's edge. The first tick after an admission is the first
    /// real clock reading of the new stream, so the open-position stand-in
    /// retires here and every later non-tick edge reads `mediaTime` again.
    func noteDanmakuMediaTick(_ currentTime: TimeInterval) {
        danmakuOpenPosition = nil
        noteDanmakuClock(currentTime)
    }

    /// Use admitted seek settlement to realign visible work without manufacturing a media-clock sample.
    func noteDanmakuSeekSettled(at position: TimeInterval) {
        guard position.isFinite, position >= 0 else { return }
        danmakuOpenPosition = position
        danmakuRealignPending = true
        noteDanmakuClock(position)
    }

    /// Advance the admitted timeline without skipping pending segments or treating ordinary sample gaps as
    /// seeks.
    func noteDanmakuClock(_ mediaTime: TimeInterval) {
        guard DanmakuFeatureGate.isEnabled(), mode == .vod else {
            // Switch off (or a mode that slipped past its didSet): drop the
            // store, keep the session identity — turning the switch back on
            // mid-stream must find the live session and resume on this edge.
            if danmakuStore != nil {
                releaseDanmakuStore()
            }
            return
        }
        settleDanmakuNaturalEndHold()
        // Danmaku is a visible VOD overlay. Keep the retained session intact
        // while backgrounded, but do not advance its window or submit render
        // work when there is no foreground sink to display it.
        guard danmakuCanDoVisibleWork else {
            suspendDanmakuVisibleWork()
            return
        }
        danmakuVisibleWorkSuspended = false
        // Only an admitted, live stream may create, fetch or admit.
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
            // Half-open `[cursor, now)`: parking the cursor ON now admits nothing.
            danmakuAdmittedUntil = mediaTime - Self.danmakuVisibleLookback()
            danmakuSpecialAdmittedUntil = danmakuAdmittedUntil
            danmakuAdmittedIDs.removeAll()
            danmakuTiming = nil
            danmakuRefillVisibleWindow = false
            danmakuSink?.seeked(to: mediaTime)
            alignedPart = true
            // A realign follows a teardown (resumed session, new store), which
            // cleared the renderer's mask; whatever the mask store kept goes back.
            pushDanmakuMask()
        }
        store.advance(to: mediaTime, duration: duration)
        advanceDanmakuMask(oid: session.oid, mediaTime: mediaTime)
        // Preserve the existing backward fallback for unsolicited rewinds.
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
        // Advance the renderer's expiry clock BEFORE admitting: a lookback
        // batch may contain bullets that already ended at this exact edge.
        danmakuSink?.reclaimFinished(at: mediaTime)
        let from = danmakuAdmittedUntil
        // `elements` only returns what is loaded; moving the cursor to `to` would skip the hole once that
        // segment arrives.
        let end = store.admitCursor(from: from, to: mediaTime)
        admitVisibleDanmaku(store, from: from, to: end, at: mediaTime)
        // Advancing only on a non-empty batch left the cursor parked at the start of a failed or empty
        // stretch, so a retry that succeeded later would have admitted that whole stretch at once — stale
        // bullets the clock passed long ago.
        danmakuAdmittedUntil = end
        syncDanmakuTransportIfNeeded(mediaTime)
    }

    private func admitVisibleDanmaku(
        _ store: DanmakuSegmentStore, from: TimeInterval, to resolved: TimeInterval, at mediaTime: TimeInterval
    ) {
        let regular = store.elements(from: from, to: resolved)
        let special = store.specialElements(from: danmakuSpecialAdmittedUntil, to: mediaTime)
        danmakuSpecialAdmittedUntil = mediaTime
        // A completed background post can land exactly at this paused edge.
        // Own echoes are explicitly inclusive; ordinary cursors stay half-open.
        let own = store.selfSent.filter {
            $0.progress >= mediaTime - Self.danmakuVisibleLookback() && $0.progress <= mediaTime
        }
        // One clock edge has one ordered admission. An earlier special bullet
        // must claim its lane before a later regular bullet from the same edge.
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
            // Refill only the currently visible package window, even paused.
            // Existing regular bullets retain their layers and cursor.
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

    // MARK: - Person mask (Phase C)

    /// Records where this cid's person mask lives, or that it has none. A
    /// live session for that cid picks it up on this edge, so the mask does
    /// not wait for the next media tick (a paused player sends none).
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

    /// The mask store follows the danmaku session: it exists only for a live
    /// session whose cid has a mask and while Smart Anti-Occlusion is on, and
    /// otherwise it — and the renderer's mask — goes.
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
