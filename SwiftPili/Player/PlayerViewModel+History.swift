import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Server-side resume point (last_play_time from x/player/wbi/v2) for one video part, honoring the
    /// resumePlayback setting.
    static func serverResumePoint(
        aid: Int,
        cid: Int,
        duration: TimeInterval = 0,
        ownerLease: PlayerOwnerLease? = nil
    ) async -> ServerResumeLookup {
        let handoff = shared.issuePlayerInfoHandoff(
            aid: aid,
            cid: cid,
            ownerLease: ownerLease
        )
        guard PlayerPlaybackPreferences.resumePlayback else {
            shared.clearPlayerInfoHandoff(matching: ownerLease)
            PlayerLog.log("[Player] resume: setting is OFF — starting aid=\(aid) cid=\(cid) from 0")
            return .noHistory
        }
        guard AuthManager.shared.isLoggedIn else {
            shared.clearPlayerInfoHandoff(matching: ownerLease)
            PlayerLog.log("[Player] resume: not logged in — no server history to resume from")
            return .noHistory
        }
        do {
            let info = try await VideoAPI.getPlayerInfo(aid: aid, cid: cid)
            // Park the response only with the exact screen/load/lease token.
            // Ownerless internal reloads cannot consume this one-shot value.
            if let handoff,
               let ownerLease,
               shared.isCurrentOwner(ownerLease),
               shared.playerInfoHandoffPolicy.activeToken == handoff {
                shared.pendingPlayerInfo = PendingPlayerInfo(
                    aid: aid,
                    cid: cid,
                    info: info,
                    handoff: handoff
                )
            }
            // "Watched to the end" is returned AS the answer instead of showing the notice here: every caller
            // runs loadVOD next, whose stop() wipes the notice slot — the toast was shown and destroyed within
            // the same frame, so finished videos restarted silently.
            let lookup = ServerResumeLookup.classify(
                lastPlayTimeMs: info.lastPlayTime,
                duration: duration
            )
            switch lookup {
            case .resume(let t):
                PlayerLog.log("[Player] resume: aid=\(aid) cid=\(cid) → \(String(format: "%.0f", t))s (server history)")
            case .watchedToEnd where info.lastPlayTime == -1:
                PlayerLog.log("[Player] resume: aid=\(aid) cid=\(cid) was watched to the end (-1) — playing from beginning")
            case .watchedToEnd:
                let t = TimeInterval(info.lastPlayTime ?? 0) / 1000
                PlayerLog.log("[Player] resume: aid=\(aid) cid=\(cid) history \(String(format: "%.0f", t))s is at the end of \(String(format: "%.0f", duration))s — playing from beginning")
            case .noHistory, .cancelled:
                PlayerLog.log("[Player] resume: no usable history for aid=\(aid) cid=\(cid) (last_play_time=\(info.lastPlayTime.map(String.init) ?? "nil")ms)")
            }
            return lookup
        } catch {
            shared.clearPlayerInfoHandoff(matching: ownerLease)
            let lookup = ServerResumeLookup.failed(callerIsCancelled: Task.isCancelled)
            if lookup == .cancelled {
                PlayerLog.log("[Player] resume: history lookup cancelled for aid=\(aid) cid=\(cid) — caller aborts its load")
            } else {
                PlayerLog.log("[Player] ⚠️ resume: history lookup failed for aid=\(aid) cid=\(cid): \(error) — starting from 0")
            }
            return lookup
        }
    }

    /// A pass that begins where a completed one ended: explicit replay/loop, or a user seek back from natural
    /// EOF.
    func rearmHistoryReportingAfterCompletion() {
        guard mode.usesOnlineVODServices, completionMarkerReported else { return }
        PlayerLog.log("[Player] progress reporting re-armed after the finished marker")
        startHistoryReporting()
    }

    func startHistoryReporting() {
        historyReportTask?.cancel()
        historyPassIsOpen = true
        lastReportedProgress = -1
        // A new pass owns the server record again — see `completionMarkerReported`.
        completionMarkerReported = false
        historyStartTs = Int(Date().timeIntervalSince1970)
        lastReportClock = CACurrentMediaTime()
        // The account this pass may write to. A switch does not stop playback,
        // and the heartbeat reads cookies at send time — so the mid is captured
        // with the task, not inside `reportHeartbeat`.
        historyReportMid = AuthManager.shared.dedeUserID
        historyReportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.reportHistoryNow()
            }
        }
    }

    /// BiliBili's finished marker: played_time = -1 (what the official players send at the end).
    func reportCompletionNow() {
        guard mode == .vod, let aid = currentAid, let cid = currentCid else { return }
        historyReportTask?.cancel()
        historyReportTask = nil
        lastReportedProgress = -1
        completionMarkerReported = true
        let now = CACurrentMediaTime()
        let realtime = min(60, max(1, Int(now - lastReportClock)))
        lastReportClock = now
        let epid: Int? = if case .pgc(let epId) = currentSource { epId } else { nil }
        let season = pgcSeasonContext
        let startTs = historyStartTs
        let reportMid = historyReportMid
        PlayerLog.log("[Player] progress report: aid=\(aid) cid=\(cid)\(epid.map { " epid=\($0)" } ?? "") progress=-1 (finished)")
        Task {
            guard AuthManager.shared.dedeUserID == reportMid else { return }
            await VideoAPI.reportHeartbeat(
                aid: aid, cid: cid, progress: -1, realtime: realtime,
                startTs: startTs, epid: epid, sid: season?.sid, seasonType: season?.type
            )
        }
    }

    func reportHistoryNow() {
        guard mode == .vod, let aid = currentAid, let cid = currentCid else { return }
        guard historyPassIsOpen else { return }
        // A raw second written after it — the 15s tick that outlived the end edge, or `stop()`'s flush on the
        // way out of a completed video — would overwrite it with ≈ duration and restore the
        // resume-into-the-final-seconds bug the marker exists to prevent.
        guard !completionMarkerReported else { return }
        // Media truth only — wall-driven display must not poison resume.
        let progress = Int(mediaTime)
        // A paused clock doesn't move — don't re-POST the same position
        // every 15s for as long as the screen sits open.
        guard progress != lastReportedProgress else { return }
        lastReportedProgress = progress
        let now = CACurrentMediaTime()
        let realtime = min(60, max(1, Int(now - lastReportClock)))
        lastReportClock = now
        // These POSTs are what make "resume last position" possible on the next open — logged so a broken
        // resume can be traced to either the write (here) or the read (serverResumePoint).
        let epid: Int? = if case .pgc(let epId) = currentSource { epId } else { nil }
        let season = pgcSeasonContext
        let startTs = historyStartTs
        let reportMid = historyReportMid
        PlayerLog.log("[Player] progress report: aid=\(aid) cid=\(cid)\(epid.map { " epid=\($0)" } ?? "")\(season.map { " sid=\($0.sid)" } ?? "") progress=\(progress)s")
        Task {
            guard AuthManager.shared.dedeUserID == reportMid else { return }
            await VideoAPI.reportHeartbeat(
                aid: aid, cid: cid, progress: progress, realtime: realtime,
                startTs: startTs, epid: epid, sid: season?.sid, seasonType: season?.type
            )
            guard AuthManager.shared.dedeUserID == reportMid else { return }
            await VideoAPI.reportHistory(aid: aid, cid: cid, progress: progress, epid: epid)
        }
    }

    func startOfflineProgressPersistence() {
        offlineProgressTask?.cancel()
        lastPersistedOfflineSecond = -1
        offlineProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.persistOfflineProgressNow()
            }
        }
    }

    /// Flush the position and stand the loop down.
    func endOfflineProgressPersistence() {
        persistOfflineProgressNow()
        offlineProgressTask?.cancel()
        offlineProgressTask = nil
    }

    /// Write the offline resume point for the part currently loaded.
    func persistOfflineProgressNow() {
        guard mode == .offline, let asset = offlineAsset else { return }
        let seconds = OfflineResumePolicy.storedPosition(
            position: mediaTime,
            durationSeconds: asset.durationSeconds
        )
        guard seconds != lastPersistedOfflineSecond else { return }
        lastPersistedOfflineSecond = seconds
        OfflineProgressStore.shared.record(
            position: seconds, aid: asset.aid, cid: asset.cid
        )
    }
}

/// Keep a cancelled history lookup distinct from an answer that playback should start at zero.
enum ServerResumeLookup: Equatable, Sendable {
    /// Server history to resume at (always > 5s).
    case resume(TimeInterval)
    /// Start at 0 silently: setting off, logged out, no usable history, or a
    /// genuine lookup failure.
    case noHistory
    /// BiliBili's "watched to the end" (`-1`, or history within the last few
    /// seconds): start at 0 WITH the restart notice.
    case watchedToEnd
    /// The calling task was cancelled before the lookup answered.
    case cancelled

    /// The value `loadVOD(resumeAt:)` has always taken for "watched to the
    /// end" — it raises the restart notice once the player is ready.
    static let watchedToEndSentinel: TimeInterval = -1

    /// What a load does with the lookup.
    enum LoadDecision: Equatable, Sendable {
        /// Stop this load quietly; its activation re-runs it.
        case abort
        /// Load with this `resumeAt` (nil = from 0, sentinel = from 0 + notice).
        case load(resumeAt: TimeInterval?)
    }

    /// `cloudFallbackSeconds` is the Bangumi season-level `last_time`, used
    /// only when the per-cid lookup found nothing — the same rule the season
    /// screen has always applied to a `nil` result.
    func loadDecision(cloudFallbackSeconds: TimeInterval? = nil) -> LoadDecision {
        switch self {
        case .cancelled:
            return .abort
        case .resume(let seconds):
            return .load(resumeAt: seconds)
        case .watchedToEnd:
            return .load(resumeAt: Self.watchedToEndSentinel)
        case .noHistory:
            if let fallback = cloudFallbackSeconds, fallback > 5 {
                return .load(resumeAt: fallback)
            }
            return .load(resumeAt: nil)
        }
    }

    /// Maps x/player/wbi/v2's `last_play_time` (milliseconds) for a part of `duration` seconds (0 = unknown).
    static func classify(lastPlayTimeMs: Int?, duration: TimeInterval) -> ServerResumeLookup {
        guard let ms = lastPlayTimeMs, ms > 5000 else {
            return lastPlayTimeMs == -1 ? .watchedToEnd : .noHistory
        }
        let seconds = TimeInterval(ms) / 1000
        if duration > 10, seconds >= duration - max(15, duration * 0.02) {
            return .watchedToEnd
        }
        return .resume(seconds)
    }

    /// A lookup that threw. See the type comment for why only a cancelled
    /// CALLER is `.cancelled`.
    static func failed(callerIsCancelled: Bool) -> ServerResumeLookup {
        callerIsCancelled ? .cancelled : .noHistory
    }
}
