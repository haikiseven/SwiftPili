import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func issuePlayerInfoHandoff(
        aid: Int,
        cid: Int,
        ownerLease: PlayerOwnerLease?
    ) -> PlayerInfoHandoffToken? {
        clearPlayerInfoHandoff()
        guard let ownerLease else { return nil }
        return playerInfoHandoffPolicy.issue(
            aid: aid,
            cid: cid,
            owner: ownerLease.owner,
            ownerLeaseGeneration: ownerLease.generation
        )
    }

    func takePlayerInfoHandoff(
        aid: Int,
        cid: Int,
        owner: String?,
        ownerLease: PlayerOwnerLease?
    ) -> PlayerV2Info? {
        guard let pending = pendingPlayerInfo else { return nil }
        guard let owner, let ownerLease else {
            clearPlayerInfoHandoff(matching: currentOwnerLease)
            return nil
        }
        let consumed = playerInfoHandoffPolicy.consume(
            pending.handoff,
            aid: aid,
            cid: cid,
            currentOwner: owner,
            currentOwnerLeaseGeneration: ownerLease.generation,
            isScreenLoad: true
        )
        guard consumed else {
            clearPlayerInfoHandoff(matching: ownerLease)
            return nil
        }
        pendingPlayerInfo = nil
        return pending.info
    }

    func clearPlayerInfoHandoff(matching lease: PlayerOwnerLease? = nil) {
        guard let pending = pendingPlayerInfo else {
            if let lease,
               let active = playerInfoHandoffPolicy.activeToken,
               (active.owner != lease.owner
                   || active.ownerLeaseGeneration != lease.generation) {
                return
            }
            playerInfoHandoffPolicy.invalidate()
            return
        }
        if let lease,
           (pending.handoff.owner != lease.owner
               || pending.handoff.ownerLeaseGeneration != lease.generation) {
            return
        }
        pendingPlayerInfo = nil
        playerInfoHandoffPolicy.invalidate()
    }

    func loadSubtitleList(
        aid: Int,
        cid: Int,
        generation: Int,
        ownerLease: PlayerOwnerLease?,
        preloadedInfo: PlayerV2Info?
    ) async {
        guard generation == loadGeneration,
              ownerLease.map({ isCurrentOwner($0) }) ?? true else { return }
        let info: PlayerV2Info
        if let preloadedInfo {
            info = preloadedInfo
        } else if let fetched = try? await VideoAPI.getPlayerInfo(aid: aid, cid: cid) {
            info = fetched
        } else {
            return
        }
        guard generation == loadGeneration,
              ownerLease.map({ isCurrentOwner($0) }) ?? true else { return }
        availableSubtitles = info.subtitle?.subtitles ?? []
        noteDanmakuMaskSource(info.dmMask, cid: cid)
        if let ownerLease {
            let frames = PlayerAmbientStoryboardFrame.admitted(info.viewPoints)
            setAmbientStoryboard(
                frames,
                ownerLease: ownerLease,
                loadGeneration: generation
            )
        }
        if !availableSubtitles.isEmpty {
            PlayerLog.log("[Player] CC subtitles: \(availableSubtitles.map { $0.lanDoc ?? $0.lan ?? "?" }.joined(separator: ", "))")
        }
    }

    func selectSubtitle(_ item: PlayerV2Info.SubtitleBox.SubtitleItem?) async {
        subtitleSelectionGeneration &+= 1
        let selectionGen = subtitleSelectionGeneration
        let streamGen = loadGeneration
        let lease = currentOwnerLease
        guard let item, var urlString = item.subtitleUrl else {
            activeSubtitleLan = nil
            subtitleCues = []
            subtitleText = nil
            return
        }
        if urlString.hasPrefix("//") { urlString = "https:" + urlString }
        guard let url = URL(string: urlString) else { return }
        PlayerLog.log("[Player] selectSubtitle(\(item.lan ?? "?")): playing=\(isPlaying) t=\(String(format: "%.1f", mediaTime))")
        activeSubtitleLan = item.lan
        subtitleCues = []
        subtitleText = nil
        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
            let (data, _) = try await URLSession.shared.data(for: request)
            struct SubtitleFile: Decodable {
                struct Cue: Decodable {
                    let from: Double?
                    let to: Double?
                    let content: String?
                }

                let body: [Cue]?
            }
            let parsed = try JSONDecoder().decode(SubtitleFile.self, from: data)
            guard !Task.isCancelled,
                  subtitleSelectionGeneration == selectionGen,
                  loadGeneration == streamGen,
                  lease == nil || currentOwnerLease == lease else {
                return
            }
            subtitleCues = (parsed.body ?? []).compactMap { cue in
                guard let from = cue.from, let to = cue.to, let content = cue.content else { return nil }
                return SubtitleCue(from: from, to: to, content: content)
            }
            updateSubtitle(at: mediaTime)
            PlayerLog.log("[Player] subtitle \(item.lan ?? "?") loaded: \(subtitleCues.count) cues")
        } catch {
            guard subtitleSelectionGeneration == selectionGen,
                  loadGeneration == streamGen,
                  lease == nil || currentOwnerLease == lease else {
                return
            }
            PlayerLog.log("[Player] subtitle load failed: \(error)")
            activeSubtitleLan = nil
            subtitleCues = []
            subtitleText = nil
        }
    }

    func updateSubtitle(at time: TimeInterval) {
        guard !subtitleCues.isEmpty else { return }
        let text: String?
        switch subtitleCueTimeline?.search(at: time, cues: subtitleCues) {
        case .match(let content):
            text = content
        case .noMatch:
            text = nil
        case .unavailable, nil:
            text = subtitleCues.first(where: { time >= $0.from && time <= $0.to })?.content
        }
        if text != subtitleText {
            subtitleText = text
        }
    }
}
