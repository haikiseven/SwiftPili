import Foundation
import SwiftData

enum DownloadStore {
    static var downloadsLocation: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    static let downloadsDir: URL = {
        var dir = downloadsLocation
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()
}

struct DownloadFileSnapshot: Hashable, Sendable {
    let id: String
    let folderName: String
    let addedAt: Date
    let hasSeparateAudio: Bool
    let verifiedByteLength: Int64

    var folderURL: URL {
        DownloadStore.downloadsLocation.appendingPathComponent(folderName, isDirectory: true)
    }
    var videoFileURL: URL { folderURL.appendingPathComponent("video.m4s") }
    var audioFileURL: URL? { hasSeparateAudio ? folderURL.appendingPathComponent("audio.m4s") : nil }

    var filesExist: Bool {
        DownloadStore.integrity(folder: folderURL, hasSeparateAudio: hasSeparateAudio) == .valid
            && lengthMatchesCommit
    }

    var lengthMatchesCommit: Bool {
        guard verifiedByteLength > 0 else { return true }
        let video = DownloadStore.logicalLength(videoFileURL)
        let audio = audioFileURL.map { DownloadStore.logicalLength($0) } ?? 0
        let total = video.addingReportingOverflow(audio)
        return !total.overflow && total.partialValue == verifiedByteLength
    }

    @concurrent
    static func validSnapshots(in snapshots: [Self]) async throws -> Set<Self> {
        var valid: Set<Self> = []
        for snapshot in snapshots {
            try Task.checkCancellation()
            if snapshot.filesExist { valid.insert(snapshot) }
        }
        try Task.checkCancellation()
        return valid
    }
}

@Model
final class DownloadedVideo {
    @Attribute(.unique) var id: String
    var aid: Int
    var bvid: String
    var cid: Int
    var title: String
    var coverURL: String
    var ownerName: String
    var durationSeconds: Int
    var qualityCode: Int
    var qualityLabel: String
    var codecs: String
    var folderName: String
    var hasSeparateAudio: Bool
    var fileSizeBytes: Int64
    var addedAt: Date
    var verifiedByteLength: Int64 = 0
    var resumePositionSeconds: Int = 0

    init(
        aid: Int,
        bvid: String,
        cid: Int,
        title: String,
        coverURL: String,
        ownerName: String,
        durationSeconds: Int,
        qualityCode: Int,
        qualityLabel: String,
        codecs: String,
        folderName: String,
        hasSeparateAudio: Bool,
        fileSizeBytes: Int64,
        verifiedByteLength: Int64 = 0,
        addedAt: Date = .now
    ) {
        self.id = "\(bvid)_\(cid)"
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.title = title
        self.coverURL = coverURL
        self.ownerName = ownerName
        self.durationSeconds = durationSeconds
        self.qualityCode = qualityCode
        self.qualityLabel = qualityLabel
        self.codecs = codecs
        self.folderName = folderName
        self.hasSeparateAudio = hasSeparateAudio
        self.fileSizeBytes = fileSizeBytes
        self.verifiedByteLength = verifiedByteLength
        self.addedAt = addedAt
    }

    var folderURL: URL { DownloadStore.downloadsDir.appendingPathComponent(folderName, isDirectory: true) }
    var videoFileURL: URL { folderURL.appendingPathComponent("video.m4s") }
    var audioFileURL: URL? {
        hasSeparateAudio ? folderURL.appendingPathComponent("audio.m4s") : nil
    }

    var fileSnapshot: DownloadFileSnapshot {
        .init(
            id: id,
            folderName: folderName,
            addedAt: addedAt,
            hasSeparateAudio: hasSeparateAudio,
            verifiedByteLength: verifiedByteLength
        )
    }

    var filesExist: Bool { fileSnapshot.filesExist }
    var lengthMatchesCommit: Bool { fileSnapshot.lengthMatchesCommit }

    var watchedFraction: Double? {
        guard resumePositionSeconds > 0, durationSeconds > 0 else { return nil }
        return min(max(Double(resumePositionSeconds) / Double(durationSeconds), 0), 1)
    }
}

@MainActor
final class OfflineProgressStore {
    static let shared = OfflineProgressStore()

    var container: ModelContainer?

    private init() {}

    func record(position: Int, aid: Int, cid: Int) {
        guard let context = container?.mainContext else { return }
        let targetAid = aid
        let targetCid = cid
        var descriptor = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.aid == targetAid && $0.cid == targetCid }
        )
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first,
              row.resumePositionSeconds != position else { return }
        row.resumePositionSeconds = position
        try? context.save()
    }
}
