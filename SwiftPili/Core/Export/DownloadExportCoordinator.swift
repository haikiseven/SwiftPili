import Foundation
import Observation
import UIKit

@MainActor @Observable
final class DownloadExportCoordinator {
    static let shared = DownloadExportCoordinator()
    private(set) var activeJob: ExportJobView?
    private(set) var artifacts: [ExportArtifact] = []
    private(set) var hasActiveOperation = false
    @ObservationIgnored private var native: (any DownloadExportNativeBackend)?
    @ObservationIgnored private let journal = ExportJobJournal()
    @ObservationIgnored private var lockedSource: DownloadExportSource?
    @ObservationIgnored private var cancellation: ExportCancellation?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var progressRelay: ExportProgressRelay?
    @ObservationIgnored private var savingID: UUID?
    @ObservationIgnored private var savePhase: SavePhase?
    @ObservationIgnored private var discardingIDs: Set<UUID> = []
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var recoveryPending = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private enum SavePhase { case preparing, presented, finishing }

    private init() {}

    func configure(native: any DownloadExportNativeBackend) {
        guard self.native == nil else { return }
        self.native = native
        requestRecovery()
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.requestRecovery() } })
    }

    func sourceIsLocked(downloadID: String) -> Bool { lockedSource?.downloadID == downloadID }

    func cancelAndWaitForSource(downloadID: String) async {
        guard sourceIsLocked(downloadID: downloadID) else { return }
        cancel()
        guard sourceIsLocked(downloadID: downloadID) else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func source(snapshot: DownloadFileSnapshot, title: String) async throws -> DownloadExportSource {
        try checkProtectedData()
        return try await journal.perform { _ in try DownloadExportSource(snapshot: snapshot, title: title) }
    }

    func prepare(source: DownloadExportSource) async throws -> ExportMediaInventory {
        guard let native else { throw ExportFailure.backendUnavailable }
        let id = UUID()
        let token = try acquire(source: source, id: id)
        defer { release(id: id) }
        return try await withTaskCancellationHandler {
            await awaitRecovery()
            try checkAdmission(token)
            try await journal.perform { _ in try source.validate() }
            try checkAdmission(token)
            let info = try await native.probe(source: source, cancellation: token)
            try checkAdmission(token)
            try await journal.perform { _ in try source.validate() }
            try checkAdmission(token)
            return info
        } onCancel: { token.cancel() }
    }

    func start(source: DownloadExportSource, options: ExportOptions) async throws {
        guard let native else { throw ExportFailure.backendUnavailable }
        try options.validate()
        let id = UUID()
        let token = try acquire(source: source, id: id)
        let record = ExportJobRecord(id: id, source: source, options: options, state: .preparing)
        do {
            try await withTaskCancellationHandler {
                await awaitRecovery()
                try checkAdmission(token)
                try await journal.perform { files in
                    try source.validate()
                    try files.create(record, estimate: nil)
                }
                try checkAdmission(token)
            } onCancel: { token.cancel() }
            operation = Task { [self] in
                await execute(record: record, native: native, token: token)
            }
        } catch {
            try? await journal.perform { try $0.discard(id) }
            release(id: id)
            throw error
        }
    }

    func cancel() {
        guard lockedSource != nil else { return }
        activeJob?.state = .stopping
        cancellation?.cancel()
        progressRelay?.finish(flush: false)
    }

    func prepareSave(id: UUID) async throws -> URL {
        guard savingID == nil, !discardingIDs.contains(id),
              UIApplication.shared.applicationState == .active,
              let artifact = artifacts.first(where: { $0.id == id }) else { throw ExportFailure.busy }
        try checkProtectedData()
        savingID = id
        savePhase = .preparing
        do {
            await awaitRecovery()
            try Task.checkCancellation()
            try checkProtectedData()
            let url = try await journal.perform { try $0.prepareHandoff(artifact) }
            try Task.checkCancellation()
            try checkProtectedData()
            guard UIApplication.shared.applicationState == .active else { throw ExportFailure.busy }
            savePhase = .presented
            return url
        } catch {
            try? await journal.perform { try $0.cancelHandoff(id) }
            clearSave(id: id)
            throw error
        }
    }

    func finishSave(id: UUID, destination: URL?) async throws {
        guard savingID == id, savePhase == .presented else { return }
        savePhase = .finishing
        defer { clearSave(id: id) }
        try await journal.perform { files in
            if destination != nil {
                try files.markSaving(id, state: .saved)
                try files.discard(id)
            } else {
                try files.cancelHandoff(id)
            }
        }
        if destination != nil { artifacts.removeAll { $0.id == id } }
    }

    func discard(id: UUID) async throws {
        guard savingID != id, !discardingIDs.contains(id),
              !(hasActiveOperation && activeJob?.id == id) else { throw ExportFailure.busy }
        discardingIDs.insert(id)
        defer {
            discardingIDs.remove(id)
            beginRecoveryIfPossible()
        }
        await awaitRecovery()
        try checkProtectedData()
        try await journal.perform { try $0.discard(id) }
        artifacts.removeAll { $0.id == id }
    }

    private func acquire(source: DownloadExportSource, id: UUID) throws -> ExportCancellation {
        guard lockedSource == nil else { throw ExportFailure.busy }
        try checkProtectedData()
        lockedSource = source
        hasActiveOperation = true
        let token = ExportCancellation()
        cancellation = token
        activeJob = ExportJobView(id: id, title: source.title, state: .preparing)
        return token
    }

    private func checkProtectedData() throws {
        guard UIApplication.shared.isProtectedDataAvailable else { throw ExportFailure.protectedData }
    }

    private func checkAdmission(_ token: ExportCancellation) throws {
        guard !token.isCancelled, !Task.isCancelled else { throw ExportFailure.cancelled }
        try checkProtectedData()
    }

    private func execute(
        record: ExportJobRecord, native: any DownloadExportNativeBackend, token: ExportCancellation
    ) async {
        let id = record.id
        defer { release(id: id) }
        do {
            let info = try await native.probe(source: record.source, cancellation: token)
            try checkAdmission(token)
            guard record.options.mode != .original || info.canRemuxOriginal else { throw ExportFailure.invalidOutput }
            if record.options.mode == .transcode {
                let recipe = ExportRecipe(codec: record.options.codec, resolution: record.options.resolution,
                                          color: record.options.color)
                guard info.recipes.contains(recipe) else {
                    throw ExportFailure.native(String(localized: "This export configuration is unavailable."))
                }
            }
            try await journal.perform { files in
                try record.source.validate()
                try files.checkCapacity(record, estimate: info.estimatedOutputBytes)
                var running = record
                running.state = .exporting
                try files.save(running)
            }
            try checkAdmission(token)
            activeJob?.state = .exporting
            let relay = ExportProgressRelay { [weak self] fraction in
                guard let self, self.activeJob?.id == id,
                      self.activeJob?.state == .exporting, !token.isCancelled else { return }
                self.activeJob?.progress = fraction
            }
            progressRelay = relay
            defer { relay.finish(flush: false) }
            let result = try await native.execute(
                request: ExportNativeRequest(source: record.source, options: record.options,
                                             output: journal.output(id)),
                cancellation: token, progress: { relay.offer($0) }
            )
            relay.finish(flush: !token.isCancelled)
            try checkAdmission(token)
            guard result.validated else { throw ExportFailure.invalidOutput }
            let artifact = try await journal.perform { files in
                try record.source.validate()
                return try files.finalize(record)
            }
            try checkAdmission(token)
            artifacts.append(artifact)
            activeJob?.progress = 1
            activeJob?.state = .readyToSave
        } catch {
            activeJob?.state = token.isCancelled ? .cancelled : .failed
            activeJob?.error = error.localizedDescription
            try? await journal.perform { try $0.discard(id) }
        }
    }

    private func release(id: UUID) {
        guard activeJob?.id == id else { return }
        lockedSource = nil
        hasActiveOperation = false
        cancellation = nil
        operation = nil
        progressRelay?.finish(flush: false)
        progressRelay = nil
        if activeJob?.state == .preparing || activeJob?.state == .stopping { activeJob = nil }
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
        beginRecoveryIfPossible()
    }

    private func clearSave(id: UUID) {
        guard savingID == id else { return }
        savingID = nil
        savePhase = nil
        beginRecoveryIfPossible()
    }

    private func awaitRecovery() async {
        while let recovery { await recovery.value }
    }

    private func requestRecovery() {
        recoveryPending = true
        beginRecoveryIfPossible()
    }

    private func beginRecoveryIfPossible() {
        guard recoveryPending, recovery == nil, lockedSource == nil,
              savingID == nil, discardingIDs.isEmpty,
              UIApplication.shared.isProtectedDataAvailable else { return }
        recoveryPending = false
        recovery = Task { [self] in
            do {
                let recovered = try await journal.perform { try $0.recover() }
                artifacts = recovered
            } catch {
                if !(error is ExportFailure) { activeJob?.error = error.localizedDescription }
            }
            recovery = nil
            beginRecoveryIfPossible()
        }
    }
}

private final class ExportProgressRelay: @unchecked Sendable {
    private static let updateInterval: Duration = .milliseconds(100)

    private struct Update: Sendable {
        let fraction: Double?
    }

    private let lock = NSLock()
    private var latest: Update?
    private var scheduled = false
    private var closed = false
    private let publish: @MainActor @Sendable (Double?) -> Void

    init(publish: @escaping @MainActor @Sendable (Double?) -> Void) {
        self.publish = publish
    }

    func offer(_ fraction: Double) {
        let shouldSchedule = lock.withLock {
            guard !closed else { return false }
            latest = Update(fraction: fraction.isFinite ? min(1, max(0, fraction)) : nil)
            guard !scheduled else { return false }
            scheduled = true
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
        lock.withLock {
            guard !closed, let update = latest else {
                scheduled = false
                return nil
            }
            latest = nil
            return update
        }
    }

    @MainActor
    func finish(flush: Bool) {
        let update: Update? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer { latest = nil }
            return latest
        }
        if flush, let update { publish(update.fraction) }
    }
}
