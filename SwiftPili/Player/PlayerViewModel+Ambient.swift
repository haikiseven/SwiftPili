import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    private func projectedAmbientSource(at time: TimeInterval) -> PlayerAmbientSource? {
        let timelineBelongsToCurrentOwner = ambientStoryboardOwnerLease.map {
            $0.matches(
                currentOwner: ownerKey,
                currentGeneration: ownerLeaseGeneration
            )
        } == true && ambientStoryboardContent == ambientStoryboardRequest?.content
        let chapterOrCover = timelineBelongsToCurrentOwner ? PlayerAmbientPolicy.sourceURL(
            at: time,
            storyboard: ambientStoryboard,
            fallback: ambientCoverURL
        ) : ambientCoverURL
        if let content = ambientStoryboardRequest?.content,
           let artwork = ambientStoryboardLoader.artwork(at: time, matching: content) {
            return PlayerAmbientSource(artwork: artwork, fallbackCover: chapterOrCover)
        }
        return chapterOrCover.map {
            PlayerAmbientSource(artwork: PlayerAmbientArtwork(url: $0), fallbackCover: ambientCoverURL)
        }
    }

    func isAmbientVideoLoaded(for ownerLease: PlayerOwnerLease) -> Bool {
        isCurrentOwner(ownerLease) && ambientVideoLoadedOwner == ownerLease
    }

    func markAmbientVideoLoaded() {
        guard let lease = currentOwnerLease, !terminalOpenFailure else { return }
        guard ambientVideoLoadedOwner != lease else { return }
        ambientVideoLoadedOwner = lease
        reconcileAmbientStoryboard()
        refreshAmbientSelection()
        sampleAmbientLiveFrameIfNeeded(at: CACurrentMediaTime(), force: true)
    }

    func admitsAmbientStoryboardContent(_ request: PlayerAmbientStoryboardLoader.Request) -> Bool {
        ambientModeEnabled && mode == .vod && currentURL?.isFileURL != true
            && ambientVideoLoadedOwner == request.content.owner
            && ambientStoryboardRequest == request && request.loadGeneration == loadGeneration
            && request.content.aid == currentAid && request.content.cid == currentCid
            && isCurrentOwner(request.content.owner)
    }

    func admitsAmbientStoryboard(_ request: PlayerAmbientStoryboardLoader.Request) -> Bool {
        admitsAmbientStoryboardContent(request)
            && UIApplication.shared.applicationState == .active
            && ambientSystemSurfaceAllowsWork
    }

    func reconcileAmbientStoryboard(allowWork: Bool = true) {
        let request = ambientStoryboardRequest
        let access = ExperimentalSettingsPolicy.captureAccess(.ambient)
        let eligible = allowWork && access != nil && request.map({ admitsAmbientStoryboard($0) }) == true
        ambientStoryboardLoader.reconcile(
            request: request, access: access, eligible: eligible,
            isCurrent: { [weak self] in
                guard let self, let request else { return false }
                return self.admitsAmbientStoryboard(request)
            },
            didPublish: { [weak self] in self?.refreshAmbientSelection() }
        )
        refreshAmbientSelection()
    }

    func refreshAmbientSelection() {
        guard ambientStoryboardLoader.isEligible, let request = ambientStoryboardRequest,
              admitsAmbientStoryboard(request) else { return }
        if ambientSelectionContent != request.content {
            ambientSelectionContent = request.content
            ambientSelectionSource = ambientCoverURL.map {
                PlayerAmbientSource(artwork: PlayerAmbientArtwork(url: $0), fallbackCover: ambientCoverURL)
            }
        }
        guard !isSeekInFlight, pendingSeekTarget == nil, resumeAtTime == nil else { return }
        let time = settledSeekDisplayTime ?? ambientSelectionMediaTime ?? mediaTime
        let source = projectedAmbientSource(at: time)
        if ambientSelectionSource != source { ambientSelectionSource = source }
    }

    func retireAmbientSelection(keepingArtwork: Bool = false) {
        guard !keepingArtwork else { return }
        ambientVideoLoadedOwner = nil
        ambientSelectionContent = nil
        ambientSelectionSource = nil
        ambientLiveImage = nil
        lastAmbientLiveSampleWall = 0
        ambientStoryboard = []
        ambientStoryboardOwnerLease = nil
        ambientStoryboardLoadGeneration = nil
        ambientStoryboardContent = nil
        ambientSelectionMediaTime = nil
    }

    func sampleAmbientLiveFrameIfNeeded(at now: TimeInterval, force: Bool = false) {
        guard let lease = currentOwnerLease,
              ambientVideoLoadedOwner == lease,
              ambientModeEnabled,
              ExperimentalSettingsPolicy.isAllowed(.ambient),
              UIApplication.shared.applicationState == .active,
              ambientSystemSurfaceAllowsWork,
              !isSeekInFlight,
              pendingSeekTarget == nil,
              resumeAtTime == nil else {
            return
        }
        guard force || (isPlaying && !isBuffering && now - lastAmbientLiveSampleWall >= 0.12) else {
            return
        }
        guard let image = backend.currentAmbientSampleImage(targetSize: PlayerAmbientPolicy.analysisBox) else {
            return
        }
        lastAmbientLiveSampleWall = now
        ambientLiveImage = image
    }

    func setAmbientCoverURL(_ url: String?, ownerLease: PlayerOwnerLease) {
        guard isCurrentOwner(ownerLease) else {
            PlayerLog.log(
                "[Ambient] stale cover ignored owner=\(ownerLease.owner) "
                    + "leaseGen=\(ownerLease.generation) "
                    + "currentGen=\(ownerLeaseGeneration)"
            )
            return
        }
        let normalized = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        ambientCoverURL = normalized.flatMap { $0.isEmpty ? nil : $0 }
        ambientOwnerLease = ownerLease
        ambientStoryboardRequest = nil
        ambientStoryboardLoader.retire(keepingArtwork: false)
        retireAmbientSelection()
    }

    func setAmbientStoryboard(
        _ frames: [PlayerAmbientStoryboardFrame],
        ownerLease: PlayerOwnerLease,
        loadGeneration: Int
    ) {
        guard isCurrentOwner(ownerLease), loadGeneration == self.loadGeneration else {
            PlayerLog.log(
                "[Ambient] stale storyboard ignored owner=\(ownerLease.owner) "
                    + "leaseGen=\(ownerLease.generation) "
                    + "loadGen=\(loadGeneration) currentLoadGen=\(self.loadGeneration)"
            )
            return
        }
        ambientStoryboard = frames
        ambientStoryboardOwnerLease = ownerLease
        ambientStoryboardLoadGeneration = loadGeneration
        if let aid = currentAid, let cid = currentCid {
            ambientStoryboardContent = .init(aid: aid, cid: cid, owner: ownerLease)
        } else {
            ambientStoryboardContent = nil
        }
        if !isSeekInFlight, pendingSeekTarget == nil, resumeAtTime == nil {
            ambientSelectionMediaTime = mediaTime
        }
        refreshAmbientSelection()
        if !frames.isEmpty {
            PlayerLog.log(
                "[Ambient] storyboard admitted frames=\(frames.count) "
                    + "owner=\(ownerLease.owner) loadGen=\(loadGeneration)"
            )
        }
    }
}

struct PlayerAmbientStoryboardFrame: Equatable, Sendable {
    static let maxAdmittedFrames = 48

    let from: TimeInterval
    let to: TimeInterval
    let url: String

    init?(from: TimeInterval, to: TimeInterval, url: String) {
        guard from.isFinite, from >= 0,
              to.isFinite, to > from,
              let normalizedURL = Self.normalizedURL(url)
        else { return nil }
        self.from = from
        self.to = to
        self.url = normalizedURL
    }

    init?(point: PlayerV2Info.ViewPoint) {
        guard let from = point.from,
              let to = point.to,
              let imgURL = point.imgURL else { return nil }
        self.init(from: from, to: to, url: imgURL)
    }

    static func normalizedURL(_ rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.hasPrefix("//") ? "https:\(trimmed)" : trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return candidate
    }

    static func admitted(
        _ points: [PlayerV2Info.ViewPoint]?,
        maxCount: Int = Self.maxAdmittedFrames
    ) -> [Self] {
        guard maxCount > 0 else { return [] }
        return (points ?? [])
            .compactMap(Self.init(point:))
            .sorted {
                if $0.from != $1.from { return $0.from < $1.from }
                if $0.to != $1.to { return $0.to < $1.to }
                return $0.url < $1.url
            }
            .prefix(maxCount)
            .map { $0 }
    }
}
