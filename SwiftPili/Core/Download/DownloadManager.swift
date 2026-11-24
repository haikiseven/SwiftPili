import Foundation
import QuartzCore
import SwiftData
import UIKit

@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()
    static let maxConcurrentDownloads = 2

    private init() {
        PlayerViewModel.startNetworkMonitor()
        observeAppLifecycle()
    }

    var container: ModelContainer? {
        didSet {
            guard container != nil else { return }
            reconcileInterruptedDownloads()
        }
    }
    private var context: ModelContext? { container?.mainContext }

    private let activityState = DownloadActivityState()

    private(set) var active: [ActiveDownload] {
        get { activityState.active }
        set { activityState.active = newValue }
        _modify { yield &activityState.active }
    }

    var hasInFlightDownloads: Bool {
        activityState.hasInFlightDownloads
    }

    private enum ActiveStageDownloader {
        case single(FileDownloader)
        case segmented(SegmentedFileDownloader)

        func cancel() {
            switch self {
            case .single(let downloader): downloader.cancel()
            case .segmented(let downloader): downloader.cancel()
            }
        }

        func invalidate() {
            switch self {
            case .single(let downloader): downloader.invalidate()
            case .segmented(let downloader): downloader.cancel()
            }
        }
    }

    private struct RankedStageCandidates: Sendable {
        let segmentedURLs: [URL]
        let verifiedAPIHosts: Set<String>
        let fallbackURLStrings: [String]
    }

    private struct Operation {
        let token: UUID
        let stagingFolder: URL
        var manifest: DownloadManifest
        var stageDownloaders: [DownloadStage: ActiveStageDownloader] = [:]
        var stagePhases: [DownloadStage: ActiveDownload.Phase] = [:]
        var stageGenerationCounter: UInt64 = 0
        var acceptingCallbacks = true
        var accounting: DownloadProgressAccumulator
        var callbackFence: DownloadCallbackFence
        var lastProgressPublishTime: TimeInterval = 0
    }

    private var operations: [String: Operation] = [:]
    private var pendingTokens: [String: UUID] = [:]
    private var runningTasks: [String: Task<Void, Never>] = [:]
    private var queuedOrder: [String] = []
    private var queuedManifests: [String: DownloadManifest] = [:]
    private var automaticResumeQueue = DownloadAutomaticResumeQueue()
    private var isBackgrounded = UIApplication.shared.applicationState == .background
    @ObservationIgnored
    private var qualityCache = DownloadQualityCache()

    struct ActiveDownload: Identifiable, Equatable, Sendable {
        let id: String
        let aid: Int
        let bvid: String
        let cid: Int
        let title: String
        let coverURL: String
        let ownerName: String
        let durationSeconds: Int
        var qualityCode: Int
        var qualityLabel: String
        var bytesTransferred: Int64
        var expectedBytes: Int64?
        var fraction: Double?
        var speedBytesPerSecond: Double?
        var fractionIsEstimated: Bool
        var phase: Phase

        enum Phase: Sendable, Equatable {
            case queued
            case preparing
            case downloadingVideo
            case downloadingAudio
            case retryingVideo
            case retryingAudio
            case validating
            case committing
            case failed(String)
            case paused

            var isResumable: Bool {
                switch self {
                case .failed, .paused: true
                default: false
                }
            }

            var isActivelyRunning: Bool {
                switch self {
                case .preparing, .downloadingVideo, .downloadingAudio,
                     .retryingVideo, .retryingAudio, .validating, .committing:
                    true
                case .queued, .failed, .paused:
                    false
                }
            }
        }

        nonisolated static func seededFraction(
            bytesTransferred: Int64,
            expectedBytes: Int64?
        ) -> Double? {
            guard let expectedBytes, expectedBytes > 0, bytesTransferred > 0 else {
                return nil
            }
            return min(max(Double(bytesTransferred) / Double(expectedBytes), 0), 1)
        }
    }

    nonisolated static let requestHeaders = [
        "Referer": BiliAPIClient.defaultReferer,
        "User-Agent": BiliAPIClient.defaultUserAgent,
    ]

    // MARK: - Queries

    func isActive(bvid: String, cid: Int) -> Bool {
        active.contains { $0.id == "\(bvid)_\(cid)" }
    }

    func existing(bvid: String, cid: Int) -> DownloadedVideo? {
        let id = "\(bvid)_\(cid)"
        let descriptor = FetchDescriptor<DownloadedVideo>(predicate: #Predicate { $0.id == id })
        return try? context?.fetch(descriptor).first
    }

    func availableQualities(aid: Int, cid: Int) async throws -> [DownloadQualityOption] {
        try Task.checkCancellation()
        let session = AuthManager.shared.sessionGeneration
        let key = DownloadQualityCacheKey(aid: aid, cid: cid, sessionGeneration: session)
        let startedAt = CACurrentMediaTime()
        func elapsedMS() -> Int { Int((CACurrentMediaTime() - startedAt) * 1000) }

        if let cached = qualityCache.value(for: key, now: Date()) {
            PlayerLog.log(
                "[Download] quality list source=cache aid=\(aid) cid=\(cid) " +
                    "count=\(cached.count) elapsed=\(elapsedMS())ms"
            )
            return cached
        }
        let result: PlayURLResult
        do {
            result = try await VideoAPI.getPlayURL(aid: aid, cid: cid, quality: 127, fnval: 4048)
        } catch {
            guard !Task.isCancelled, AuthManager.shared.sessionGeneration == session else {
                throw CancellationError()
            }
            if let reason = PlaybackAvailabilityPolicy.unavailability(forAny: error) {
                throw DownloadError.unavailable(reason)
            }
            throw DownloadError.playURL(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard AuthManager.shared.sessionGeneration == session else { throw CancellationError() }
        let requestMS = elapsedMS()
        guard let dash = result.dash, !dash.video.isEmpty else {
            throw DownloadError.noStream
        }
        let qualities = DownloadQualityOption.options(
            videoStreams: dash.video.map { (id: $0.id, bandwidth: $0.bandwidth) },
            audioBandwidth: dash.audio?.max(by: { $0.bandwidth < $1.bandwidth })?.bandwidth,
            durationSeconds: dash.duration,
            labels: Dictionary(
                dash.video.map { ($0.id, PlayerViewModel.qualityLabel(for: $0.id)) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        qualityCache.store(qualities, for: key, now: Date())
        PlayerLog.log(
            "[Download] quality list source=network aid=\(aid) cid=\(cid) " +
                "count=\(qualities.count) request=\(requestMS)ms " +
                "parse=\(elapsedMS() - requestMS)ms elapsed=\(elapsedMS())ms"
        )
        return qualities
    }

    func hasImmediateQualityList(aid: Int, cid: Int) -> Bool {
        qualityCache.value(
            for: DownloadQualityCacheKey(
                aid: aid, cid: cid, sessionGeneration: AuthManager.shared.sessionGeneration
            ), now: Date()
        ) != nil
    }

    func invalidateQualityCache(aid: Int, cid: Int) {
        qualityCache.invalidate(DownloadQualityCacheKey(
            aid: aid, cid: cid, sessionGeneration: AuthManager.shared.sessionGeneration
        ))
    }

    // MARK: - App lifecycle

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DownloadManager.shared.suspendActiveDownloadsForBackgrounding()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DownloadManager.shared.resumeDownloadsSuspendedByBackgrounding()
            }
        }
    }

    private func suspendActiveDownloadsForBackgrounding() {
        isBackgrounded = true
        let running = Array(pendingTokens.keys)
        let queued = queuedOrder
        let toSuspend = running + queued
        guard !toSuspend.isEmpty else { return }
        automaticResumeQueue.enqueue(toSuspend)
        queuedOrder.removeAll()
        queuedManifests.removeAll()
        for id in running {
            halt(id: id, promoteNext: false)
        }
        for id in queued {
            if let index = active.firstIndex(where: { $0.id == id }) {
                active[index].phase = .paused
                active[index].speedBytesPerSecond = nil
            }
        }
        PlayerLog.log(
            "[Download] suspended \(running.count) active + \(queued.count) queued transfer(s) for backgrounding"
        )
    }

    private func resumeDownloadsSuspendedByBackgrounding() {
        isBackgrounded = false
        scheduleAutomaticResumes()
    }

    private func scheduleAutomaticResumes() {
        guard !isBackgrounded, !automaticResumeQueue.isEmpty else { return }
        var ids: [String] = []
        while let id = automaticResumeQueue.takeNext(isBackgrounded: isBackgrounded) {
            ids.append(id)
        }
        for id in ids {
            guard active.contains(where: { $0.id == id && $0.phase == .paused }),
                  DownloadStore.readManifest(contentID: id)?.allowsAutomaticResume == true
            else { continue }
            enqueueResume(id: id)
        }
        drainQueue()
    }

    // MARK: - Download

    func startDownload(
        aid: Int,
        cid: Int,
        bvid: String,
        title: String,
        coverURL: String,
        ownerName: String,
        durationSeconds: Int,
        quality: Int
    ) async {
        let id = "\(bvid)_\(cid)"
        guard !DownloadExportCoordinator.shared.sourceIsLocked(downloadID: id) else { return }
        guard existing(bvid: bvid, cid: cid) == nil, !isActive(bvid: bvid, cid: cid) else {
            PlayerLog.log("[Download] duplicate start ignored id=\(id)")
            return
        }
        var manifest = DownloadStore.readManifest(contentID: id)
        if let existingManifest = manifest, existingManifest.requestedQuality != quality {
            PlayerLog.log(
                "[Download] discarding partial id=\(id) — quality changed " +
                    "\(existingManifest.requestedQuality) → \(quality)"
            )
            DownloadStore.removeStaging(contentID: id)
            manifest = nil
        }
        var plan = manifest ?? DownloadManifest(
            contentID: id,
            aid: aid,
            bvid: bvid,
            cid: cid,
            title: title,
            coverURL: coverURL,
            ownerName: ownerName,
            durationSeconds: durationSeconds,
            requestedQuality: quality
        )
        plan.userPaused = false
        enqueueDownload(plan)
        drainQueue()
    }

    func resumeDownload(id: String) async {
        enqueueResume(id: id)
        drainQueue()
    }

    private func enqueueResume(id: String) {
        guard pendingTokens[id] == nil,
              operations[id] == nil,
              queuedManifests[id] == nil else {
            PlayerLog.log("[Download] resume ignored — already active or queued id=\(id)")
            return
        }
        guard var manifest = DownloadStore.readManifest(contentID: id) else {
            PlayerLog.log("[Download] resume unavailable — no manifest id=\(id)")
            active.removeAll { $0.id == id }
            return
        }
        guard existing(bvid: manifest.bvid, cid: manifest.cid) == nil else {
            DownloadStore.removeStaging(contentID: id)
            active.removeAll { $0.id == id }
            return
        }
        automaticResumeQueue.revoke(id)
        manifest.userPaused = false
        do {
            try DownloadStore.writeManifest(
                manifest, folder: DownloadStore.makeStagingDirectory(contentID: id)
            )
        } catch {
            PlayerLog.log("[Download] cannot persist resume intent id=\(id) error=\(error)")
            return
        }
        enqueueDownload(manifest)
    }

    private func enqueueDownload(_ plan: DownloadManifest) {
        let id = plan.contentID
        guard pendingTokens[id] == nil, queuedManifests[id] == nil else { return }

        if let folder = try? DownloadStore.makeStagingDirectory(contentID: id) {
            try? DownloadStore.writeManifest(plan, folder: folder)
        }

        let stagedBytes = DownloadStore.effectiveStagedBytes(
            manifest: plan,
            folder: DownloadStore.stagingFolder(contentID: id)
        )
        let row = ActiveDownload(
            id: id, aid: plan.aid, bvid: plan.bvid, cid: plan.cid, title: plan.title,
            coverURL: plan.coverURL, ownerName: plan.ownerName,
            durationSeconds: plan.durationSeconds,
            qualityCode: plan.resolvedQuality ?? plan.requestedQuality,
            qualityLabel: PlayerViewModel.qualityLabel(
                for: plan.resolvedQuality ?? plan.requestedQuality
            ),
            bytesTransferred: stagedBytes,
            expectedBytes: plan.totalExpectedBytes,
            fraction: ActiveDownload.seededFraction(
                bytesTransferred: stagedBytes, expectedBytes: plan.totalExpectedBytes
            ),
            speedBytesPerSecond: nil,
            fractionIsEstimated: false,
            phase: .queued
        )
        if let index = active.firstIndex(where: { $0.id == id }) {
            active[index] = row
        } else {
            active.insert(row, at: 0)
        }
        queuedOrder.append(id)
        queuedManifests[id] = plan
        PlayerLog.log(
            "[Download] queued id=\(id) qn=\(plan.requestedQuality) " +
                "active=\(pendingTokens.count)/\(Self.maxConcurrentDownloads) queued=\(queuedOrder.count)"
        )
    }

    private func drainQueue() {
        guard !isBackgrounded else { return }
        while pendingTokens.count < Self.maxConcurrentDownloads, !queuedOrder.isEmpty {
            let nextID = queuedOrder.removeFirst()
            guard let manifest = queuedManifests.removeValue(forKey: nextID) else { continue }
            guard pendingTokens[nextID] == nil, operations[nextID] == nil else { continue }
            guard existing(bvid: manifest.bvid, cid: manifest.cid) == nil else {
                DownloadStore.removeStaging(contentID: nextID)
                active.removeAll { $0.id == nextID }
                continue
            }
            let token = UUID()
            pendingTokens[nextID] = token
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runDownload(manifest, token: token, presentAs: .preparing)
            }
            runningTasks[nextID] = task
        }
    }

    func pause(id: String) {
        guard var manifest = operations[id]?.manifest
            ?? queuedManifests[id]
            ?? DownloadStore.readManifest(contentID: id)
        else {
            PlayerLog.log("[Download] pause ignored — no manifest id=\(id)")
            return
        }
        manifest.userPaused = true
        do {
            try DownloadStore.writeManifest(
                manifest, folder: DownloadStore.makeStagingDirectory(contentID: id)
            )
        } catch {
            PlayerLog.log("[Download] cannot persist pause intent id=\(id) error=\(error)")
            return
        }
        automaticResumeQueue.revoke(id)
        halt(id: id, promoteNext: !isBackgrounded)
    }

    private func halt(id: String, promoteNext: Bool = true) {
        removeFromQueue(id: id)
        stopActiveExecution(id: id)
        let staged = DownloadStore.readManifest(contentID: id).map {
            DownloadStore.effectiveStagedBytes(
                manifest: $0, folder: DownloadStore.stagingFolder(contentID: id)
            )
        } ?? DownloadStore.stagedBytes(contentID: id)
        if let index = active.firstIndex(where: { $0.id == id }) {
            active[index].phase = .paused
            active[index].speedBytesPerSecond = nil
        }
        PlayerLog.log("[Download] paused id=\(id) bytes=\(staged)")
        if promoteNext {
            drainQueue()
        }
    }

    private func removeFromQueue(id: String) {
        queuedOrder.removeAll { $0 == id }
        queuedManifests.removeValue(forKey: id)
    }

    private func stopActiveExecution(id: String) {
        let operation = operations.removeValue(forKey: id)
        pendingTokens[id] = nil
        let task = runningTasks.removeValue(forKey: id)
        if let operation {
            for downloader in operation.stageDownloaders.values {
                downloader.cancel()
                downloader.invalidate()
            }
        }
        task?.cancel()
    }

    private func runDownload(
        _ plan: DownloadManifest,
        token: UUID,
        presentAs initialPhase: ActiveDownload.Phase
    ) async {
        let id = plan.contentID
        let tokenLabel = String(token.uuidString.prefix(8))
        let stagedBytes = DownloadStore.effectiveStagedBytes(
            manifest: plan,
            folder: DownloadStore.stagingFolder(contentID: id)
        )
        let row = ActiveDownload(
            id: id, aid: plan.aid, bvid: plan.bvid, cid: plan.cid, title: plan.title,
            coverURL: plan.coverURL, ownerName: plan.ownerName,
            durationSeconds: plan.durationSeconds,
            qualityCode: plan.resolvedQuality ?? plan.requestedQuality,
            qualityLabel: PlayerViewModel.qualityLabel(
                for: plan.resolvedQuality ?? plan.requestedQuality
            ),
            bytesTransferred: stagedBytes, expectedBytes: plan.totalExpectedBytes,
            fraction: ActiveDownload.seededFraction(
                bytesTransferred: stagedBytes, expectedBytes: plan.totalExpectedBytes
            ),
            speedBytesPerSecond: nil, fractionIsEstimated: false, phase: initialPhase
        )
        if let index = active.firstIndex(where: { $0.id == id }) {
            active[index] = row
        } else {
            active.insert(row, at: 0)
        }
        PlayerLog.log(
            "[Download] \(stagedBytes > 0 ? "resume" : "start") id=\(id) " +
                "qn=\(plan.requestedQuality) staged=\(stagedBytes)B op=\(tokenLabel)"
        )

        var manifest = plan
        defer {
            if let existingOp = operations[id], existingOp.token == token {
                for downloader in existingOp.stageDownloaders.values {
                    downloader.invalidate()
                }
                operations[id] = nil
            }
            if pendingTokens[id] == token {
                pendingTokens[id] = nil
                runningTasks[id] = nil
            }
            drainQueue()
        }
        do {
            guard let context else { throw DownloadError.storeUnavailable }

            let stagingFolder = try DownloadStore.makeStagingDirectory(contentID: id)
            try DownloadStore.writeManifest(manifest, folder: stagingFolder)
            let created = Operation(
                token: token,
                stagingFolder: stagingFolder,
                manifest: manifest,
                accounting: DownloadProgressAccumulator(requiredStages: [.video]),
                callbackFence: DownloadCallbackFence(operationToken: token)
            )
            operations[id] = created

            let result: PlayURLResult
            do {
                result = try await VideoAPI.getPlayURL(
                    aid: manifest.aid, cid: manifest.cid,
                    quality: manifest.requestedQuality, fnval: 4048
                )
            } catch {
                throw DownloadError.playURL(error.localizedDescription)
            }
            guard isCurrent(id: id, token: token) else { throw CancellationError() }
            guard let dash = result.dash else { throw DownloadError.noStream }

            let requested = manifest.requestedQuality
            let video = dash.video.first(where: { $0.id == requested })
                ?? dash.video.filter { $0.id <= requested }.max(by: { $0.id < $1.id })
                ?? dash.video.max(by: { $0.id < $1.id })
            guard let video else { throw DownloadError.noStream }
            let audio = dash.audio?.max(by: { $0.bandwidth < $1.bandwidth })

            if !manifest.matchesResolvedStream(quality: video.id, codecs: video.codecs) {
                PlayerLog.log(
                    "[Download] partial discarded id=\(id) — encode changed " +
                        "\(manifest.resolvedQuality.map(String.init) ?? "-")/\(manifest.codecs ?? "-") " +
                        "→ \(video.id)/\(video.codecs)"
                )
                DownloadStore.resetStagedMedia(folder: stagingFolder)
                manifest.resolvedQuality = nil
                manifest.codecs = nil
                manifest.expectedBytes = [:]
                manifest.completedRanges = nil
            }
            manifest.resolvedQuality = video.id
            manifest.codecs = video.codecs
            manifest.hasSeparateAudio = audio != nil
            updateOperationManifest(id: id, token: token, manifest: manifest)
            try? DownloadStore.writeManifest(manifest, folder: stagingFolder)

            let videoCandidates = try rankDownloadCandidates(video.allURLs, stage: .video)
            let audioCandidates = try audio.map {
                try rankDownloadCandidates($0.allURLs, stage: .audio)
            }
            let requiredStages: [DownloadStage] = audio == nil ? [.video] : [.video, .audio]
            let networkPolicy = DownloadNetworkPolicy.current

            let effectiveStagedByStage = DownloadStore.effectiveStagedByteLengths(
                manifest: manifest,
                stages: requiredStages,
                folder: stagingFolder
            )
            let effectiveStagedTotal = effectiveStagedByStage.values.reduce(0, +)
            let requiredBytes = DownloadStoragePolicy.requiredBytes(
                expectedBytesByStage: manifest.expectedBytesByStage,
                requiredStages: requiredStages,
                videoBandwidth: video.bandwidth,
                audioBandwidth: audio?.bandwidth,
                durationSeconds: manifest.durationSeconds
            )
            let storage = DownloadStoragePolicy.verdict(
                availableBytes: DownloadStore.availableCapacityForImportantUsage(),
                requiredBytes: requiredBytes,
                alreadyStagedBytes: effectiveStagedTotal
            )
            if case let .insufficient(required, available) = storage {
                throw DownloadError.insufficientStorage(
                    requiredBytes: required, availableBytes: available
                )
            }
            configureRequiredStages(
                id: id, token: token, stages: requiredStages,
                knownExpectedBytes: manifest.expectedBytesByStage,
                stagedByteLengths: effectiveStagedByStage,
                estimatedExpectedBytes: DownloadStoragePolicy.estimatedBytesByStage(
                    requiredStages: requiredStages,
                    videoBandwidth: video.bandwidth,
                    audioBandwidth: audio?.bandwidth,
                    durationSeconds: manifest.durationSeconds
                )
            )
            updateQuality(id: id, token: token, code: video.id)
            if video.id != manifest.requestedQuality {
                invalidateQualityCache(aid: manifest.aid, cid: manifest.cid)
            }

            let hasAudioSibling = audio != nil
            let aid = manifest.aid
            let cid = manifest.cid
            let requestedQuality = manifest.requestedQuality
            let resolvedVideoID = video.id
            let resolvedCodecs = video.codecs
            let manifestSnapshot = manifest

            try await withThrowingTaskGroup(of: (DownloadStage, FileDownloader.StageResult).self) { group in
                for stage in requiredStages {
                    guard let candidates = stage == .video ? videoCandidates : audioCandidates else {
                        continue
                    }
                    let destination = DownloadStore.stagedFile(stage, in: stagingFolder)
                    let initialExpected = manifestSnapshot.expected(stage)
                    let initialRanges = manifestSnapshot.effectiveCompletedRanges(
                        for: stage,
                        fileLength: FileDownloader.fileLength(destination)
                    )
                    group.addTask {
                        let stageResult = try await self.downloadStage(
                            id: id,
                            token: token,
                            tokenLabel: tokenLabel,
                            stage: stage,
                            candidates: candidates,
                            destination: destination,
                            knownTotalLength: initialExpected,
                            initialCompletedRanges: initialRanges,
                            hasAudioSibling: hasAudioSibling,
                            networkPolicy: networkPolicy,
                            aid: aid,
                            cid: cid,
                            requestedQuality: requestedQuality,
                            resolvedVideoID: resolvedVideoID,
                            resolvedCodecs: resolvedCodecs
                        )
                        return (stage, stageResult)
                    }
                }
                for try await (stage, stageResult) in group {
                    guard isCurrent(id: id, token: token) else {
                        group.cancelAll()
                        throw CancellationError()
                    }
                    if let learned = stageResult.expectedBytes {
                        mutateOperationManifest(id: id, token: token) {
                            $0.setExpected(stage, bytes: learned)
                        }
                    }
                    completeStage(
                        id: id, token: token, stage: stage,
                        actualBytes: stageResult.bytesOnDisk
                    )
                }
            }

            guard isCurrent(id: id, token: token) else { throw CancellationError() }
            if let latestManifest = operations[id]?.manifest {
                manifest = latestManifest
            }
            updatePhase(id: id, token: token, .validating)

            let integrity = DownloadStore.integrity(
                folder: stagingFolder, hasSeparateAudio: audio != nil
            )
            guard integrity == .valid else {
                throw DownloadError.invalidFiles(integrity.errorDescription)
            }
            for stage in requiredStages {
                if let ranges = manifest.completedRanges(for: stage),
                   let expected = manifest.expected(stage),
                   !DownloadByteRange.isComplete(ranges, totalBytes: expected) {
                    throw DownloadError.incomplete(
                        stage: stage.rawValue,
                        onDisk: DownloadByteRange.totalBytes(in: ranges),
                        expected: expected
                    )
                }
            }
            let completeness = DownloadCompletenessPolicy.verdict(
                stages: requiredStages,
                bytesOnDisk: DownloadStore.stagedByteLengths(
                    stages: requiredStages, folder: stagingFolder
                ),
                expected: manifest.expectedBytesByStage
            )
            switch completeness {
            case .complete(let totalBytes):
                PlayerLog.log("[Download] byte-complete id=\(id) bytes=\(totalBytes)")
            case .unverifiable(let stage, let onDisk):
                PlayerLog.log(
                    "[Download] ⚠️ length unverified id=\(id) stage=\(stage.rawValue) " +
                        "bytes=\(onDisk) — origin stated no total"
                )
            case .short(let stage, let onDisk, let expected):
                throw DownloadError.incomplete(
                    stage: stage.rawValue, onDisk: onDisk, expected: expected
                )
            case .missing(let stage):
                throw DownloadError.invalidFiles(
                    (stage == .video
                        ? DownloadAssetIntegrity.missingVideo
                        : DownloadAssetIntegrity.missingAudio).errorDescription
                )
            }
            let verifiedLength = DownloadStore.stagedByteLengths(
                stages: requiredStages, folder: stagingFolder
            ).values.reduce(0, +)

            updatePhase(id: id, token: token, .committing)
            let finalFolder = try DownloadStore.commit(
                stagingFolder: stagingFolder, contentID: id
            )
            DownloadStore.removeManifest(folder: finalFolder)
            let size = DownloadStore.folderSize(finalFolder)
            guard size > 0 else {
                try? FileManager.default.removeItem(at: finalFolder)
                throw DownloadError.invalidFiles("downloaded files are empty")
            }
            guard isCurrent(id: id, token: token) else {
                try? FileManager.default.removeItem(at: finalFolder)
                throw CancellationError()
            }

            let record = DownloadedVideo(
                aid: manifest.aid, bvid: manifest.bvid, cid: manifest.cid,
                title: manifest.title, coverURL: manifest.coverURL,
                ownerName: manifest.ownerName, durationSeconds: manifest.durationSeconds,
                qualityCode: video.id,
                qualityLabel: PlayerViewModel.qualityLabel(for: video.id),
                codecs: video.codecs, folderName: id,
                hasSeparateAudio: audio != nil, fileSizeBytes: size,
                verifiedByteLength: completeness.isVerified ? verifiedLength : 0
            )
            context.insert(record)
            do {
                try context.save()
            } catch {
                context.delete(record)
                try? context.save()
                try? FileManager.default.removeItem(at: finalFolder)
                throw DownloadError.persistence(error.localizedDescription)
            }

            guard isCurrent(id: id, token: token) else {
                context.delete(record)
                try? context.save()
                try? FileManager.default.removeItem(at: finalFolder)
                throw CancellationError()
            }
            active.removeAll { $0.id == id }
            PlayerLog.log(
                "[Download] completed id=\(id) qn=\(video.id) bytes=\(size) " +
                    "audio=\(audio != nil) verified=\(completeness.isVerified ? 1 : 0) op=\(tokenLabel)"
            )
        } catch {
            guard isCurrent(id: id, token: token) else {
                PlayerLog.log("[Download] stale operation ended id=\(id) op=\(tokenLabel)")
                return
            }
            if error.isDownloadCancellation {
                if let index = active.firstIndex(where: { $0.id == id }),
                   active[index].phase != .paused {
                    active.remove(at: index)
                }
                PlayerLog.log("[Download] cancelled id=\(id) op=\(tokenLabel)")
            } else {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                updatePhase(id: id, token: token, .failed(message))
                let staged = DownloadStore.readManifest(contentID: id).map {
                    DownloadStore.effectiveStagedBytes(
                        manifest: $0, folder: DownloadStore.stagingFolder(contentID: id)
                    )
                } ?? DownloadStore.stagedBytes(contentID: id)
                PlayerLog.log(
                    "[Download] failed id=\(id) op=\(tokenLabel) " +
                        "staged=\(staged)B error=\(message)"
                )
            }
        }
    }

    private func downloadStage(
        id: String,
        token: UUID,
        tokenLabel: String,
        stage: DownloadStage,
        candidates: RankedStageCandidates,
        destination: URL,
        knownTotalLength: Int64?,
        initialCompletedRanges: [DownloadByteRange],
        hasAudioSibling: Bool,
        networkPolicy: DownloadNetworkPolicy,
        aid: Int,
        cid: Int,
        requestedQuality: Int,
        resolvedVideoID: Int,
        resolvedCodecs: String
    ) async throws -> FileDownloader.StageResult {
        guard isCurrent(id: id, token: token) else { throw CancellationError() }

        let currentPath = PlayerViewModel.resolvedDownloadNetworkPath()
        let onCellular = currentPath?.networkClass == .expensive
        let allowSegmentedForStage = networkPolicy.multiConnectionEnabled
            && !candidates.segmentedURLs.isEmpty
            && !(stage == .audio && hasAudioSibling && onCellular)

        var fallbackKnownTotal = knownTotalLength

        if allowSegmentedForStage {
            guard let stageGeneration = beginStage(id: id, token: token, stage: stage) else {
                throw CancellationError()
            }
            setStagePhase(
                id: id, token: token, stage: stage,
                phase: stage == .video ? .downloadingVideo : .downloadingAudio
            )

            let profile: SegmentedDownloadProfile
            if stage == .audio {
                profile = .concurrentAudio
            } else if hasAudioSibling {
                profile = .videoWithConcurrentAudio
            } else {
                profile = .standardVideo
            }

            let segmented = SegmentedFileDownloader()
            setStageDownloader(id: id, token: token, stage: stage, downloader: .segmented(segmented))
            defer {
                clearStageDownloader(id: id, token: token, stage: stage)
            }

            let request = SegmentedDownloadRequest(
                urls: candidates.segmentedURLs,
                verifiedAPIHosts: candidates.verifiedAPIHosts,
                destination: destination,
                headers: Self.requestHeaders,
                label: stage.rawValue,
                operationLabel: tokenLabel,
                knownTotalLength: knownTotalLength,
                initialCompletedRanges: initialCompletedRanges,
                network: networkPolicy,
                profile: profile
            )

            let refreshURLs: @Sendable () async throws -> SegmentedRefreshedCandidates = { [weak self] in
                let refreshedResult = try await VideoAPI.getPlayURL(
                    aid: aid, cid: cid, quality: requestedQuality, fnval: 4048
                )
                guard let refreshedDash = refreshedResult.dash else {
                    throw DownloadError.noStream
                }
                let rawURLs: [String]
                switch stage {
                case .video:
                    guard let matched = refreshedDash.video.first(where: {
                        $0.id == resolvedVideoID && $0.codecs == resolvedCodecs
                    }) ?? refreshedDash.video.first(where: { $0.id == resolvedVideoID }) else {
                        throw DownloadError.noStream
                    }
                    rawURLs = matched.allURLs
                case .audio:
                    guard let matched = refreshedDash.audio?.max(by: { $0.bandwidth < $1.bandwidth }) else {
                        throw DownloadError.noStream
                    }
                    rawURLs = matched.allURLs
                }
                guard let self else { throw CancellationError() }
                let ranked = try await MainActor.run {
                    try self.rankDownloadCandidates(rawURLs, stage: stage)
                }
                return SegmentedRefreshedCandidates(
                    urls: ranked.segmentedURLs,
                    verifiedAPIHosts: ranked.verifiedAPIHosts
                )
            }

            let outcome = try await segmented.download(
                request,
                onProgress: { [weak self] receivedBytes, totalBytes in
                    Task { @MainActor in
                        self?.applySegmentedProgress(
                            id: id,
                            token: token,
                            stage: stage,
                            stageGeneration: stageGeneration,
                            transferredBytes: receivedBytes,
                            expectedBytes: totalBytes
                        )
                    }
                },
                onCheckpoint: { [weak self] ranges, totalBytes in
                    Task { @MainActor in
                        self?.applySegmentedCheckpoint(
                            id: id,
                            token: token,
                            stage: stage,
                            ranges: ranges,
                            totalBytes: totalBytes
                        )
                    }
                },
                refreshURLs: refreshURLs
            )

            switch outcome {
            case .completed(let result):
                if result.bytesOnDisk > 0 {
                    mutateOperationManifest(id: id, token: token) { manifest in
                        manifest.setCompletedRanges(
                            [DownloadByteRange(start: 0, end: result.bytesOnDisk)],
                            for: stage
                        )
                        if let expected = result.expectedBytes {
                            manifest.setExpected(stage, bytes: expected)
                        }
                    }
                }
                return result
            case .fallbackToSingleConnection(let learnedTotal):
                fallbackKnownTotal = learnedTotal ?? fallbackKnownTotal
            }
        }

        // Single-connection FileDownloader path (or fallback from SegmentedFileDownloader).
        guard isCurrent(id: id, token: token) else { throw CancellationError() }
        prepareForSingleConnectionFallback(
            id: id,
            token: token,
            stage: stage,
            destination: destination,
            learnedTotal: fallbackKnownTotal
        )
        guard let stageGeneration = beginStage(id: id, token: token, stage: stage) else {
            throw CancellationError()
        }
        setStagePhase(
            id: id, token: token, stage: stage,
            phase: stage == .video ? .downloadingVideo : .downloadingAudio
        )
        let single = FileDownloader()
        setStageDownloader(id: id, token: token, stage: stage, downloader: .single(single))
        defer {
            clearStageDownloader(id: id, token: token, stage: stage)
            single.invalidate()
        }

        return try await single.download(
            urls: candidates.fallbackURLStrings,
            to: destination,
            headers: Self.requestHeaders,
            label: stage.rawValue,
            operationLabel: tokenLabel,
            operationToken: token,
            stage: stage,
            stageGeneration: stageGeneration,
            knownTotalLength: fallbackKnownTotal,
            network: networkPolicy
        ) { [weak self] event in
            Task { @MainActor in
                self?.applyTransferEvent(id: id, event: event)
            }
        }
    }

    private func prepareForSingleConnectionFallback(
        id: String,
        token: UUID,
        stage: DownloadStage,
        destination: URL,
        learnedTotal: Int64?
    ) {
        guard var operation = operations[id], operation.token == token else { return }
        let diskLength = FileDownloader.fileLength(destination)
        if operation.manifest.completedRanges(for: stage) != nil {
            let effective = operation.manifest.effectiveCompletedRanges(for: stage, fileLength: diskLength)
            let prefix = DownloadByteRange.contiguousPrefixLength(in: effective)
            if diskLength > prefix {
                try? FileDownloader.truncate(destination, to: prefix)
            }
            operation.manifest.clearCompletedRanges(for: stage)
        }
        if let learnedTotal, learnedTotal > 0 {
            operation.manifest.setExpected(stage, bytes: learnedTotal)
        }
        operations[id] = operation
        try? DownloadStore.writeManifest(operation.manifest, folder: operation.stagingFolder)
    }

    func reconcileInterruptedDownloads() {
        let restored = DownloadStore.reconcileStaging()
        guard !restored.isEmpty else { return }
        var resumable: [String] = []
        for manifest in restored {
            let id = manifest.contentID
            guard existing(bvid: manifest.bvid, cid: manifest.cid) == nil else {
                DownloadStore.removeStaging(contentID: id)
                continue
            }
            guard !active.contains(where: { $0.id == id }) else { continue }
            let staged = DownloadStore.effectiveStagedBytes(
                manifest: manifest,
                folder: DownloadStore.stagingFolder(contentID: id)
            )
            active.append(
                ActiveDownload(
                    id: id, aid: manifest.aid, bvid: manifest.bvid, cid: manifest.cid,
                    title: manifest.title, coverURL: manifest.coverURL,
                    ownerName: manifest.ownerName,
                    durationSeconds: manifest.durationSeconds,
                    qualityCode: manifest.resolvedQuality ?? manifest.requestedQuality,
                    qualityLabel: PlayerViewModel.qualityLabel(
                        for: manifest.resolvedQuality ?? manifest.requestedQuality
                    ),
                    bytesTransferred: staged,
                    expectedBytes: manifest.totalExpectedBytes,
                    fraction: ActiveDownload.seededFraction(
                        bytesTransferred: staged,
                        expectedBytes: manifest.totalExpectedBytes
                    ),
                    speedBytesPerSecond: nil, fractionIsEstimated: false, phase: .paused
                )
            )
            if manifest.allowsAutomaticResume { resumable.append(id) }
            PlayerLog.log(
                "[Download] restored interrupted id=\(id) staged=\(staged)B of " +
                    "\(manifest.totalExpectedBytes.map(String.init) ?? "unknown")"
            )
        }
        guard !resumable.isEmpty else { return }
        automaticResumeQueue.enqueue(resumable)
        scheduleAutomaticResumes()
    }

    func cancel(id: String) {
        removeFromQueue(id: id)
        stopActiveExecution(id: id)
        automaticResumeQueue.revoke(id)
        active.removeAll { $0.id == id }
        DownloadStore.removeStaging(contentID: id)
        PlayerLog.log("[Download] user cancelled id=\(id)")
        drainQueue()
    }

    func retry(id: String) {
        guard let item = active.first(where: { $0.id == id }) else { return }
        switch item.phase {
        case .failed, .paused:
            break
        default:
            return
        }
        automaticResumeQueue.revoke(id)
        removeFromQueue(id: id)
        stopActiveExecution(id: id)
        enqueueResume(id: id)
        drainQueue()
    }

    @discardableResult
    func delete(_ item: DownloadedVideo) -> Bool {
        guard !DownloadExportCoordinator.shared.sourceIsLocked(downloadID: item.id) else { return false }
        cancel(id: item.id)
        do {
            if FileManager.default.fileExists(atPath: item.folderURL.path) {
                try FileManager.default.removeItem(at: item.folderURL)
            }
            context?.delete(item)
            try context?.save()
            PlayerLog.log("[Download] deleted id=\(item.id)")
            return true
        } catch {
            PlayerLog.log("[Download] delete failed id=\(item.id) error=\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - State mutation

    private func isCurrent(id: String, token: UUID) -> Bool {
        operations[id]?.token == token || pendingTokens[id] == token
    }

    private func updateOperationManifest(id: String, token: UUID, manifest: DownloadManifest) {
        guard var operation = operations[id], operation.token == token else { return }
        operation.manifest = manifest
        operations[id] = operation
    }

    private func mutateOperationManifest(
        id: String,
        token: UUID,
        _ mutate: (inout DownloadManifest) -> Void
    ) {
        guard var operation = operations[id], operation.token == token else { return }
        mutate(&operation.manifest)
        operations[id] = operation
        try? DownloadStore.writeManifest(operation.manifest, folder: operation.stagingFolder)
    }

    private func setStageDownloader(
        id: String,
        token: UUID,
        stage: DownloadStage,
        downloader: ActiveStageDownloader
    ) {
        guard var operation = operations[id], operation.token == token else { return }
        operation.stageDownloaders[stage] = downloader
        operations[id] = operation
    }

    private func clearStageDownloader(id: String, token: UUID, stage: DownloadStage) {
        guard var operation = operations[id], operation.token == token else { return }
        operation.stageDownloaders[stage] = nil
        operations[id] = operation
    }

    private func configureRequiredStages(
        id: String,
        token: UUID,
        stages: [DownloadStage],
        knownExpectedBytes: [DownloadStage: Int64],
        stagedByteLengths: [DownloadStage: Int64],
        estimatedExpectedBytes: [DownloadStage: Int64]
    ) {
        guard var operation = operations[id], operation.token == token else { return }
        operation.accounting.setRequiredStages(stages)
        operation.accounting.seed(
            transferredBytes: stagedByteLengths,
            expectedBytes: knownExpectedBytes,
            estimatedBytes: estimatedExpectedBytes
        )
        operations[id] = operation
        publishSnapshot(id: id, token: token, operation: operation)
        let snapshot = operation.accounting.snapshot
        PlayerLog.log(
            "[Download] progress denominator id=\(id) " +
                "stages=\(stages.map(\.rawValue).joined(separator: "+")) " +
                "measured=\(knownExpectedBytes.count) estimated=\(estimatedExpectedBytes.count) " +
                "total=\(snapshot.expectedBytes.map(String.init) ?? "unknown") " +
                "isEstimated=\(snapshot.fractionIsEstimated)"
        )
    }

    private func beginStage(
        id: String,
        token: UUID,
        stage: DownloadStage
    ) -> UInt64? {
        guard var operation = operations[id], operation.token == token else { return nil }
        operation.stageGenerationCounter &+= 1
        let generation = operation.stageGenerationCounter
        operation.acceptingCallbacks = true
        operation.callbackFence.beginStage(stage, generation: generation)
        operation.accounting.beginStage(stage)
        operations[id] = operation
        publishSnapshot(id: id, token: token, operation: operation)
        return generation
    }

    private func completeStage(
        id: String,
        token: UUID,
        stage: DownloadStage,
        actualBytes: Int64
    ) {
        guard var operation = operations[id], operation.token == token else { return }
        operation.callbackFence.endStage(stage)
        operation.stagePhases[stage] = nil
        operation.accounting.completeStage(stage, actualBytes: actualBytes)
        operations[id] = operation
        publishSnapshot(id: id, token: token, operation: operation)
        if let combined = resolvedStagePhase(for: operation) {
            updatePhase(id: id, token: token, combined)
        }
    }

    private func setStagePhase(
        id: String,
        token: UUID,
        stage: DownloadStage,
        phase: ActiveDownload.Phase
    ) {
        guard var operation = operations[id], operation.token == token else { return }
        operation.stagePhases[stage] = phase
        operations[id] = operation
        if let combined = resolvedStagePhase(for: operation) {
            updatePhase(id: id, token: token, combined)
        }
    }

    private func resolvedStagePhase(for operation: Operation) -> ActiveDownload.Phase? {
        if let videoPhase = operation.stagePhases[.video] {
            if videoPhase == .downloadingVideo { return .downloadingVideo }
            if operation.stagePhases[.audio] == .downloadingAudio { return .downloadingAudio }
            return videoPhase
        }
        return operation.stagePhases[.audio]
    }

    private static let progressPublishMinimumInterval: TimeInterval = 0.20

    private func applySegmentedProgress(
        id: String,
        token: UUID,
        stage: DownloadStage,
        stageGeneration: UInt64,
        transferredBytes: Int64,
        expectedBytes: Int64
    ) {
        guard var operation = operations[id],
              operation.token == token,
              operation.acceptingCallbacks,
              operation.callbackFence.isAccepting(stage, generation: stageGeneration)
        else { return }

        operation.accounting.update(
            stage: stage,
            transferredBytes: transferredBytes,
            expectedBytes: expectedBytes
        )
        operation.stagePhases[stage] = stage == .video ? .downloadingVideo : .downloadingAudio
        let combined = resolvedStagePhase(for: operation)
        let reachedStageEnd = expectedBytes > 0 && transferredBytes >= expectedBytes
        publishSnapshot(
            id: id,
            token: token,
            operation: &operation,
            phase: combined,
            force: reachedStageEnd
        )
        operations[id] = operation
    }

    private func applySegmentedCheckpoint(
        id: String,
        token: UUID,
        stage: DownloadStage,
        ranges: [DownloadByteRange],
        totalBytes: Int64
    ) {
        if var operation = operations[id], operation.token == token {
            operation.manifest.setCompletedRanges(ranges, for: stage)
            operation.manifest.setExpected(stage, bytes: totalBytes)
            operations[id] = operation
            try? DownloadStore.writeManifest(operation.manifest, folder: operation.stagingFolder)
            return
        }
        // If paused right before the final checkpoint arrived, preserve `userPaused` while persisting ranges.
        // If cancelled, the staging folder was already deleted so `readManifest` returns nil.
        let folder = DownloadStore.stagingFolder(contentID: id)
        guard var onDisk = DownloadStore.readManifest(folder: folder) else { return }
        onDisk.setCompletedRanges(ranges, for: stage)
        onDisk.setExpected(stage, bytes: totalBytes)
        try? DownloadStore.writeManifest(onDisk, folder: folder)
        if let index = active.firstIndex(where: { $0.id == id && $0.phase == .paused }) {
            let staged = DownloadStore.effectiveStagedBytes(manifest: onDisk, folder: folder)
            active[index].bytesTransferred = staged
            active[index].expectedBytes = onDisk.totalExpectedBytes
            active[index].fraction = ActiveDownload.seededFraction(
                bytesTransferred: staged,
                expectedBytes: onDisk.totalExpectedBytes
            )
        }
    }

    private func applyTransferEvent(id: String, event: DownloadTransferEvent) {
        guard var operation = operations[id],
              operation.token == event.operationToken,
              operation.acceptingCallbacks,
              case .single(let stageDownloader) = operation.stageDownloaders[event.stage],
              stageDownloader.accepts(event)
        else { return }

        let previousCandidate = operation.callbackFence.candidateGeneration(for: event.stage)
        guard operation.callbackFence.accepts(event) else { return }
        let candidateChanged = event.candidateGeneration > previousCandidate
        if candidateChanged {
            operation.accounting.beginCandidate(
                event.stage,
                retrying: event.candidateGeneration > 1,
                resumedFromBytes: event.kind == .candidateStarted
                    ? event.bytesTransferred
                    : 0
            )
        }
        if event.kind == .progress {
            operation.accounting.update(
                stage: event.stage,
                transferredBytes: event.bytesTransferred,
                expectedBytes: event.expectedBytes
            )
        }
        let stagePhase: ActiveDownload.Phase
        switch event.stage {
        case .video:
            stagePhase = event.kind == .candidateStarted && event.candidateGeneration > 1
                ? .retryingVideo : .downloadingVideo
        case .audio:
            stagePhase = event.kind == .candidateStarted && event.candidateGeneration > 1
                ? .retryingAudio : .downloadingAudio
        }
        operation.stagePhases[event.stage] = stagePhase
        let combined = resolvedStagePhase(for: operation)
        let isStateTransition = candidateChanged || event.kind != .progress
        publishSnapshot(
            id: id,
            token: event.operationToken,
            operation: &operation,
            phase: combined,
            force: isStateTransition
        )
        operations[id] = operation
    }

    private func updateQuality(id: String, token: UUID, code: Int) {
        guard isCurrent(id: id, token: token),
              let index = active.firstIndex(where: { $0.id == id }),
              active[index].qualityCode != code
        else { return }
        active[index].qualityCode = code
        active[index].qualityLabel = PlayerViewModel.qualityLabel(for: code)
    }

    private func updatePhase(id: String, token: UUID, _ phase: ActiveDownload.Phase) {
        guard isCurrent(id: id, token: token),
              let index = active.firstIndex(where: { $0.id == id })
        else { return }
        if var operation = operations[id], operation.token == token {
            switch phase {
            case .validating, .committing, .failed(_), .paused:
                operation.acceptingCallbacks = false
                operation.callbackFence.closeAll()
                operation.accounting.markTerminal()
            default:
                break
            }
            publishSnapshot(id: id, token: token, operation: &operation, phase: phase, force: true)
            operations[id] = operation
            return
        }
        if active[index].phase != phase {
            active[index].phase = phase
        }
    }

    private func publishSnapshot(
        id: String,
        token: UUID,
        operation: Operation
    ) {
        var copy = operation
        publishSnapshot(id: id, token: token, operation: &copy, phase: nil, force: true)
        if operations[id]?.token == token {
            operations[id]?.lastProgressPublishTime = copy.lastProgressPublishTime
        }
    }

    private func publishSnapshot(
        id: String,
        token: UUID,
        operation: inout Operation,
        phase: ActiveDownload.Phase?,
        force: Bool
    ) {
        guard operation.token == token,
              let index = active.firstIndex(where: { $0.id == id })
        else { return }
        let current = active[index]
        let snapshot = operation.accounting.snapshot
        var row = current
        row.bytesTransferred = snapshot.bytesTransferred
        row.expectedBytes = snapshot.expectedBytes
        row.fraction = snapshot.fraction
        row.speedBytesPerSecond = snapshot.speedBytesPerSecond
        row.fractionIsEstimated = snapshot.fractionIsEstimated
        if let phase {
            row.phase = phase
        }
        guard row != current else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if !force {
            let phaseChanged = row.phase != current.phase
            let expectedRevealed = current.expectedBytes == nil && row.expectedBytes != nil
            let reachedCompletion = row.expectedBytes.map { $0 > 0 && row.bytesTransferred >= $0 } ?? false
            if !phaseChanged, !expectedRevealed, !reachedCompletion,
               now.isFinite, operation.lastProgressPublishTime > 0,
               now >= operation.lastProgressPublishTime,
               now - operation.lastProgressPublishTime < Self.progressPublishMinimumInterval {
                return
            }
        }
        if now.isFinite {
            operation.lastProgressPublishTime = now
        }
        active[index] = row
    }

    // MARK: - CDN Filtering & Multi-CDN Ranking

    private static let fallbackCDNMirrors: [CDNService] = [
        .ali, .cos, .hw, .alib, .cosb, .hwb,
    ]

    private func rankDownloadCandidates(
        _ rawURLs: [String],
        stage: DownloadStage
    ) throws -> RankedStageCandidates {
        let admittedRaw = try admittedDownloadURLs(rawURLs, stage: stage.rawValue)
        let parsedAll = admittedRaw.compactMap(Self.normalizedHTTPSURL)
        guard !parsedAll.isEmpty else { throw DownloadError.noUsableCandidate }

        // Exclude PCDN (mcdn.bilivideo) whenever non-PCDN hosts exist.
        let trusted = parsedAll.filter { CDNHostPolicy.admitsVODHost($0) }
        let smartEnabled = SmartCDNSelector.isEnabled
        let selector = SmartCDNSelector.shared

        var trustedPool = trusted
        if trusted.count < parsedAll.count {
            if trusted.isEmpty, let first = parsedAll.first {
                let rewriteServices: [CDNService] = smartEnabled
                    ? (selector.failoverServices(excluding: nil) + Self.fallbackCDNMirrors)
                    : Self.fallbackCDNMirrors
                var seenMirrors: Set<String> = []
                trustedPool = rewriteServices.compactMap { service -> URL? in
                    guard let rewritten = service.safeRewriteURL(first),
                          CDNHostPolicy.admitsVODHost(rewritten),
                          seenMirrors.insert(rewritten.absoluteString).inserted
                    else { return nil }
                    return rewritten
                }
                PlayerLog.log(
                    "[Download] all \(parsedAll.count) \(stage.rawValue) URLs are PCDN — " +
                        "rewrote \(trustedPool.count) non-PCDN mirror(s)"
                )
            } else {
                PlayerLog.log(
                    "[Download] dropped \(parsedAll.count - trusted.count) PCDN \(stage.rawValue) candidate(s)"
                )
            }
        }

        let basePool = trustedPool.isEmpty ? parsedAll : trustedPool
        let primary = preferredDownloadURL(from: basePool, smartEnabled: smartEnabled, selector: selector)
            ?? basePool[0]

        // Build SmartCDN-ranked catalogue for MultiConnectionVODCandidates.
        var orderedCatalogue: [CDNService] = []
        var seenServices: Set<CDNService> = []
        if smartEnabled {
            for service in selector.failoverServices(excluding: nil) where seenServices.insert(service).inserted {
                orderedCatalogue.append(service)
            }
        }
        for service in CDNService.publishableServices + CDNService.allCases
            where seenServices.insert(service).inserted {
            orderedCatalogue.append(service)
        }

        var segmented = MultiConnectionVODCandidates.select(
            primary: primary,
            rawURLs: admittedRaw,
            catalogue: orderedCatalogue
        ) { host in
            selector.excludesPrefetchHost(host)
        }
        // Keep SmartCDN / user-preferred primary at index 0 for initial probe.
        if let primaryHost = CDNHostPolicy.canonicalHost(primary.host()) {
            if let existingIndex = segmented.firstIndex(where: {
                CDNHostPolicy.canonicalHost($0.host()) == primaryHost
            }) {
                let lead = segmented.remove(at: existingIndex)
                segmented.insert(lead, at: 0)
            } else if CDNHostPolicy.admitsVODHost(primary) {
                segmented.insert(primary, at: 0)
            }
        }
        if segmented.isEmpty {
            segmented = basePool
        }

        var verifiedHosts = MultiConnectionVODCandidates.verifiedAPIHosts(rawURLs: admittedRaw)
        for url in segmented {
            if let host = CDNHostPolicy.canonicalHost(url.host()),
               selector.hasSessionReachabilityEvidence(for: host) {
                verifiedHosts.insert(host)
            }
        }

        // Build ordered single-connection fallback URL list (deduplicated).
        var fallbackURLStrings: [String] = []
        var seenURLStrings: Set<String> = []
        func appendFallback(_ url: URL) {
            let value = url.absoluteString
            if seenURLStrings.insert(value).inserted {
                fallbackURLStrings.append(value)
            }
        }
        appendFallback(primary)
        for url in segmented.prefix(5) { appendFallback(url) }
        for url in trustedPool { appendFallback(url) }
        // Only retain original PCDN URLs at the very tail if every non-PCDN host fails.
        for url in parsedAll { appendFallback(url) }

        PlayerLog.log(
            "[Download] candidates stage=\(stage.rawValue) " +
                "primary=\(CDNHostPolicy.diagnosticHost(primary.host())) " +
                "segmented=\(segmented.count) fallback=\(fallbackURLStrings.count)"
        )
        return RankedStageCandidates(
            segmentedURLs: segmented,
            verifiedAPIHosts: verifiedHosts,
            fallbackURLStrings: fallbackURLStrings
        )
    }

    private func preferredDownloadURL(
        from pool: [URL],
        smartEnabled: Bool,
        selector: SmartCDNSelector
    ) -> URL? {
        guard let first = pool.first else { return nil }
        if smartEnabled, let node = selector.nodeForPlayback(),
           let rewritten = node.service.safeRewriteURL(first),
           CDNHostPolicy.admitsVODHost(rewritten) {
            return rewritten
        }
        let cdn = CDNService.current
        switch cdn {
        case .baseUrl:
            return first
        case .backupUrl:
            if let standard = pool.first(where: { $0.port == nil || $0.port == 443 }) {
                return standard
            }
            return pool.dropFirst(1).first ?? first
        default:
            if let rewritten = cdn.safeRewriteURL(first), CDNHostPolicy.admitsVODHost(rewritten) {
                return rewritten
            }
            return first
        }
    }

    private static func normalizedHTTPSURL(_ raw: String) -> URL? {
        let normalized: String
        if raw.hasPrefix("http://") {
            normalized = "https://" + raw.dropFirst("http://".count)
        } else {
            normalized = raw
        }
        return URL(string: normalized)
    }

    private func admittedDownloadURLs(_ rawURLs: [String], stage: String) throws -> [String] {
        let admitted = rawURLs.filter { rawURL in
            let decision = CDNHostPolicy.decision(for: rawURL)
            guard decision.isAllowed else {
                let host = URL(string: rawURL)?.host
                PlayerLog.log(
                    "[Download] rejected stage=\(stage) host=\(CDNHostPolicy.diagnosticHost(host)) " +
                        "reason=\(decision.reason)"
                )
                return false
            }
            return true
        }
        guard !admitted.isEmpty else { throw DownloadError.noUsableCandidate }
        return admitted
    }

    enum DownloadError: LocalizedError {
        case storeUnavailable
        case playURL(String)
        case noStream
        case noUsableCandidate
        case invalidFiles(String)
        case persistence(String)
        case incomplete(stage: String, onDisk: Int64, expected: Int64)
        case unavailable(PlaybackUnavailability)
        case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)

        var errorDescription: String? {
            switch self {
            case .storeUnavailable:
                String(localized: "Download storage is not ready. Try again.")
            case .playURL(let detail):
                String(localized: "Could not prepare the download: \(detail)")
            case .noStream:
                String(localized: "No downloadable stream for this quality.")
            case .noUsableCandidate:
                String(localized: "No supported download URL is available.")
            case .invalidFiles(let detail):
                String(localized: "Downloaded media is invalid: \(detail)")
            case .persistence(let detail):
                String(localized: "Could not save the download: \(detail)")
            case .insufficientStorage(let required, let available):
                Self.outOfSpaceMessage(required: required, available: available)
            case .unavailable(let reason):
                reason.message
            case .incomplete(_, let onDisk, let expected):
                Self.incompleteMessage(onDisk: onDisk, expected: expected)
            }
        }

        private static func incompleteMessage(onDisk: Int64, expected: Int64) -> String {
            let received = ByteCountFormatter.string(fromByteCount: onDisk, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            return String(localized: "Download interrupted at \(received) of \(total). Resume to continue.")
        }

        private static func outOfSpaceMessage(required: Int64, available: Int64) -> String {
            let needed = DownloadStoragePolicy.byteLabel(required)
            let free = DownloadStoragePolicy.byteLabel(available)
            return String(localized: "Not enough space: \(needed) needed, \(free) free.")
        }
    }
}

// MARK: - File store

enum DownloadAssetIntegrity: Equatable {
    case valid
    case missingVideo
    case emptyVideo
    case missingAudio
    case emptyAudio

    var errorDescription: String {
        switch self {
        case .valid: ""
        case .missingVideo: String(localized: "video file is missing")
        case .emptyVideo: String(localized: "video file is empty")
        case .missingAudio: String(localized: "audio file is missing")
        case .emptyAudio: String(localized: "audio file is empty")
        }
    }
}

extension DownloadStore {
    static var stagingDir: URL {
        downloadsDir.appendingPathComponent(".staging", isDirectory: true)
    }

    static func makeStagingDirectory(contentID: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: stagingDir, withIntermediateDirectories: true
        )
        let folder = stagingFolder(contentID: contentID)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true
            )
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = folder
        try? mutable.setResourceValues(values)
        return folder
    }

    static func stagingFolder(contentID: String) -> URL {
        stagingDir.appendingPathComponent(
            DownloadStagingIdentity.folderName(contentID: contentID),
            isDirectory: true
        )
    }

    static func stagedFile(_ stage: DownloadStage, in folder: URL) -> URL {
        folder.appendingPathComponent("\(stage.rawValue).m4s")
    }

    static func stagedByteLengths(
        stages: [DownloadStage],
        folder: URL
    ) -> [DownloadStage: Int64] {
        var lengths: [DownloadStage: Int64] = [:]
        for stage in stages {
            lengths[stage] = FileDownloader.fileLength(stagedFile(stage, in: folder))
        }
        return lengths
    }

    static func effectiveStagedByteLengths(
        manifest: DownloadManifest,
        stages: [DownloadStage],
        folder: URL
    ) -> [DownloadStage: Int64] {
        var lengths: [DownloadStage: Int64] = [:]
        for stage in stages {
            let fileLength = FileDownloader.fileLength(stagedFile(stage, in: folder))
            lengths[stage] = manifest.effectiveDownloadedBytes(for: stage, fileLength: fileLength)
        }
        return lengths
    }

    static func effectiveStagedBytes(
        manifest: DownloadManifest,
        folder: URL
    ) -> Int64 {
        let videoLength = FileDownloader.fileLength(stagedFile(.video, in: folder))
        let audioLength = FileDownloader.fileLength(stagedFile(.audio, in: folder))
        return manifest.effectiveDownloadedBytes(for: .video, fileLength: videoLength)
            + manifest.effectiveDownloadedBytes(for: .audio, fileLength: audioLength)
    }

    static func availableCapacityForImportantUsage() -> Int64? {
        try? downloadsDir
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    static func stagedBytes(contentID: String) -> Int64 {
        let folder = stagingFolder(contentID: contentID)
        return FileDownloader.fileLength(stagedFile(.video, in: folder))
            + FileDownloader.fileLength(stagedFile(.audio, in: folder))
    }

    static func resetStagedMedia(folder: URL) {
        for stage in [DownloadStage.video, .audio] {
            try? FileManager.default.removeItem(at: stagedFile(stage, in: folder))
        }
    }

    // MARK: Manifest

    static func manifestURL(folder: URL) -> URL {
        folder.appendingPathComponent(DownloadManifest.fileName)
    }

    static func writeManifest(_ manifest: DownloadManifest, folder: URL) throws {
        var normalized = manifest
        normalized.version = DownloadManifest.currentVersion
        let data = try JSONEncoder().encode(normalized)
        try data.write(to: manifestURL(folder: folder), options: .atomic)
    }

    static func readManifest(contentID: String) -> DownloadManifest? {
        readManifest(folder: stagingFolder(contentID: contentID))
    }

    static func readManifest(folder: URL) -> DownloadManifest? {
        guard let data = try? Data(contentsOf: manifestURL(folder: folder)),
              let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data),
              manifest.isSupportedVersion
        else { return nil }
        return manifest
    }

    static func removeManifest(folder: URL) {
        try? FileManager.default.removeItem(at: manifestURL(folder: folder))
    }

    static func removeStaging(contentID: String) {
        removeStaging(stagingFolder(contentID: contentID))
    }

    @discardableResult
    static func commit(stagingFolder: URL, contentID: String) throws -> URL {
        let finalFolder = downloadsDir.appendingPathComponent(contentID, isDirectory: true)
        if FileManager.default.fileExists(atPath: finalFolder.path) {
            try FileManager.default.removeItem(at: finalFolder)
        }
        try FileManager.default.moveItem(at: stagingFolder, to: finalFolder)
        return finalFolder
    }

    static func removeStaging(_ folder: URL) {
        guard folder.deletingLastPathComponent().standardizedFileURL
            == stagingDir.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    static func reconcileStaging() -> [DownloadManifest] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var resumable: [DownloadManifest] = []
        for folder in folders {
            let name = folder.lastPathComponent
            guard let manifest = readManifest(folder: folder),
                  DownloadStagingIdentity.matches(
                      folderName: name, contentID: manifest.contentID
                  )
            else {
                do {
                    try FileManager.default.removeItem(at: folder)
                    PlayerLog.log("[Download] staging discarded name=\(name)")
                } catch {
                    PlayerLog.log(
                        "[Download] staging cleanup failed name=\(name) error=\(error.localizedDescription)"
                    )
                }
                continue
            }
            resumable.append(manifest)
        }
        return resumable
    }

    static func integrity(folder: URL, hasSeparateAudio: Bool) -> DownloadAssetIntegrity {
        let video = folder.appendingPathComponent("video.m4s")
        switch mediaFileState(video) {
        case .missing: return .missingVideo
        case .empty: return .emptyVideo
        case .valid: break
        }
        guard hasSeparateAudio else { return .valid }
        let audio = folder.appendingPathComponent("audio.m4s")
        switch mediaFileState(audio) {
        case .missing: return .missingAudio
        case .empty: return .emptyAudio
        case .valid: return .valid
        }
    }

    static func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
            )
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    private enum MediaFileState {
        case missing
        case empty
        case valid
    }

    static func logicalLength(_ url: URL) -> Int64 {
        FileDownloader.fileLength(url)
    }

    private static func mediaFileState(_ url: URL) -> MediaFileState {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ), values.isRegularFile == true
        else { return .missing }
        return (values.fileSize ?? 0) > 0 ? .valid : .empty
    }
}

// MARK: - Transport

enum DownloadTransferError: Error, LocalizedError, Equatable {
    case invalidURL
    case nonHTTP
    case httpStatus(host: String, code: Int)
    case emptyResponse(host: String)
    case incompleteTransfer
    case rangeNotHonoured(host: String)
    case partialFileUnwritable(String)
    case cellularNotAllowed
    case lowDataModeNotAllowed
    case expensiveNetworkNotAllowed
    case outOfSpace

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "The download URL is invalid.")
        case .nonHTTP:
            String(localized: "The download server returned an invalid response.")
        case .httpStatus(let host, let code):
            String(localized: "Download server \(host) returned HTTP \(code).")
        case .emptyResponse(let host):
            String(localized: "Download server \(host) returned an empty file.")
        case .incompleteTransfer:
            String(localized: "The download ended before a file was produced.")
        case .rangeNotHonoured(let host):
            String(localized: "Download server \(host) could not resume this file.")
        case .partialFileUnwritable(let detail):
            String(localized: "Could not write the partial download: \(detail)")
        case .cellularNotAllowed:
            String(localized: "Downloads are set to Wi-Fi only. Turn on Download over Cellular.")
        case .lowDataModeNotAllowed:
            String(localized: "Low Data Mode is on. Turn it off in iOS Settings to download.")
        case .expensiveNetworkNotAllowed:
            String(localized: "This network is metered, so the download was not started.")
        case .outOfSpace:
            String(localized: "The device ran out of space during the download.")
        }
    }
}

enum DownloadRequestPolicy {
    static func makeRequest(
        urlString: String,
        headers: [String: String],
        resumeFromByte: Int64 = 0,
        network: DownloadNetworkPolicy
    ) throws -> URLRequest {
        let normalized: String
        if urlString.hasPrefix("http://") {
            normalized = "https://" + urlString.dropFirst("http://".count)
        } else {
            normalized = urlString
        }
        guard let url = URL(string: normalized) else {
            throw DownloadTransferError.invalidURL
        }
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(max(0, resumeFromByte))-", forHTTPHeaderField: "Range")
        network.apply(to: &request)
        return request
    }
}

enum DownloadStoragePolicy {
    static let reserveBytes: Int64 = 64 * 1024 * 1024

    enum Verdict: Equatable {
        case sufficient
        case insufficient(requiredBytes: Int64, availableBytes: Int64)
        case unknown
    }

    static func verdict(
        availableBytes: Int64?,
        requiredBytes: Int64?,
        alreadyStagedBytes: Int64
    ) -> Verdict {
        guard let availableBytes, let requiredBytes, requiredBytes > 0 else {
            return .unknown
        }
        let staged = max(0, alreadyStagedBytes)
        let outstanding = staged >= requiredBytes ? 0 : requiredBytes - staged
        guard outstanding > 0 else { return .sufficient }
        let (needed, overflow) = outstanding.addingReportingOverflow(reserveBytes)
        guard !overflow else {
            return .insufficient(
                requiredBytes: outstanding,
                availableBytes: max(0, availableBytes)
            )
        }
        return availableBytes >= needed
            ? .sufficient
            : .insufficient(requiredBytes: outstanding, availableBytes: max(0, availableBytes))
    }

    static func requiredBytes(
        expectedBytesByStage: [DownloadStage: Int64],
        requiredStages: [DownloadStage],
        videoBandwidth: Int,
        audioBandwidth: Int?,
        durationSeconds: Int
    ) -> Int64? {
        guard !requiredStages.isEmpty else { return nil }
        var total: Int64 = 0
        for stage in requiredStages {
            let known = expectedBytesByStage[stage].flatMap { $0 > 0 ? $0 : nil }
            let bandwidth: Int? = stage == .video ? videoBandwidth : audioBandwidth
            guard let stageBytes = known ?? bandwidth.flatMap({
                estimatedBytes(
                    videoBandwidth: $0,
                    audioBandwidth: nil,
                    durationSeconds: durationSeconds
                )
            }), stageBytes > 0 else {
                return nil
            }
            let (nextTotal, overflow) = total.addingReportingOverflow(stageBytes)
            guard !overflow else { return nil }
            total = nextTotal
        }
        return total > 0 ? total : nil
    }

    static func estimatedBytesByStage(
        requiredStages: [DownloadStage],
        videoBandwidth: Int,
        audioBandwidth: Int?,
        durationSeconds: Int
    ) -> [DownloadStage: Int64] {
        var result: [DownloadStage: Int64] = [:]
        for stage in requiredStages {
            let bandwidth: Int? = stage == .video ? videoBandwidth : audioBandwidth
            guard let bandwidth, let bytes = estimatedBytes(
                videoBandwidth: bandwidth, audioBandwidth: nil, durationSeconds: durationSeconds
            ), bytes > 0 else { continue }
            result[stage] = bytes
        }
        return result
    }

    static func estimatedBytes(
        videoBandwidth: Int,
        audioBandwidth: Int?,
        durationSeconds: Int
    ) -> Int64? {
        guard durationSeconds > 0, videoBandwidth > 0 else { return nil }
        let (bitsPerSecond, sumOverflow) = Int64(videoBandwidth).addingReportingOverflow(
            Int64(max(0, audioBandwidth ?? 0))
        )
        guard !sumOverflow else { return nil }
        let (bytes, sizeOverflow) = (bitsPerSecond / 8).multipliedReportingOverflow(
            by: Int64(durationSeconds)
        )
        return sizeOverflow ? nil : bytes
    }

    static func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct DownloadNetworkPolicy: Equatable, Sendable {
    static let cellularSettingsKey = "download_over_cellular"
    static let multiConnectionSettingsKey = "download_multi_connection_enabled"

    let allowsCellular: Bool
    let multiConnectionEnabled: Bool

    init(allowsCellular: Bool, multiConnectionEnabled: Bool = true) {
        self.allowsCellular = allowsCellular
        self.multiConnectionEnabled = multiConnectionEnabled
    }

    static var current: DownloadNetworkPolicy {
        let defaults = UserDefaults.standard
        let storedCellular = defaults.object(forKey: cellularSettingsKey) as? Bool
        let storedMulti = defaults.object(forKey: multiConnectionSettingsKey) as? Bool
        return DownloadNetworkPolicy(
            allowsCellular: storedCellular ?? true,
            multiConnectionEnabled: storedMulti ?? true
        )
    }

    func apply(to request: inout URLRequest) {
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = false
    }
}

extension DownloadTransferError {
    static func classify(_ error: Error) -> DownloadTransferError? {
        if let urlError = error as? URLError {
            switch urlError.networkUnavailableReason {
            case .cellular: return .cellularNotAllowed
            case .constrained: return .lowDataModeNotAllowed
            case .expensive: return .expensiveNetworkNotAllowed
            default: break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteOutOfSpaceError {
            return .outOfSpace
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return .outOfSpace
        }
        return nil
    }
}

final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct StageResult: Sendable, Equatable {
        let bytesOnDisk: Int64
        let expectedBytes: Int64?
    }

    private struct Sink {
        let handle: FileHandle
        let destination: URL
        var writeOffset: Int64
        var expectedTotal: Int64?
        var admitted: Bool
    }

    private struct RestartRequest: Error {
        let failure: DownloadTransferError
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var eventCoalescer = DownloadProgressEventCoalescer()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<StageResult, Error>?
    private var eventSink: (@Sendable (DownloadTransferEvent) -> Void)?
    private var operationToken: UUID?
    private var stage: DownloadStage?
    private var stageGeneration: UInt64 = 0
    private var candidateGeneration: UInt64 = 0
    private var sequence: UInt64 = 0
    private var cancelled = false
    private var sink: Sink?
    private var requestedOffset: Int64 = 0
    private var lastLearnedTotal: Int64?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = .shared
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    @discardableResult
    func download(
        urls: [String],
        to destination: URL,
        headers: [String: String],
        label: String,
        operationLabel: String,
        operationToken: UUID,
        stage: DownloadStage,
        stageGeneration: UInt64,
        knownTotalLength: Int64?,
        network: DownloadNetworkPolicy,
        onEvent: @escaping @Sendable (DownloadTransferEvent) -> Void
    ) async throws -> StageResult {
        resetLearnedTotal(knownTotalLength)
        var expectedTotal = knownTotalLength
        var lastError: Error = DownloadTransferError.invalidURL
        var generation: UInt64 = 0
        for (index, candidate) in urls.enumerated() {
            var restarted = false
            while true {
                generation &+= 1
                let bytesOnDisk = Self.fileLength(destination)
                switch DownloadResumePolicy.stagePlan(
                    bytesOnDisk: bytesOnDisk,
                    expectedBytes: expectedTotal
                ) {
                case .complete:
                    PlayerLog.log(
                        "[Download] \(label) already complete bytes=\(bytesOnDisk) op=\(operationLabel)"
                    )
                    return StageResult(bytesOnDisk: bytesOnDisk, expectedBytes: expectedTotal)
                case .restart:
                    if bytesOnDisk > 0 {
                        PlayerLog.log(
                            "[Download] \(label) discarding \(bytesOnDisk)B partial " +
                                "(expected \(expectedTotal.map(String.init) ?? "unknown")) op=\(operationLabel)"
                        )
                        try Self.truncate(destination)
                    }
                case .resume(let fromByte):
                    PlayerLog.log(
                        "[Download] \(label) resuming at \(fromByte)B of " +
                            "\(expectedTotal.map(String.init) ?? "unknown") op=\(operationLabel)"
                    )
                }

                let resumeFrom = max(0, Self.fileLength(destination))
                do {
                    let request = try DownloadRequestPolicy.makeRequest(
                        urlString: candidate,
                        headers: headers,
                        resumeFromByte: resumeFrom,
                        network: network
                    )
                    let host = request.url?.host ?? "unknown"
                    PlayerLog.log(
                        "[Download] \(label) candidate=\(index + 1)/\(urls.count) host=\(host) " +
                            "from=\(resumeFrom)B op=\(operationLabel)"
                    )
                    let result = try await transferOne(
                        request,
                        destination: destination,
                        operationToken: operationToken,
                        stage: stage,
                        stageGeneration: stageGeneration,
                        candidateGeneration: generation,
                        resumeFromByte: resumeFrom,
                        knownTotalLength: expectedTotal,
                        onEvent: onEvent
                    )
                    PlayerLog.log(
                        "[Download] \(label) received host=\(host) bytes=\(result.bytesOnDisk) " +
                            "of \(result.expectedBytes.map(String.init) ?? "unknown") op=\(operationLabel)"
                    )
                    return result
                } catch {
                    if let restart = error as? RestartRequest {
                        lastError = restart.failure
                        guard !restarted else { break }
                        restarted = true
                        try Self.truncate(destination)
                        expectedTotal = nil
                        resetLearnedTotal(nil)
                        continue
                    }
                    if error.isDownloadCancellation { throw error }
                    lastError = error
                    expectedTotal = learnedExpectedTotal()
                    PlayerLog.log(
                        "[Download] \(label) candidate=\(index + 1)/\(urls.count) failed " +
                            "op=\(operationLabel) error=\(error.localizedDescription)"
                    )
                    break
                }
            }
        }
        throw lastError
    }

    private func resetLearnedTotal(_ total: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        lastLearnedTotal = total
    }

    private func learnedExpectedTotal() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return lastLearnedTotal
    }

    private func transferOne(
        _ request: URLRequest,
        destination: URL,
        operationToken: UUID,
        stage: DownloadStage,
        stageGeneration: UInt64,
        candidateGeneration: UInt64,
        resumeFromByte: Int64,
        knownTotalLength: Int64?,
        onEvent: @escaping @Sendable (DownloadTransferEvent) -> Void
    ) async throws -> StageResult {
        try Task.checkCancellation()
        let handle = try Self.openForAppend(destination)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    try? handle.close()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                task.priority = URLSessionTask.defaultPriority
                self.task = task
                self.operationToken = operationToken
                self.stage = stage
                self.stageGeneration = stageGeneration
                self.candidateGeneration = candidateGeneration
                self.eventSink = onEvent
                self.requestedOffset = resumeFromByte
                self.sink = Sink(
                    handle: handle,
                    destination: destination,
                    writeOffset: resumeFromByte,
                    expectedTotal: knownTotalLength,
                    admitted: false
                )
                sequence &+= 1
                let event = DownloadTransferEvent(
                    operationToken: operationToken,
                    stage: stage,
                    stageGeneration: stageGeneration,
                    candidateGeneration: candidateGeneration,
                    taskIdentifier: task.taskIdentifier,
                    sequence: sequence,
                    bytesTransferred: resumeFromByte,
                    expectedBytes: knownTotalLength,
                    kind: .candidateStarted
                )
                let emitted = eventCoalescer.beginCandidate(event)
                lock.unlock()
                onEvent(emitted)
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func accepts(_ event: DownloadTransferEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
            && operationToken == event.operationToken
            && stage == event.stage
            && stageGeneration == event.stageGeneration
            && candidateGeneration == event.candidateGeneration
            && task?.taskIdentifier == event.taskIdentifier
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        let continuation = self.continuation
        let sink = self.sink
        self.task = nil
        self.continuation = nil
        self.eventSink = nil
        self.sink = nil
        operationToken = nil
        stage = nil
        eventCoalescer.cancel()
        lock.unlock()
        try? sink?.handle.close()
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(DownloadTransferError.nonHTTP), taskIdentifier: dataTask.taskIdentifier)
            return
        }
        let contentLength = response.expectedContentLength > 0
            ? Int64(response.expectedContentLength)
            : nil

        lock.lock()
        guard !cancelled,
              task?.taskIdentifier == dataTask.taskIdentifier,
              var pending = sink
        else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let verdict = DownloadRangeResponsePolicy.verdict(
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: contentLength,
            requestedOffset: requestedOffset,
            knownTotalLength: pending.expectedTotal,
            host: http.url?.host ?? "unknown"
        )

        var failure: Error?
        switch verdict {
        case .append(let offset, let total):
            failure = admitBody(&pending, at: offset, totalLength: total)
        case .replaceFromZero(let total):
            failure = admitBody(&pending, at: 0, totalLength: total)
            if failure == nil, requestedOffset > 0 {
                PlayerLog.log(
                    "[Download] range not honoured at \(requestedOffset)B — restarting from 0"
                )
            }
        case .restartRequest:
            failure = RestartRequest(
                failure: .rangeNotHonoured(host: http.url?.host ?? "unknown")
            )
        case .reject(let error):
            failure = error
        }
        let admittedOffset = sink?.writeOffset ?? 0
        let admittedTotal = sink?.expectedTotal
        if failure == nil { lastLearnedTotal = admittedTotal }
        let admittedSink = failure == nil
        lock.unlock()

        guard admittedSink else {
            completionHandler(.cancel)
            finish(.failure(failure ?? DownloadTransferError.incompleteTransfer),
                   taskIdentifier: dataTask.taskIdentifier)
            return
        }
        completionHandler(.allow)
        emitProgress(
            taskIdentifier: dataTask.taskIdentifier,
            bytes: admittedOffset,
            expected: admittedTotal
        )
    }

    private func admitBody(
        _ pending: inout Sink,
        at offset: Int64,
        totalLength: Int64?
    ) -> Error? {
        do {
            let admittedOffset = max(0, offset)
            try pending.handle.truncate(atOffset: UInt64(admittedOffset))
            try pending.handle.seek(toOffset: UInt64(admittedOffset))
            pending.writeOffset = admittedOffset
            pending.expectedTotal = totalLength ?? pending.expectedTotal
            pending.admitted = true
            sink = pending
            return nil
        } catch {
            return DownloadTransferError.classify(error)
                ?? DownloadTransferError.partialFileUnwritable(error.localizedDescription)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard !cancelled,
              task?.taskIdentifier == dataTask.taskIdentifier,
              var pending = sink,
              pending.admitted
        else {
            lock.unlock()
            return
        }
        var failure: Error?
        do {
            try pending.handle.write(contentsOf: data)
            pending.writeOffset += Int64(data.count)
            sink = pending
        } catch {
            failure = DownloadTransferError.classify(error)
                ?? DownloadTransferError.partialFileUnwritable(error.localizedDescription)
        }
        var emitted: DownloadTransferEvent?
        var sinkToNotify: (@Sendable (DownloadTransferEvent) -> Void)?
        if failure == nil,
           let operationToken,
           let stage,
           let eventSink {
            sequence &+= 1
            let event = DownloadTransferEvent(
                operationToken: operationToken,
                stage: stage,
                stageGeneration: stageGeneration,
                candidateGeneration: candidateGeneration,
                taskIdentifier: dataTask.taskIdentifier,
                sequence: sequence,
                bytesTransferred: max(0, pending.writeOffset),
                expectedBytes: pending.expectedTotal,
                kind: .progress
            )
            emitted = eventCoalescer.offer(event)
            if emitted != nil { sinkToNotify = eventSink }
        }
        lock.unlock()

        if let failure {
            dataTask.cancel()
            finish(.failure(failure), taskIdentifier: dataTask.taskIdentifier)
            return
        }
        if let emitted { sinkToNotify?(emitted) }
    }

    func urlSession(
        _ session: URLSession,
        task completedTask: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(
                .failure(DownloadTransferError.classify(error) ?? error),
                taskIdentifier: completedTask.taskIdentifier
            )
            return
        }
        lock.lock()
        let pending = sink
        lock.unlock()
        guard let pending, pending.admitted else {
            finish(
                .failure(DownloadTransferError.incompleteTransfer),
                taskIdentifier: completedTask.taskIdentifier
            )
            return
        }
        guard pending.writeOffset > 0 else {
            finish(
                .failure(DownloadTransferError.emptyResponse(
                    host: completedTask.response?.url?.host ?? "unknown"
                )),
                taskIdentifier: completedTask.taskIdentifier
            )
            return
        }
        if let expected = pending.expectedTotal,
           pending.writeOffset != expected {
            finish(
                .failure(DownloadTransferError.incompleteTransfer),
                taskIdentifier: completedTask.taskIdentifier
            )
            return
        }
        finish(
            .success(StageResult(
                bytesOnDisk: pending.writeOffset,
                expectedBytes: pending.expectedTotal
            )),
            taskIdentifier: completedTask.taskIdentifier
        )
    }

    // MARK: Event emission

    private func emitProgress(taskIdentifier: Int, bytes: Int64, expected: Int64?) {
        lock.lock()
        guard !cancelled,
              task?.taskIdentifier == taskIdentifier,
              let operationToken,
              let stage,
              let eventSink
        else {
            lock.unlock()
            return
        }
        sequence &+= 1
        let event = DownloadTransferEvent(
            operationToken: operationToken,
            stage: stage,
            stageGeneration: stageGeneration,
            candidateGeneration: candidateGeneration,
            taskIdentifier: taskIdentifier,
            sequence: sequence,
            bytesTransferred: max(0, bytes),
            expectedBytes: expected,
            kind: .progress
        )
        let emitted = eventCoalescer.offer(event)
        lock.unlock()
        if let emitted { eventSink(emitted) }
    }

    private func finish(_ result: Result<StageResult, Error>, taskIdentifier: Int) {
        lock.lock()
        let flush: DownloadTransferEvent?
        let flushSink: (@Sendable (DownloadTransferEvent) -> Void)?
        if task?.taskIdentifier == taskIdentifier {
            flush = eventCoalescer.flush(taskIdentifier: taskIdentifier)
            flushSink = eventSink
        } else {
            flush = nil
            flushSink = nil
        }
        lock.unlock()
        if let flush { flushSink?(flush) }

        lock.lock()
        guard task?.taskIdentifier == taskIdentifier, let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        task = nil
        eventSink = nil
        operationToken = nil
        stage = nil
        let closing = sink
        sink = nil
        lock.unlock()
        try? closing?.handle.synchronize()
        try? closing?.handle.close()
        continuation.resume(with: result)
    }

    // MARK: Partial-file helpers

    static func fileLength(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return max(0, size.int64Value)
    }

    static func truncate(_ url: URL, to offset: Int64 = 0) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(max(0, offset)))
    }

    private static func openForAppend(_ url: URL) throws -> FileHandle {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard manager.createFile(atPath: url.path, contents: nil) else {
                throw DownloadTransferError.partialFileUnwritable(url.lastPathComponent)
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        } catch {
            throw DownloadTransferError.classify(error)
                ?? DownloadTransferError.partialFileUnwritable(error.localizedDescription)
        }
    }
}
private extension Error {
    var isDownloadCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
