import Foundation
import QuartzCore
import SwiftData
import UIKit

/// Coordinates foreground offline downloads from play-URL acquisition through
/// atomic file commit and SwiftData persistence.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private init() {
        observeAppLifecycle()
    }

    /// Injected from SwiftPiliApp at launch (same container the views @Query).
    var container: ModelContainer? {
        didSet {
            guard container != nil else { return }
            // Reconciliation needs the store: deciding whether a partial is
            // still wanted requires knowing what has already been committed.
            reconcileInterruptedDownloads()
        }
    }
    private var context: ModelContext? { container?.mainContext }

    private let activityState = DownloadActivityState()

    /// In-flight and failed downloads, keyed by "<bvid>_<cid>", newest first.
    private(set) var active: [ActiveDownload] {
        get { activityState.active }
        set { activityState.active = newValue }
        _modify { yield &activityState.active }
    }

    /// Accessory eligibility changes only when in-flight membership changes.
    var hasInFlightDownloads: Bool {
        activityState.hasInFlightDownloads
    }

    private struct Operation {
        let token: UUID
        let stagingFolder: URL
        let downloader: FileDownloader
        var stageGeneration: UInt64 = 0
        var stage: DownloadStage? = nil
        var acceptingCallbacks = true
        var accounting: DownloadProgressAccumulator
        var callbackFence: DownloadCallbackFence
    }

    private var operations: [String: Operation] = [:]
    private var pendingTokens: [String: UUID] = [:]
    /// Transfers halted because the app was suspended, to be continued on the
    /// next foreground. A USER pause is deliberately never in this set:
    /// resuming it automatically would override an explicit choice.
    private var automaticResumeQueue = DownloadAutomaticResumeQueue()
    private var isBackgrounded = UIApplication.shared.applicationState == .background
    private var automaticResumeTask: Task<Void, Never>?
    /// Per-part quality lists, so opening the picker twice does not pay the
    /// playurl round trip twice. Memory-only and short-lived on purpose: the
    /// list is derived from a signed response, and a stale one would offer a
    /// tier the server no longer serves.
    ///
    /// `@ObservationIgnored`: no view reads it, and a cache write must not
    /// invalidate everything observing `active`.
    @ObservationIgnored
    private var qualityCache = DownloadQualityCache()

    struct ActiveDownload: Identifiable, Sendable {
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
        /// Whether `fraction`/`expectedBytes` rest on a bandwidth-derived
        /// estimate rather than on bytes and totals measured off the wire.
        /// See `DownloadProgressSnapshot.fractionIsEstimated`.
        var fractionIsEstimated: Bool
        var phase: Phase

        enum Phase: Sendable, Equatable {
            case preparing
            case downloadingVideo
            case downloadingAudio
            case retryingVideo
            case retryingAudio
            case validating
            case committing
            case failed(String)
            /// Halted with its bytes intact — a user pause, or a transfer
            /// restored from a previous run. Distinct from `.failed`: nothing
            /// went wrong, and resuming needs no error to be cleared.
            case paused

            /// Whether this row can be continued rather than restarted.
            var isResumable: Bool {
                switch self {
                case .failed, .paused: true
                default: false
                }
            }
        }

        /// Determinate fraction from staged bytes and manifest-recorded total (`nil` when unknown or at 0 bytes).
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

    /// Downloadable video tiers for this part (highest first), served from the
    /// session-fenced short-TTL cache before querying `playurl`.
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
        // Query `dash.video` directly rather than reusing `PlayerViewModel`'s `accept_quality`,
        // which lists requestable tiers rather than streams actually delivered for this session.
        let result: PlayURLResult
        do {
            result = try await VideoAPI.getPlayURL(aid: aid, cid: cid, quality: 127, fnval: 4048)
        } catch {
            guard !Task.isCancelled, AuthManager.shared.sessionGeneration == session else {
                throw CancellationError()
            }
            // A refused video is not a download that might work on a second tap.
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
        // The per-tier size the picker shows is derived here, from the same
        // response, so it costs no extra round trip. It resolves the stream and
        // the audio pairing exactly the way `runDownload` will, which is what
        // keeps this number and the storage pre-flight's requirement from
        // contradicting each other on screen.
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

    /// Whether `availableQualities` can answer without touching the network.
    ///
    /// The picker's caller uses it to decide whether it needs to say anything at
    /// all: an immediate answer opens the sheet with no intermediate state, and
    /// only a real round trip deserves a progress indicator. Without this the
    /// choice was "always show a spinner" or "always look frozen".
    func hasImmediateQualityList(aid: Int, cid: Int) -> Bool {
        qualityCache.value(
            for: DownloadQualityCacheKey(
                aid: aid, cid: cid, sessionGeneration: AuthManager.shared.sessionGeneration
            ), now: Date()
        ) != nil
    }

    /// Drop the cached list for one part — used when a download of it discovers
    /// the resolved stream differs from what the list promised.
    func invalidateQualityCache(aid: Int, cid: Int) {
        qualityCache.invalidate(DownloadQualityCacheKey(
            aid: aid, cid: cid, sessionGeneration: AuthManager.shared.sessionGeneration
        ))
    }

    // MARK: - App lifecycle

    /// Suspension is the ordinary interruption, not an error.
    ///
    /// Without this, backgrounding mid-download let iOS kill the transfer and
    /// the row surfaced a raw URLSession failure — a network error message for
    /// something that was not a network problem, on a download the user had done
    /// nothing wrong with. Pausing first keeps the bytes, keeps the phase
    /// honest, and records which rows the system stopped so foreground can
    /// continue exactly those.
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
        let running = Array(operations.keys)
        guard !running.isEmpty else { return }
        automaticResumeQueue.enqueue(running)
        for id in running { halt(id: id) }
        PlayerLog.log("[Download] suspended \(running.count) transfer(s) for backgrounding")
    }

    private func resumeDownloadsSuspendedByBackgrounding() {
        isBackgrounded = false
        scheduleAutomaticResumes()
    }

    private func scheduleAutomaticResumes() {
        guard !isBackgrounded, automaticResumeTask == nil,
              !automaticResumeQueue.isEmpty else { return }
        automaticResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.automaticResumeTask = nil }
            while let id = self.automaticResumeQueue.takeNext(
                isBackgrounded: self.isBackgrounded
            ) {
                guard self.active.contains(where: { $0.id == id && $0.phase == .paused }),
                      DownloadStore.readManifest(contentID: id)?.allowsAutomaticResume == true
                else { continue }
                await self.resumeDownload(id: id)
            }
        }
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
        // A staging folder for this content may already hold bytes from an
        // interrupted attempt. Its manifest is the plan of record; a fresh
        // request at a DIFFERENT quality supersedes it, because the partial
        // bytes belong to the old encode.
        var manifest = DownloadStore.readManifest(contentID: id)
        if let existingManifest = manifest, existingManifest.requestedQuality != quality {
            PlayerLog.log(
                "[Download] discarding partial id=\(id) — quality changed " +
                    "\(existingManifest.requestedQuality) → \(quality)"
            )
            DownloadStore.removeStaging(contentID: id)
            manifest = nil
        }
        let plan = manifest ?? DownloadManifest(
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
        await runDownload(plan, presentAs: .preparing)
    }

    /// Continues a download whose partial bytes are already on disk — an
    /// interrupted transfer, a relaunch, or a user-paused row.
    func resumeDownload(id: String) async {
        guard !operations.keys.contains(id), pendingTokens[id] == nil else {
            PlayerLog.log("[Download] resume ignored — already running id=\(id)")
            return
        }
        guard var manifest = DownloadStore.readManifest(contentID: id) else {
            PlayerLog.log("[Download] resume unavailable — no manifest id=\(id)")
            active.removeAll { $0.id == id }
            return
        }
        guard existing(bvid: manifest.bvid, cid: manifest.cid) == nil else {
            // It finished through another path; the staging bytes are dead.
            DownloadStore.removeStaging(contentID: id)
            active.removeAll { $0.id == id }
            return
        }
        automaticResumeQueue.revoke(id)
        manifest.userPaused = false
        do {
            try DownloadStore.writeManifest(manifest, folder: DownloadStore.makeStagingDirectory(contentID: id))
        } catch {
            PlayerLog.log("[Download] cannot persist resume intent id=\(id) error=\(error)")
            return
        }
        await runDownload(manifest, presentAs: .preparing)
    }

    /// Halt a transfer but keep its bytes. Unlike `cancel`, the staging folder
    /// and its manifest survive, so the row stays resumable.
    func pause(id: String) {
        // Persist first. If the process dies after this write but before halt,
        // reconciliation still observes the user's pause and cannot restart it.
        guard var manifest = DownloadStore.readManifest(contentID: id) else {
            PlayerLog.log("[Download] pause ignored — no manifest id=\(id)")
            return
        }
        manifest.userPaused = true
        do {
            try DownloadStore.writeManifest(
                manifest, folder: DownloadStore.makeStagingDirectory(contentID: id)
            )
        } catch {
            // Keep the current transfer honest if durable pause authority could
            // not be recorded. Halting first would let relaunch resume it.
            PlayerLog.log("[Download] cannot persist pause intent id=\(id) error=\(error)")
            return
        }
        automaticResumeQueue.revoke(id)
        halt(id: id)
    }

    /// The mechanics of stopping without discarding. Separate from `pause` so
    /// backgrounding can stop a transfer without clearing the very flag that
    /// records that it needs restarting.
    private func halt(id: String) {
        let operation = operations.removeValue(forKey: id)
        pendingTokens[id] = nil
        operation?.downloader.cancel()
        operation?.downloader.invalidate()
        if let index = active.firstIndex(where: { $0.id == id }) {
            active[index].phase = .paused
            active[index].speedBytesPerSecond = nil
        }
        PlayerLog.log("[Download] paused id=\(id) bytes=\(DownloadStore.stagedBytes(contentID: id))")
    }

    private func runDownload(
        _ plan: DownloadManifest,
        presentAs initialPhase: ActiveDownload.Phase
    ) async {
        let id = plan.contentID
        let token = UUID()
        let tokenLabel = String(token.uuidString.prefix(8))
        pendingTokens[id] = token
        let stagedBytes = DownloadStore.stagedBytes(contentID: id)
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
            // `plan.totalExpectedBytes` is the manifest's own measured total
            // (both stages' totals learned off the wire by a previous run) —
            // never an estimate, so the row starts out honestly measured.
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
        var operation: Operation?
        defer {
            operation?.downloader.invalidate()
            if operations[id]?.token == token {
                operations[id] = nil
            }
            if pendingTokens[id] == token {
                pendingTokens[id] = nil
            }
        }
        do {
            guard let context else { throw DownloadError.storeUnavailable }

            let stagingFolder = try DownloadStore.makeStagingDirectory(contentID: id)
            try DownloadStore.writeManifest(manifest, folder: stagingFolder)
            let downloader = FileDownloader()
            let created = Operation(
                token: token,
                stagingFolder: stagingFolder,
                downloader: downloader,
                accounting: DownloadProgressAccumulator(requiredStages: [.video]),
                callbackFence: DownloadCallbackFence(operationToken: token)
            )
            operation = created
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

            // Exact quality first, then best available at/below it, then best
            // overall. Multiple codecs can share a quality; the server's first
            // supported stream remains the compatibility choice.
            let requested = manifest.requestedQuality
            let video = dash.video.first(where: { $0.id == requested })
                ?? dash.video.filter { $0.id <= requested }.max(by: { $0.id < $1.id })
                ?? dash.video.max(by: { $0.id < $1.id })
            guard let video else { throw DownloadError.noStream }
            let audio = dash.audio?.max(by: { $0.bandwidth < $1.bandwidth })

            // The partial bytes on disk belong to a specific encode. A refetch
            // that resolved a DIFFERENT one cannot be appended to them — the
            // file would splice two objects — so the partial is discarded and
            // this attempt starts clean under the new encode.
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
            }
            manifest.resolvedQuality = video.id
            manifest.codecs = video.codecs
            manifest.hasSeparateAudio = audio != nil
            try? DownloadStore.writeManifest(manifest, folder: stagingFolder)

            // Admit every base/backup candidate before a downloader or stage
            // side effect. Keep the original strings for allowed signed URLs;
            // only the host decision is normalized.
            let videoURLs = try admittedDownloadURLs(video.allURLs, stage: "video")
            let audioURLs = try audio.map {
                try admittedDownloadURLs($0.allURLs, stage: "audio")
            }
            let requiredStages: [DownloadStage] = audio == nil ? [.video] : [.video, .audio]
            let networkPolicy = DownloadNetworkPolicy.current

            // Disk pre-flight, BEFORE the first byte is requested.
            //
            // Apple: "Before you try to store a large amount of data locally,
            // first verify that you have sufficient storage capacity", and the
            // key to ask is decided by intent — "If you're storing data based
            // on a user request… query against
            // `volumeAvailableCapacityForImportantUsageKey`". A video the user
            // just tapped Download on is exactly that; the opportunistic key is
            // for speculative prefetch this app does not do.
            //
            // Prefer exact per-stage lengths learned by an earlier attempt.
            // When a split manifest knows video but not audio, only the
            // unknown audio stage is estimated from its bandwidth and duration;
            // falling back to the whole-asset estimate would charge for video
            // twice. The exact check arrives later and for free: a write that
            // runs out of space fails with a distinguishable error either way.
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
                alreadyStagedBytes: DownloadStore.stagedBytes(contentID: id)
            )
            if case let .insufficient(required, available) = storage {
                throw DownloadError.insufficientStorage(
                    requiredBytes: required, availableBytes: available
                )
            }
            // Hand the accumulator what the manifest and the staged files
            // already know. It is constructed empty, and publishing that blank
            // snapshot is what used to wipe the percentage the row had just
            // been seeded with — the seed and this come from the same two
            // sources, so after this they agree instead of fighting.
            //
            // The third source — a per-stage bandwidth × duration estimate —
            // is what lets the whole-asset fraction be determinate for the
            // 85–95% of a download that used to have no aggregate at all: a
            // stage without a measured total yet still contributes a stated
            // denominator, honestly flagged via `fractionIsEstimated` once it
            // is the reason the whole figure isn't fully measured.
            configureRequiredStages(
                id: id, token: token, stages: requiredStages,
                knownExpectedBytes: manifest.expectedBytesByStage,
                stagedByteLengths: DownloadStore.stagedByteLengths(
                    stages: requiredStages, folder: stagingFolder
                ),
                estimatedExpectedBytes: DownloadStoragePolicy.estimatedBytesByStage(
                    requiredStages: requiredStages,
                    videoBandwidth: video.bandwidth,
                    audioBandwidth: audio?.bandwidth,
                    durationSeconds: manifest.durationSeconds
                )
            )
            updateQuality(id: id, token: token, code: video.id)
            if video.id != manifest.requestedQuality {
                // The picker offered a tier the server did not resolve, so the
                // list it offered is provably wrong for this part. Drop it so
                // the next open re-asks instead of promising the same tier
                // again.
                invalidateQualityCache(aid: manifest.aid, cid: manifest.cid)
            }

            for stage in requiredStages {
                guard isCurrent(id: id, token: token) else { throw CancellationError() }
                guard let stageGeneration = beginStage(
                    id: id, token: token, stage: stage
                ) else { throw CancellationError() }
                updatePhase(
                    id: id, token: token,
                    stage == .video ? .downloadingVideo : .downloadingAudio
                )
                let stageResult = try await downloader.download(
                    urls: stage == .video ? videoURLs : audioURLs!,
                    to: DownloadStore.stagedFile(stage, in: stagingFolder),
                    headers: Self.requestHeaders,
                    label: stage.rawValue,
                    operationLabel: tokenLabel,
                    operationToken: token,
                    stage: stage,
                    stageGeneration: stageGeneration,
                    knownTotalLength: manifest.expected(stage),
                    // Read ONCE, above, for the whole download. Re-reading per
                    // request would let a toggle flipped mid-transfer produce a
                    // download whose video stage obeyed one policy and whose
                    // audio stage obeyed another.
                    network: networkPolicy
                ) { [weak self] event in
                    Task { @MainActor in
                        self?.applyTransferEvent(id: id, event: event)
                    }
                }
                guard isCurrent(id: id, token: token) else { throw CancellationError() }
                if let learned = stageResult.expectedBytes {
                    manifest.setExpected(stage, bytes: learned)
                    try? DownloadStore.writeManifest(manifest, folder: stagingFolder)
                }
                completeStage(
                    id: id, token: token, stage: stage,
                    actualBytes: stageResult.bytesOnDisk
                )
            }

            guard isCurrent(id: id, token: token) else { throw CancellationError() }
            updatePhase(id: id, token: token, .validating)

            // Two independent gates, and the ORDER matters. Structural
            // integrity answers "is a usable file there at all"; completeness
            // answers "is all of it there". A short-but-non-empty file passes
            // the first and used to commit — which is exactly how a truncated
            // download became a library entry that plays part-way and then
            // stalls with nothing left to load.
            let integrity = DownloadStore.integrity(
                folder: stagingFolder, hasSeparateAudio: audio != nil
            )
            guard integrity == .valid else {
                throw DownloadError.invalidFiles(integrity.errorDescription)
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
                // The origin never stated a length. A non-empty file is all the
                // evidence that exists, so it commits — but unverified, and the
                // log must not imply otherwise.
                PlayerLog.log(
                    "[Download] ⚠️ length unverified id=\(id) stage=\(stage.rawValue) " +
                        "bytes=\(onDisk) — origin stated no total"
                )
            case .short(let stage, let onDisk, let expected):
                // Keep the partial: this is a resumable state, not a corrupt
                // one, and throwing away the bytes would make the next attempt
                // start over.
                throw DownloadError.incomplete(
                    stage: stage.rawValue, onDisk: onDisk, expected: expected
                )
            case .missing(let stage):
                // Reuse the structural vocabulary rather than minting a
                // parallel one: "the audio file is missing" is the same fact
                // whichever gate noticed it.
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
            // The manifest is staging-only bookkeeping, and it is dropped
            // AFTER the move, not before: removing it first would leave a
            // window in which a crash turns a complete download into a
            // staging folder with no plan — which reconciliation deletes. It
            // travels with the folder and is deleted from the destination,
            // where a stray copy is inert (reconciliation only scans staging).
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
            // The staging folder deliberately SURVIVES a failure now: its bytes
            // are the resume point. Only a user cancel or a superseding encode
            // removes it.
            guard isCurrent(id: id, token: token) else {
                PlayerLog.log("[Download] stale operation ended id=\(id) op=\(tokenLabel)")
                return
            }
            if error.isDownloadCancellation {
                // A cancel that came through `pause` already published the
                // paused row and kept the bytes; `cancel` removed the row.
                if let index = active.firstIndex(where: { $0.id == id }),
                   active[index].phase != .paused {
                    active.remove(at: index)
                }
                PlayerLog.log("[Download] cancelled id=\(id) op=\(tokenLabel)")
            } else {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                updatePhase(id: id, token: token, .failed(message))
                PlayerLog.log(
                    "[Download] failed id=\(id) op=\(tokenLabel) " +
                        "staged=\(DownloadStore.stagedBytes(contentID: id))B error=\(message)"
                )
            }
        }
    }

    /// Restores rows for staging folders with a valid manifest and schedules automatic resumes.
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
            let staged = DownloadStore.stagedBytes(contentID: id)
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
        // Removal IS the cancellation — every callback path guards on `operations[id]`.
        let operation = operations.removeValue(forKey: id)
        pendingTokens[id] = nil
        automaticResumeQueue.revoke(id)
        active.removeAll { $0.id == id }
        operation?.downloader.cancel()
        // A user cancel is the one path that discards partial bytes.
        DownloadStore.removeStaging(contentID: id)
        PlayerLog.log("[Download] user cancelled id=\(id)")
    }

    /// Retry after a failure. This RESUMES: the partial bytes are the whole
    /// point of the resume work, and restarting from zero on every retry is
    /// what made a flaky connection unable to finish a large file at all.
    func retry(id: String) {
        guard let item = active.first(where: { $0.id == id }) else { return }
        switch item.phase {
        case .failed, .paused:
            break
        default:
            return
        }
        // An explicit resume is the user taking over from any pending
        // system-suspension restart.
        automaticResumeQueue.revoke(id)
        operations.removeValue(forKey: id)?.downloader.cancel()
        pendingTokens[id] = nil
        Task { await resumeDownload(id: id) }
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
        // The one place the bar's provenance is recorded. A percentage that
        // looks wrong on a device is otherwise indistinguishable from a
        // percentage whose denominator was estimated — and this is the only
        // read `fractionIsEstimated` has, which is what keeps it an honest
        // field rather than a claim nothing checks.
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
        operation.stageGeneration &+= 1
        operation.stage = stage
        operation.acceptingCallbacks = true
        operation.callbackFence.beginStage(stage, generation: operation.stageGeneration)
        operation.accounting.beginStage(stage)
        let generation = operation.stageGeneration
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
        guard var operation = operations[id], operation.token == token,
              operation.stage == stage
        else { return }
        operation.acceptingCallbacks = false
        operation.accounting.completeStage(stage, actualBytes: actualBytes)
        operation.accounting.markTerminal()
        operations[id] = operation
        publishSnapshot(id: id, token: token, operation: operation)
    }

    private func applyTransferEvent(id: String, event: DownloadTransferEvent) {
        guard var operation = operations[id],
              operation.token == event.operationToken,
              operation.acceptingCallbacks,
              operation.downloader.accepts(event)
        else { return }

        let previousCandidate = operation.callbackFence.candidateGeneration
        guard operation.callbackFence.accepts(event) else { return }
        let candidateChanged = event.candidateGeneration > previousCandidate
        if candidateChanged {
            operation.accounting.beginCandidate(
                event.stage,
                retrying: event.candidateGeneration > 1,
                // A candidate-start event carries the absolute resume floor,
                // which is a baseline and not a transfer.
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
        let phase: ActiveDownload.Phase
        switch event.stage {
        case .video:
            phase = event.kind == .candidateStarted && event.candidateGeneration > 1
                ? .retryingVideo : .downloadingVideo
        case .audio:
            phase = event.kind == .candidateStarted && event.candidateGeneration > 1
                ? .retryingAudio : .downloadingAudio
        }
        operation.stage = event.stage
        operations[id] = operation
        updatePhase(id: id, token: event.operationToken, phase)
        publishSnapshot(id: id, token: event.operationToken, operation: operation)
    }

    /// The resolved quality can differ from the requested one (login-gated
    /// tiers, server fallback). The row is created from the request, so it is
    /// corrected here once the server has answered.
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
                operation.accounting.markTerminal()
            default:
                break
            }
            operations[id] = operation
            publishSnapshot(id: id, token: token, operation: operation)
        }
        active[index].phase = phase
    }

    private func publishSnapshot(
        id: String,
        token: UUID,
        operation: Operation
    ) {
        guard operation.token == token,
              let index = active.firstIndex(where: { $0.id == id })
        else { return }
        let snapshot = operation.accounting.snapshot
        var row = active[index]
        row.bytesTransferred = snapshot.bytesTransferred
        row.expectedBytes = snapshot.expectedBytes
        row.fraction = snapshot.fraction
        row.speedBytesPerSecond = snapshot.speedBytesPerSecond
        row.fractionIsEstimated = snapshot.fractionIsEstimated
        active[index] = row
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
        /// Ended short of the object's stated length. Deliberately its own case
        /// rather than `invalidFiles`: the bytes are sound and retained, so the
        /// user-facing wording promises a resume rather than a restart.
        case incomplete(stage: String, onDisk: Int64, expected: Int64)
        /// The server refused this video outright. Distinct from `playURL`: a
        /// deleted or region-locked video is not a request that might work on a
        /// second tap, and the message must say so rather than wrap a code.
        case unavailable(PlaybackUnavailability)
        /// Insufficient volume capacity to store the download; surfaces the required vs. free byte counts.
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

        /// Built here rather than inline because the case above is one arm of a
        /// switch EXPRESSION, which cannot hold statements — and the message
        /// needs two locals to stay a single `String(localized:)` literal.
        ///
        /// That literal is the point. `String(localized:)` takes a
        /// `String.LocalizationValue`, which has no `+`: concatenating pieces
        /// types the argument as `String` and does not compile. It also
        /// destroys the extraction key, so even where a concatenation compiles
        /// the string never reaches the catalogs.
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

    /// Returns the content-keyed staging folder (preserving existing bytes) and marks it excluded from backup.
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
        // Partial media is large and must never enter the user's iCloud/iTunes
        // backup. `downloadsDir` is already excluded, but the flag is per-URL
        // and a freshly created subdirectory does not inherit it.
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

    /// Logical lengths of the staged media, which are the resume offsets.
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

    /// Room the system is willing to give up for content the user asked for.
    ///
    /// `volumeAvailableCapacityForImportantUsage`, not the opportunistic key —
    /// Apple splits them by intent: "If you're storing data based on a user
    /// request or resources the app requires to function properly (for example,
    /// a video the user is about to watch…), query against
    /// `volumeAvailableCapacityForImportantUsageKey`."
    ///
    /// ⚠️ This is a REQUIRED-REASON API. Both capacity keys carry Apple's
    /// fingerprinting notice and must be declared in `PrivacyInfo.xcprivacy`
    /// under `NSPrivacyAccessedAPICategoryDiskSpace`. The reason is `E174.1`,
    /// whose published text is this call site verbatim: "Declare this reason to
    /// check whether there is sufficient disk space to write files… There is an
    /// exception that allows the app to avoid downloading files from a server
    /// when disk space is insufficient." That reason also requires the app to
    /// "behave differently based on disk space in a way that is observable to
    /// users", which `DownloadError.insufficientStorage` is.
    ///
    /// Called from ONE place for that reason: a second call site is a second
    /// thing to keep in agreement with the manifest.
    ///
    /// Returns `nil` when the volume declines to answer. `nil` is not zero —
    /// see `DownloadStoragePolicy.verdict`.
    static func availableCapacityForImportantUsage() -> Int64? {
        try? downloadsDir
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Bytes staged for this content across both possible tracks — the number a
    /// restored row shows before its plan is re-resolved.
    static func stagedBytes(contentID: String) -> Int64 {
        let folder = stagingFolder(contentID: contentID)
        return FileDownloader.fileLength(stagedFile(.video, in: folder))
            + FileDownloader.fileLength(stagedFile(.audio, in: folder))
    }

    /// Discards staged MEDIA while keeping the folder and its manifest — used
    /// when a refetched playurl resolved a different encode.
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
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(folder: folder), options: .atomic)
    }

    static func readManifest(contentID: String) -> DownloadManifest? {
        readManifest(folder: stagingFolder(contentID: contentID))
    }

    static func readManifest(folder: URL) -> DownloadManifest? {
        guard let data = try? Data(contentsOf: manifestURL(folder: folder)),
              let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data),
              manifest.isCurrentVersion
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

    /// Returns valid resumable staging manifests and deletes orphaned staging folders.
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
                // No plan, or a plan that does not match its folder: nothing
                // here can be resumed safely.
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

    /// Logical byte length — the quantity a commit records and a playback
    /// boundary re-checks. Allocated size is block-rounded and would not
    /// compare equal across filesystems.
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
    /// The transfer was refused by this app's own network policy, not by the
    /// network. Apple: when a configuration or request forbids the only
    /// available interface, "any task created from the session fails", and the
    /// error carries `URLError.networkUnavailableReason`.
    ///
    /// This changes what the user is TOLD, not whether Retry is offered — the
    /// row's Retry is gated on `phase.isResumable` and does not consult the
    /// cause. Naming the setting is the point: "Wi-Fi only is on" reaching the
    /// user as a generic transport failure is what made the retry pointless,
    /// not the button's presence.
    case cellularNotAllowed
    case lowDataModeNotAllowed
    case expensiveNetworkNotAllowed
    /// The volume filled up mid-transfer. The pre-flight is an estimate, so
    /// this is the exact answer and it arrives at the moment it matters.
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
        // A range is sent even for a fresh transfer (`bytes=0-`). It is
        // identical to a plain GET for the caller, and it is what makes the
        // object's total length knowable: a range-capable origin answers 206
        // with `Content-Range: bytes 0-N/TOTAL` whether or not it sent a
        // Content-Length. That total is the completion criterion, so learning
        // it on the first request — rather than hoping for a header — is what
        // lets a truncated transfer be recognized instead of committed.
        request.setValue("bytes=\(max(0, resumeFromByte))-", forHTTPHeaderField: "Range")
        network.apply(to: &request)
        return request
    }
}

/// Evaluates volume capacity against estimated or manifest-known download byte requirements.
enum DownloadStoragePolicy {
    /// Small headroom for SwiftData metadata (`volumeAvailableCapacityForImportantUsage` already
    /// accounts for system cushion, and staging-to-final commit is a same-volume rename).
    static let reserveBytes: Int64 = 64 * 1024 * 1024

    enum Verdict: Equatable {
        case sufficient
        case insufficient(requiredBytes: Int64, availableBytes: Int64)
        case unknown
    }

    /// `nil` on either side yields `.unknown` (allowed to proceed); `alreadyStagedBytes` is subtracted.
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

    /// Returns the expected bytes for all required stages. A positive length
    /// learned from the manifest is authoritative for that stage; only a
    /// missing or non-positive length falls back to its own bandwidth estimate.
    /// If an unknown stage cannot be estimated, the whole requirement remains
    /// unknown so storage admission does not pretend that stage is free.
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

    /// Per-stage bandwidth-derived estimate, keyed the same way `requiredBytes`
    /// treats each stage: video's own bandwidth against the duration, audio's
    /// own against the same duration — never one weight applied to a combined
    /// total. This is `DownloadProgressAccumulator`'s third, lowest-priority
    /// denominator tier, reproducing `requiredBytes`' known-else-estimate rule
    /// rather than inventing a parallel one; the caller does not need to check
    /// which stages already have a measured total first — `expected(_:)`
    /// always tries the measured tiers before this one. A stage this cannot
    /// estimate (no bandwidth, or no duration) is simply absent from the
    /// result, which is how "no duration and no bandwidth ⇒ no estimate"
    /// reaches the accumulator.
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

    /// playurl states a bandwidth, never a byte size, so the requirement is
    /// derived. Bandwidth is in BITS per second.
    ///
    /// Returns `nil` rather than 0 when either input is unusable, so an
    /// unknown requirement reaches `verdict` as unknown instead of as "needs
    /// nothing" — which would silently disable the check.
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

/// Which networks a download may use.
///
/// Applied to the REQUEST, not to the session configuration, and that is
/// deliberate twice over. `URLSessionConfiguration`'s own documentation says a
/// session "makes a copy of the configuration settings you provide… Once
/// configured, the session object ignores any changes you make to the
/// URLSessionConfiguration object" — so a runtime toggle cannot live there
/// without rebuilding the session. The request level is legal for loosening
/// nothing and tightening anything: "Any policy specified on the request object
/// is respected unless the session's policy is more restrictive." It also
/// survives a future move to a background session, whose configuration is
/// frozen for the life of an identifier.
struct DownloadNetworkPolicy: Equatable, Sendable {
    /// User setting. Default TRUE, which is today's behaviour — every download
    /// so far has been free to use cellular, and flipping the default would
    /// start failing downloads for cellular-only users who never asked for
    /// that. Apple's own default for `allowsCellularAccess` is also true.
    static let cellularSettingsKey = "download_over_cellular"

    let allowsCellular: Bool

    /// Reads the user's choice. `object(forKey:)` rather than `bool(forKey:)`
    /// because the latter answers `false` for an absent key, which would make
    /// "never chosen" mean "refuse cellular".
    ///
    /// Nonisolated, like `AccentTheme.current` — `UserDefaults` reads are
    /// thread-safe, and `FileDownloader` is not on the main actor.
    static var current: DownloadNetworkPolicy {
        let stored = UserDefaults.standard.object(forKey: cellularSettingsKey) as? Bool
        return DownloadNetworkPolicy(allowsCellular: stored ?? true)
    }

    func apply(to request: inout URLRequest) {
        request.allowsCellularAccess = allowsCellular
        // A personal hotspot is not "cellular" to `allowsCellularAccess`, and it
        // is exactly as metered as the phone sharing it. Apple: "iOS 13
        // considers most cellular networks and personal hotspots expensive." So
        // Wi-Fi-only means both, or the setting has a hole the size of every
        // tethered connection — and `expensiveNetworkNotAllowed` was an
        // unreachable case until this line existed.
        request.allowsExpensiveNetworkAccess = allowsCellular
        // Low Data Mode, refused unconditionally and NOT behind a setting of
        // its own. Apple's guidance on `allowsExpensiveNetworkAccess` says to
        // "prefer basing your app's policy logic around the
        // `allowsConstrainedNetworkAccess` property", and HIG § Settings says
        // to "respect people's systemwide settings and avoid including
        // redundant versions of them in your custom settings area". A whole
        // video is the largest discretionary transfer this app makes, which is
        // the traffic that setting exists to stop.
        //
        // It FAILS rather than waiting — "any task created from the session
        // fails" — so the refusal must reach the user as a policy message
        // naming the setting, which is what `DownloadTransferError` does.
        request.allowsConstrainedNetworkAccess = false
    }
}

extension DownloadTransferError {
    /// Re-labels the failures that are policy or capacity rather than network.
    ///
    /// `URLError.networkUnavailableReason` is documented as non-nil only when
    /// the request was refused by `allowsCellularAccess`,
    /// `allowsConstrainedNetworkAccess` or `allowsExpensiveNetworkAccess` — "If
    /// the error doesn't involve network unavailability, this property is
    /// `nil`" — so this cannot mistake a real connectivity failure for a
    /// policy one. Without it, "Wi-Fi only is on" reached the user as a
    /// generic transport error with a Retry that could never succeed.
    ///
    /// Returns `nil` when the error is not one of these, so the caller keeps
    /// the original rather than flattening everything into a house type.
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
        // Out of space arrives as either a Cocoa write error or the POSIX code
        // underneath it, depending on which layer noticed.
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

/// Appends a ranged HTTP body directly into staging files, reporting absolute progress
/// and walking base/backup CDN candidates in order.
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
        config.networkServiceType = .background
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Transfers one stage into `destination`, continuing any bytes already
    /// there. `knownTotalLength` is the manifest's recorded total, or nil the
    /// first time this stage runs.
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
                        // A file longer than the object it claims to be is not this
                        // object's bytes; truncating is the only honest repair.
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
                    // A candidate that learned the object's length hands that fact
                    // to the next one even though its body failed.
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
        let handle = try Self.openForAppend(destination)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                try? handle.close()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let task = session.dataTask(with: request)
            // Playback shares the connection budget; keep the transfer itself
            // below the streaming player's own fetches.
            task.priority = URLSessionTask.lowPriority
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
        // Close the handle without truncating: the bytes written so far are the
        // resume point, and a user cancel deletes the staging folder wholesale.
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
        // A resumed transfer must publish its absolute floor immediately, or
        // the first progress event would read as a collapse back to zero.
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
            // Anything beyond the admitted offset was never part of the body
            // about to arrive. Truncate before seeking so bytes cannot overlap.
            let admittedOffset = max(0, offset)
            try pending.handle.truncate(atOffset: UInt64(admittedOffset))
            try pending.handle.seek(toOffset: UInt64(admittedOffset))
            pending.writeOffset = admittedOffset
            pending.expectedTotal = totalLength ?? pending.expectedTotal
            pending.admitted = true
            sink = pending
            return nil
        } catch {
            // A full volume surfaces here as a write failure; preserve that
            // classification instead of calling it an unwritable file.
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
            // A full volume surfaces HERE, as a write failure, and it is not
                // an unwritable-file problem the user can do anything about
                // under that name. `classify` keeps its own name.
                failure = DownloadTransferError.classify(error)
                    ?? DownloadTransferError.partialFileUnwritable(error.localizedDescription)
        }
        let bytes = pending.writeOffset
        let expected = pending.expectedTotal
        lock.unlock()

        if let failure {
            dataTask.cancel()
            finish(.failure(failure), taskIdentifier: dataTask.taskIdentifier)
            return
        }
        emitProgress(taskIdentifier: dataTask.taskIdentifier, bytes: bytes, expected: expected)
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
        // Zero bytes on disk after an admitted transfer is an empty object, not
        // a resume that had nothing left to fetch — that case arrives with a
        // non-zero offset already written.
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
        // Flush the coalesced trailing progress while this task is still the
        // authoritative one, so the last cumulative byte count reaches the
        // callback sink before the continuation resumes.
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
        // Durability point: the partial bytes must be on the filesystem before
        // the caller is told this candidate ended, because the caller's next
        // decision (resume, retry, commit) is made from the file's length.
        try? closing?.handle.synchronize()
        try? closing?.handle.close()
        continuation.resume(with: result)
    }

    // MARK: Partial-file helpers

    /// Logical length, which is the resume offset. Allocated size is a
    /// filesystem fact and would be wrong here.
    static func fileLength(_ url: URL) -> Int64 {
        // Ask FileManager on every admission. URL resource values can retain a
        // cached size after `truncate`, which would make the fresh request use
        // the stale pre-truncation Range offset and recreate a corrupt file.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return max(0, size.int64Value)
    }

    static func truncate(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
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
