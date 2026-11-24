import Foundation
import Observation
import Photos
import Synchronization

@MainActor @Observable
final class DownloadExportCoordinator {
    static let shared = DownloadExportCoordinator()

    private(set) var activeJob: ExportJobView?
    private(set) var artifacts: [ExportArtifact] = []
    private(set) var hasActiveOperation = false
    private(set) var savingArtifactID: UUID?

    @ObservationIgnored private var native: (any DownloadExportNativeBackend)?
    @ObservationIgnored private let rootDirectory: URL
    @ObservationIgnored private let photoSaver: @Sendable (URL) async throws -> Void
    @ObservationIgnored private var lockedSource: DownloadExportSource?
    @ObservationIgnored private var cancellation: ExportCancellation?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var progressRelay: ExportProgressRelay?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        rootDirectory: URL? = nil,
        photoSaver: (@Sendable (URL) async throws -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("SwiftPiliExports", isDirectory: true)
        self.photoSaver = photoSaver ?? Self.defaultSaveVideoToPhotoLibrary
    }

    func configure(native: any DownloadExportNativeBackend) {
        guard self.native == nil else { return }
        self.native = native
        cleanStaleStagingDirectories()
    }

    func sourceIsLocked(downloadID: String) -> Bool {
        lockedSource?.downloadID == downloadID
    }

    func cancelAndWaitForSource(downloadID: String) async {
        guard sourceIsLocked(downloadID: downloadID) else { return }
        cancel()
        guard sourceIsLocked(downloadID: downloadID) else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func source(snapshot: DownloadFileSnapshot, title: String) throws -> DownloadExportSource {
        try DownloadExportSource(snapshot: snapshot, title: title)
    }

    func prepare(source: DownloadExportSource) async throws -> ExportMediaInventory {
        guard let native else { throw ExportFailure.backendUnavailable }
        guard !hasActiveOperation else { throw ExportFailure.busy }
        guard source.filesExist else { throw ExportFailure.sourceUnavailable }
        let token = ExportCancellation()
        return try await withTaskCancellationHandler {
            let info = try await native.probe(source: source, cancellation: token)
            if token.isCancelled || Task.isCancelled { throw ExportFailure.cancelled }
            return info
        } onCancel: {
            token.cancel()
        }
    }

    func start(source: DownloadExportSource, options: ExportOptions) async throws {
        guard let native else { throw ExportFailure.backendUnavailable }
        try options.validate()
        guard source.filesExist else { throw ExportFailure.sourceUnavailable }
        let id = UUID()
        let token = try acquire(source: source, id: id)
        let jobDir = directory(for: id)
        let outputURL = jobDir.appendingPathComponent(options.sanitizedFilename)

        do {
            try prepareJobDirectory(jobDir, sourceBytes: source.sourceByteCount, estimatedBytes: nil)
        } catch {
            removeDirectory(jobDir)
            release(id: id)
            throw error
        }

        operation = Task { [self] in
            await execute(
                id: id,
                source: source,
                options: options,
                outputURL: outputURL,
                jobDirectory: jobDir,
                native: native,
                token: token
            )
        }
    }

    func cancel() {
        guard hasActiveOperation else { return }
        activeJob?.state = .stopping
        cancellation?.cancel()
        progressRelay?.finish(flush: false)
    }

    func dismissInactiveJob() {
        guard !hasActiveOperation else { return }
        activeJob = nil
    }

    func saveToPhotoLibrary(id: UUID) async throws {
        guard savingArtifactID == nil else {
            throw ExportFailure.busy
        }
        guard let artifact = artifacts.first(where: { $0.id == id }) else {
            throw ExportFailure.invalidOutput
        }
        guard FileManager.default.fileExists(atPath: artifact.fileURL.path) else {
            removeArtifact(id: id)
            throw ExportFailure.invalidOutput
        }
        savingArtifactID = id
        defer { if savingArtifactID == id { savingArtifactID = nil } }
        try await photoSaver(artifact.fileURL)
        removeArtifact(id: id)
    }

    func completeExternalSave(id: UUID) {
        guard savingArtifactID != id else { return }
        removeArtifact(id: id)
    }

    func discard(id: UUID) {
        guard savingArtifactID != id else { return }
        removeArtifact(id: id)
    }

    // MARK: - Execution & File Lifecycle

    private func directory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func acquire(source: DownloadExportSource, id: UUID) throws -> ExportCancellation {
        guard !hasActiveOperation, lockedSource == nil else { throw ExportFailure.busy }
        lockedSource = source
        hasActiveOperation = true
        let token = ExportCancellation()
        cancellation = token
        activeJob = ExportJobView(id: id, title: source.title, state: .preparing)
        return token
    }

    private func prepareJobDirectory(_ jobDir: URL, sourceBytes: Int64, estimatedBytes: Int64?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let estimate = estimatedBytes ?? max(Int64(32 * 1024 * 1024), Int64(Double(sourceBytes) * 1.2))
        if let available = try? rootDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           available < estimate {
            throw ExportFailure.diskSpace
        }
        if fm.fileExists(atPath: jobDir.path) {
            try fm.removeItem(at: jobDir)
        }
        try fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
    }

    private func execute(
        id: UUID,
        source: DownloadExportSource,
        options: ExportOptions,
        outputURL: URL,
        jobDirectory: URL,
        native: any DownloadExportNativeBackend,
        token: ExportCancellation
    ) async {
        defer { release(id: id) }
        do {
            let info = try await native.probe(source: source, cancellation: token)
            try checkNotCancelled(token)
            guard options.mode != .original || info.canRemuxOriginal else {
                throw ExportFailure.invalidOutput
            }
            if options.mode == .transcode {
                let recipe = ExportRecipe(codec: options.codec, resolution: options.resolution, color: options.color)
                guard info.recipes.contains(recipe) else {
                    throw ExportFailure.native(String(localized: "This export configuration is unavailable."))
                }
            }
            if let estimated = info.estimatedOutputBytes,
               let available = try? rootDirectory
                   .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                   .volumeAvailableCapacityForImportantUsage,
               available < estimated {
                throw ExportFailure.diskSpace
            }

            activeJob?.state = .exporting
            let relay = ExportProgressRelay { [weak self] fraction in
                guard let self, self.activeJob?.id == id,
                      self.activeJob?.state == .exporting, !token.isCancelled else { return }
                self.activeJob?.progress = fraction
            }
            progressRelay = relay
            defer { relay.finish(flush: false) }

            let result = try await native.execute(
                request: ExportNativeRequest(source: source, options: options, output: outputURL),
                cancellation: token,
                progress: { relay.offer($0) }
            )
            relay.finish(flush: !token.isCancelled)
            try checkNotCancelled(token)

            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard result.validated, size > 0 else {
                throw ExportFailure.invalidOutput
            }

            artifacts.append(
                ExportArtifact(
                    id: id,
                    title: source.title,
                    filename: options.sanitizedFilename,
                    fileURL: outputURL,
                    fileSizeBytes: size
                )
            )
            // Transition cleanly to artifacts list without leaving a duplicate activeJob row.
            activeJob = nil
        } catch {
            removeDirectory(jobDirectory)
            if token.isCancelled || error is CancellationError || error as? ExportFailure == .cancelled {
                activeJob = nil
            } else {
                activeJob?.state = .failed
                activeJob?.error = error.localizedDescription
            }
        }
    }

    private func checkNotCancelled(_ token: ExportCancellation) throws {
        if token.isCancelled || Task.isCancelled {
            throw ExportFailure.cancelled
        }
    }

    private func release(id: UUID) {
        guard lockedSource != nil else { return }
        lockedSource = nil
        hasActiveOperation = false
        cancellation = nil
        operation = nil
        progressRelay?.finish(flush: false)
        progressRelay = nil
        if let current = activeJob, current.id == id, current.state != .failed {
            activeJob = nil
        }
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    private func removeArtifact(id: UUID) {
        artifacts.removeAll { $0.id == id }
        removeDirectory(directory(for: id))
    }

    private func removeDirectory(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    private func cleanStaleStagingDirectories() {
        guard !hasActiveOperation, artifacts.isEmpty else { return }
        let fm = FileManager.default
        guard let staleEntries = try? fm.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ), !staleEntries.isEmpty else { return }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            for entry in staleEntries {
                try? fm.removeItem(at: entry)
            }
        }
    }

    private nonisolated static func defaultSaveVideoToPhotoLibrary(_ fileURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportFailure.photoLibraryDenied
        }
        let created = PhotoCreationFlag()
        try await PHPhotoLibrary.shared().performChanges {
            if PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL) != nil {
                created.markCreated()
            }
        }
        guard created.wasCreated else {
            throw ExportFailure.invalidOutput
        }
    }
}

private final class PhotoCreationFlag: Sendable {
    private let state = Mutex(false)
    func markCreated() { state.withLock { $0 = true } }
    var wasCreated: Bool { state.withLock { $0 } }
}

private final class ExportProgressRelay: Sendable {
    private static let updateInterval: Duration = .milliseconds(100)

    private struct Update: Sendable {
        let fraction: Double?
    }

    private struct State: Sendable {
        var latest: Update?
        var scheduled = false
        var closed = false
    }

    private let state = Mutex(State())
    private let publish: @MainActor @Sendable (Double?) -> Void

    init(publish: @escaping @MainActor @Sendable (Double?) -> Void) {
        self.publish = publish
    }

    func offer(_ fraction: Double) {
        let shouldSchedule = state.withLock { state in
            guard !state.closed else { return false }
            state.latest = Update(fraction: fraction.isFinite ? min(1, max(0, fraction)) : nil)
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [self] in await drain() }
    }

    @MainActor
    private func drain() async {
        while let update = takeLatest() {
            publish(update.fraction)
            do { try await Task.sleep(for: Self.updateInterval) } catch {
                finish(flush: false)
                return
            }
        }
    }

    private func takeLatest() -> Update? {
        state.withLock { state in
            guard !state.closed, let update = state.latest else {
                state.scheduled = false
                return nil
            }
            state.latest = nil
            return update
        }
    }

    @MainActor
    func finish(flush: Bool) {
        let update: Update? = state.withLock { state in
            guard !state.closed else { return nil }
            state.closed = true
            defer { state.latest = nil }
            return state.latest
        }
        if flush, let update { publish(update.fraction) }
    }
}
