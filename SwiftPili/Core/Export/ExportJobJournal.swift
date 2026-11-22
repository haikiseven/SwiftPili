import Foundation
import UIKit

struct ExportJobRecord: Codable, Sendable {
    let id: UUID
    let source: DownloadExportSource
    let options: ExportOptions
    var state: ExportJobState
    var validatedFile: ExportFileIdentity?
}

final class ExportJobJournal: Sendable {
    private let queue = DispatchQueue(label: "com.swiftpili.export.files", qos: .userInitiated)
    private let files = ExportJobFiles()

    func output(_ id: UUID) -> URL { files.output(id) }

    func perform<Value: Sendable>(
        _ work: @escaping @Sendable (ExportJobFiles) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [files] in
                continuation.resume(with: Result { try autoreleasepool { try work(files) } })
            }
        }
    }
}

struct ExportJobFiles: Sendable {
    private var manager: FileManager { .default }
    let root: URL

    init() {
        root = URL.applicationSupportDirectory.appendingPathComponent("ExportJobs", isDirectory: true)
    }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func output(_ id: UUID) -> URL { directory(id).appendingPathComponent("partial.mp4") }
    func finalOutput(_ id: UUID) -> URL { directory(id).appendingPathComponent("final.mp4") }
    func scratch(_ id: UUID) -> URL { directory(id).appendingPathComponent("scratch", isDirectory: true) }

    func create(_ record: ExportJobRecord, estimate: Int64?) throws {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try checkCapacity(record, estimate: estimate)
        try manager.createDirectory(at: scratch(record.id), withIntermediateDirectories: true)
        try protect(root)
        try protect(directory(record.id))
        try protect(scratch(record.id))
        try save(record)
    }

    func checkCapacity(_ record: ExportJobRecord, estimate: Int64?) throws {
        let inputBytes = record.source.video.size.addingReportingOverflow(record.source.audio?.size ?? 0)
        let fallback = inputBytes.partialValue.multipliedReportingOverflow(by: 4)
        let estimated = estimate ?? fallback.partialValue
        let validEstimate = estimate != nil || !fallback.overflow
        guard !inputBytes.overflow, validEstimate, estimated > 0 else { throw ExportFailure.diskSpace }
        let reserve = estimated.multipliedReportingOverflow(by: 3)
        guard !reserve.overflow,
              let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage,
              available > reserve.partialValue else { throw ExportFailure.diskSpace }
    }

    func save(_ record: ExportJobRecord) throws {
        let data = try JSONEncoder().encode(record)
        let url = directory(record.id).appendingPathComponent("job.json")
        try data.write(to: url, options: .atomic)
        try protect(url)
    }

    func finalize(_ record: ExportJobRecord) throws -> ExportArtifact {
        let partial = output(record.id)
        guard (try manager.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw ExportFailure.invalidOutput
        }
        var ready = record
        ready.validatedFile = try ExportFileIdentity(url: partial)
        ready.state = .finalized
        try save(ready)
        try manager.moveItem(at: partial, to: finalOutput(record.id))
        try protect(finalOutput(record.id))
        ready.state = .readyToSave
        try save(ready)
        try removeScratch(record.id)
        return artifact(ready)
    }

    func recover() throws -> [ExportArtifact] {
        guard manager.fileExists(atPath: root.path) else { return [] }
        var artifacts: [ExportArtifact] = []
        for url in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard let id = UUID(uuidString: url.lastPathComponent), directory(id) == url else { continue }
            let journalURL = url.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: journalURL),
                  var record = try? JSONDecoder().decode(ExportJobRecord.self, from: data),
                  record.id == id else { continue }
            switch record.state {
            case .finalized, .readyToSave, .saving:
                if try recoverValidatedFile(&record) { artifacts.append(artifact(record)) }
            case .saved, .cancelled, .failed, .interrupted:
                try discard(id)
            default:
                record.state = .interrupted
                try save(record)
                try removeScratch(id)
                try removeInterruptedOutputs(id)
            }
        }
        return artifacts
    }

    func validateArtifact(_ id: UUID) throws {
        let data = try Data(contentsOf: directory(id).appendingPathComponent("job.json"))
        let record = try JSONDecoder().decode(ExportJobRecord.self, from: data)
        guard let proven = record.validatedFile else { throw ExportFailure.invalidOutput }
        let actual = try ExportFileIdentity(url: finalOutput(id))
        guard record.id == id, actual.size == proven.size, actual.modificationDate == proven.modificationDate,
              actual.fileNumber == proven.fileNumber else { throw ExportFailure.invalidOutput }
    }

    func markSaving(_ id: UUID, state: ExportJobState) throws {
        let data = try Data(contentsOf: directory(id).appendingPathComponent("job.json"))
        var record = try JSONDecoder().decode(ExportJobRecord.self, from: data)
        guard record.id == id else { throw ExportFailure.invalidOutput }
        record.state = state
        try save(record)
    }

    func discard(_ id: UUID) throws {
        let url = directory(id)
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
    }

    private func recoverValidatedFile(_ record: inout ExportJobRecord) throws -> Bool {
        guard let proven = record.validatedFile else { return false }
        let final = finalOutput(record.id)
        let partial = output(record.id)
        let existing = manager.fileExists(atPath: final.path) ? final : partial
        guard let actual = try? ExportFileIdentity(url: existing), actual.size == proven.size,
              actual.modificationDate == proven.modificationDate,
              actual.fileNumber == proven.fileNumber else { return false }
        if existing == partial { try manager.moveItem(at: partial, to: final) }
        record.state = .readyToSave
        try save(record)
        return true
    }

    private func removeInterruptedOutputs(_ id: UUID) throws {
        for url in [output(id), finalOutput(id)] where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
    }

    private func removeScratch(_ id: UUID) throws {
        let url = scratch(id)
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
    }

    private func artifact(_ record: ExportJobRecord) -> ExportArtifact {
        ExportArtifact(id: record.id, title: record.source.title,
                       filename: record.options.sanitizedFilename, fileURL: finalOutput(record.id))
    }

    func prepareHandoff(_ artifact: ExportArtifact) throws -> URL {
        try validateArtifact(artifact.id)
        let available = try artifact.fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let size = try ExportFileIdentity(url: artifact.fileURL).size
        guard let available, available > size else { throw ExportFailure.diskSpace }
        let handoff = directory(artifact.id).appendingPathComponent("handoff", isDirectory: true)
        try manager.createDirectory(at: handoff, withIntermediateDirectories: true)
        try protect(handoff)
        let destination = handoff.appendingPathComponent(artifact.filename)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.copyItem(at: artifact.fileURL, to: destination)
        try protect(destination)
        try markSaving(artifact.id, state: .saving)
        return destination
    }

    func cancelHandoff(_ id: UUID) throws {
        try markSaving(id, state: .readyToSave)
        let handoff = directory(id).appendingPathComponent("handoff", isDirectory: true)
        if manager.fileExists(atPath: handoff.path) { try manager.removeItem(at: handoff) }
    }

    private func protect(_ input: URL) throws {
        var url = input
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path
        )
    }
}
