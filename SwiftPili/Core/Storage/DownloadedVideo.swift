import CoreGraphics
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

    static func subtitlesDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent("subtitles", isDirectory: true)
    }

    static func subtitlesIndexURL(in folder: URL) -> URL {
        subtitlesDirectory(in: folder).appendingPathComponent("index.json")
    }

    static func danmakuDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent("danmaku", isDirectory: true)
    }

    static func danmakuSegmentURL(in folder: URL, segmentIndex: Int) -> URL {
        danmakuDirectory(in: folder).appendingPathComponent("seg_\(segmentIndex).pb")
    }

    static func danmakuMetadataURL(in folder: URL) -> URL {
        danmakuDirectory(in: folder).appendingPathComponent("metadata.pb")
    }
}

struct OfflineSubtitleTrackEntry: Codable, Equatable, Hashable, Sendable {
    let lan: String
    let lanDoc: String
    let filename: String
}

struct OfflineSubtitleManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let tracks: [OfflineSubtitleTrackEntry]

    init(version: Int = Self.currentVersion, tracks: [OfflineSubtitleTrackEntry]) {
        self.version = version
        self.tracks = tracks
    }
}

private struct BilibiliSubtitleBodyCue: Decodable {
    let from: Double?
    let endTime: Double?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case from
        case endTime = "to"
        case content
    }
}

private struct BilibiliSubtitleBodyFile: Decodable {
    let body: [BilibiliSubtitleBodyCue]?
}

enum OfflineSubtitleSidecar {

    static func sanitizedFilename(for lan: String, existingNames: Set<String> = []) -> String {
        let trimmed = lan.trimmingCharacters(in: .whitespacesAndNewlines)
        var stem = ""
        stem.reserveCapacity(trimmed.count)
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                stem.unicodeScalars.append(scalar)
            }
        }
        if stem.isEmpty {
            stem = "track"
        }
        var candidate = "\(stem).json"
        var suffix = 2
        while existingNames.contains(candidate) {
            candidate = "\(stem)_\(suffix).json"
            suffix += 1
        }
        return candidate
    }

    static func isValidFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains(".."),
              filename != "." else { return false }
        return true
    }

    @discardableResult
    static func saveSubtitleData(
        _ data: Data,
        filename: String,
        in folder: URL
    ) throws -> URL {
        guard isValidFilename(filename) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let dir = DownloadStore.subtitlesDirectory(in: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func saveManifest(
        _ tracks: [OfflineSubtitleTrackEntry],
        in folder: URL
    ) throws {
        let dir = DownloadStore.subtitlesDirectory(in: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = OfflineSubtitleManifest(tracks: tracks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: DownloadStore.subtitlesIndexURL(in: folder), options: .atomic)
    }

    static func loadManifest(in folder: URL) -> [OfflineSubtitleTrackEntry] {
        let indexURL = DownloadStore.subtitlesIndexURL(in: folder)
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let tracks: [OfflineSubtitleTrackEntry]
        if let manifest = try? JSONDecoder().decode(OfflineSubtitleManifest.self, from: data) {
            tracks = manifest.tracks
        } else if let plain = try? JSONDecoder().decode([OfflineSubtitleTrackEntry].self, from: data) {
            tracks = plain
        } else {
            return []
        }
        return tracks.filter { !$0.lan.isEmpty && isValidFilename($0.filename) }
    }

    static func subtitleFileURL(
        for entry: OfflineSubtitleTrackEntry,
        in folder: URL
    ) -> URL? {
        guard isValidFilename(entry.filename) else { return nil }
        let url = DownloadStore.subtitlesDirectory(in: folder).appendingPathComponent(entry.filename)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            return nil
        }
        return url
    }

    static func loadSubtitleItems(in folder: URL) -> [PlayerV2Info.SubtitleBox.SubtitleItem] {
        loadManifest(in: folder).compactMap { entry in
            guard let fileURL = subtitleFileURL(for: entry, in: folder) else { return nil }
            let doc = entry.lanDoc.isEmpty ? entry.lan : entry.lanDoc
            return PlayerV2Info.SubtitleBox.SubtitleItem(
                lan: entry.lan,
                lanDoc: doc,
                subtitleUrl: fileURL.absoluteString
            )
        }
    }

    static func hasSubtitles(in folder: URL) -> Bool {
        !loadSubtitleItems(in: folder).isEmpty
    }

    static func parseBilibiliSubtitleCues(from data: Data) throws -> [PlayerViewModel.SubtitleCue] {
        let parsed = try JSONDecoder().decode(BilibiliSubtitleBodyFile.self, from: data)
        return (parsed.body ?? []).compactMap { cue in
            guard let from = cue.from, let endTime = cue.endTime, let content = cue.content else { return nil }
            return PlayerViewModel.SubtitleCue(from: from, to: endTime, content: content)
        }
    }

    static func loadCues(
        for entry: OfflineSubtitleTrackEntry,
        in folder: URL
    ) throws -> [PlayerViewModel.SubtitleCue] {
        guard let url = subtitleFileURL(for: entry, in: folder) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try parseBilibiliSubtitleCues(from: data)
    }
}

enum OfflineDanmakuSidecar {
    static let segmentDurationSeconds: Double = 360.0
    static let maxSegments = 24

    static func segmentCount(durationSeconds: Int) -> Int {
        let effectiveDuration = max(durationSeconds, 1)
        let rawCount = Int(ceil(Double(effectiveDuration) / segmentDurationSeconds))
        return min(maxSegments, max(1, rawCount))
    }

    @discardableResult
    static func saveSegment(
        _ data: Data,
        segmentIndex: Int,
        in folder: URL
    ) throws -> URL {
        let dir = DownloadStore.danmakuDirectory(in: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = DownloadStore.danmakuSegmentURL(in: folder, segmentIndex: segmentIndex)
        try data.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    static func saveMetadata(
        _ data: Data,
        in folder: URL
    ) throws -> URL {
        let dir = DownloadStore.danmakuDirectory(in: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = DownloadStore.danmakuMetadataURL(in: folder)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func availableSegmentIndices(in folder: URL) -> [Int] {
        let dir = DownloadStore.danmakuDirectory(in: folder)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var indices: [Int] = []
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix("seg_"), name.hasSuffix(".pb") else { continue }
            let start = name.index(name.startIndex, offsetBy: 4)
            let end = name.index(name.endIndex, offsetBy: -3)
            guard let index = Int(name[start..<end]), index >= 1 else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) > 0 else { continue }
            indices.append(index)
        }
        return indices.sorted()
    }

    static func hasDanmaku(in folder: URL) -> Bool {
        !availableSegmentIndices(in: folder).isEmpty
    }
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
    var subtitlesDirectoryURL: URL { DownloadStore.subtitlesDirectory(in: folderURL) }
    var danmakuDirectoryURL: URL { DownloadStore.danmakuDirectory(in: folderURL) }
    var hasOfflineSubtitles: Bool { OfflineSubtitleSidecar.hasSubtitles(in: folderURL) }
    var hasOfflineDanmaku: Bool { OfflineDanmakuSidecar.hasDanmaku(in: folderURL) }

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
    var videoWidth: Int? = nil
    var videoHeight: Int? = nil

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
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
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
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.addedAt = addedAt
    }

    var folderURL: URL { DownloadStore.downloadsDir.appendingPathComponent(folderName, isDirectory: true) }
    var videoFileURL: URL { folderURL.appendingPathComponent("video.m4s") }
    var audioFileURL: URL? {
        hasSeparateAudio ? folderURL.appendingPathComponent("audio.m4s") : nil
    }
    var subtitlesDirectoryURL: URL { DownloadStore.subtitlesDirectory(in: folderURL) }
    var danmakuDirectoryURL: URL { DownloadStore.danmakuDirectory(in: folderURL) }
    var hasOfflineSubtitles: Bool { OfflineSubtitleSidecar.hasSubtitles(in: folderURL) }
    var hasOfflineDanmaku: Bool { OfflineDanmakuSidecar.hasDanmaku(in: folderURL) }

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

    var aspectRatioHint: CGFloat? {
        guard let videoWidth, let videoHeight, videoWidth > 0, videoHeight > 0 else {
            return nil
        }
        let ratio = CGFloat(videoWidth) / CGFloat(videoHeight)
        guard ratio.isFinite, ratio >= 0.15, ratio <= 5.0 else { return nil }
        return ratio
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

    func recordDimensions(width: Int, height: Int, aid: Int, cid: Int) {
        guard width > 0, height > 0, let context = container?.mainContext else { return }
        let targetAid = aid
        let targetCid = cid
        var descriptor = FetchDescriptor<DownloadedVideo>(
            predicate: #Predicate { $0.aid == targetAid && $0.cid == targetCid }
        )
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first,
              row.videoWidth != width || row.videoHeight != height else { return }
        row.videoWidth = width
        row.videoHeight = height
        try? context.save()
    }
}
