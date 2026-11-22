import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

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

    func rearmHistoryReportingAfterCompletion() {
        guard mode.usesOnlineVODServices, completionMarkerReported else { return }
        PlayerLog.log("[Player] progress reporting re-armed after the finished marker")
        startHistoryReporting()
    }

    func startHistoryReporting() {
        historyReportTask?.cancel()
        historyPassIsOpen = true
        lastReportedProgress = -1
        completionMarkerReported = false
        historyStartTs = Int(Date().timeIntervalSince1970)
        lastReportClock = CACurrentMediaTime()
        historyReportMid = AuthManager.shared.dedeUserID
        historyReportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.reportHistoryNow()
            }
        }
    }

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
        guard !completionMarkerReported else { return }
        let progress = Int(mediaTime)
        guard progress != lastReportedProgress else { return }
        lastReportedProgress = progress
        let now = CACurrentMediaTime()
        let realtime = min(60, max(1, Int(now - lastReportClock)))
        lastReportClock = now
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

    func endOfflineProgressPersistence() {
        persistOfflineProgressNow()
        offlineProgressTask?.cancel()
        offlineProgressTask = nil
    }

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

enum ServerResumeLookup: Equatable, Sendable {
    case resume(TimeInterval)
    case noHistory
    case watchedToEnd
    case cancelled

    static let watchedToEndSentinel: TimeInterval = -1

    enum LoadDecision: Equatable, Sendable {
        case abort
        case load(resumeAt: TimeInterval?)
    }

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

    static func failed(callerIsCancelled: Bool) -> ServerResumeLookup {
        callerIsCancelled ? .cancelled : .noHistory
    }
}
