import Foundation
import Observation
import Synchronization

struct ExportFileIdentity: Codable, Sendable, Equatable {
    let path: String
    let size: Int64
    let modificationDate: Date
    let fileNumber: UInt64

    init(url: URL) throws {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              let date = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber else {
            throw ExportFailure.sourceUnavailable
        }
        path = resolved.path
        self.size = size.int64Value
        modificationDate = date
        fileNumber = number.uint64Value
    }

    func validate() throws {
        guard try ExportFileIdentity(url: URL(fileURLWithPath: path)) == self else {
            throw ExportFailure.sourceChanged
        }
    }
}

struct DownloadExportSource: Codable, Sendable, Equatable {
    let downloadID: String
    let title: String
    let video: ExportFileIdentity
    let audio: ExportFileIdentity?

    init(downloadID: String, title: String, video: ExportFileIdentity, audio: ExportFileIdentity?) {
        self.downloadID = downloadID
        self.title = title
        self.video = video
        self.audio = audio
    }

    init(snapshot: DownloadFileSnapshot, title: String) throws {
        guard snapshot.filesExist else { throw ExportFailure.sourceUnavailable }
        downloadID = snapshot.id
        self.title = title
        video = try ExportFileIdentity(url: snapshot.videoFileURL)
        audio = try snapshot.audioFileURL.map { try ExportFileIdentity(url: $0) }
    }

    func validate() throws {
        try video.validate()
        try audio?.validate()
    }
}

enum ExportMode: String, Codable, CaseIterable, Sendable { case original, transcode }
enum ExportVideoCodec: String, Codable, CaseIterable, Sendable { case h264, hevc }
enum ExportResolution: String, Codable, CaseIterable, Sendable { case source, hd720, hd1080, uhd4K }
enum ExportColorMode: String, Codable, CaseIterable, Sendable { case sourceHDR, sdr }

struct ExportOptions: Codable, Sendable, Equatable {
    var filename: String
    var mode: ExportMode
    var codec: ExportVideoCodec
    var resolution: ExportResolution
    var color: ExportColorMode
    var includeAudio: Bool

    var sanitizedFilename: String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let component = filename.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (component as NSString).deletingPathExtension
        return String(stem.prefix(180)) + ".mp4"
    }

    func validate() throws {
        guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sanitizedFilename != ".mp4" else { throw ExportFailure.invalidFilename }
    }
}

struct ExportRecipe: Sendable, Equatable {
    let codec: ExportVideoCodec
    let resolution: ExportResolution
    let color: ExportColorMode
}

struct ExportMediaInventory: Sendable {
    let width: Int
    let height: Int
    let duration: Double
    let videoCodec: String
    let audioCodec: String?
    let hdr: Bool
    let dolbyVisionProfile: Int?
    let recipes: [ExportRecipe]
    let canRemuxOriginal: Bool
    let estimatedOutputBytes: Int64?
}

enum ExportJobState: String, Codable, Sendable {
    case preparing, awaitingExecution, exporting, stopping, finalized, readyToSave
    case saving, saved, cancelled, failed, interrupted
}

struct ExportJobView: Identifiable, Sendable {
    let id: UUID
    let title: String
    var state: ExportJobState
    var progress: Double?
    var error: String?
}

struct ExportArtifact: Identifiable, Sendable {
    let id: UUID
    let title: String
    let filename: String
    let fileURL: URL
}

enum ExportFailure: Error, LocalizedError, Sendable {
    case sourceUnavailable, sourceChanged, busy, backendUnavailable, invalidFilename
    case diskSpace, protectedData, cancelled, invalidOutput
    case native(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: String(localized: "Downloaded files are unavailable.")
        case .sourceChanged: String(localized: "The downloaded files changed. Open export again.")
        case .busy: String(localized: "Another export is still running.")
        case .backendUnavailable: String(localized: "The export component is not ready.")
        case .invalidFilename: String(localized: "Enter a file name.")
        case .diskSpace: String(localized: "There is not enough space for this export.")
        case .protectedData: String(localized: "Unlock the device to access the export files.")
        case .cancelled: String(localized: "Export cancelled.")
        case .invalidOutput: String(localized: "The exported file could not be validated.")
        case .native(let message): message
        }
    }
}

final class ExportCancellation: Sendable {
    private struct State { var cancelled = false; var handler: (@Sendable () -> Void)? }
    private let value = Mutex(State())
    func cancel() {
        let handler = value.withLock { state in state.cancelled = true; return state.handler }
        handler?()
    }
    var isCancelled: Bool { value.withLock { $0.cancelled } }
    func install(_ handler: @escaping @Sendable () -> Void) {
        let alreadyCancelled = value.withLock { state in state.handler = handler; return state.cancelled }
        if alreadyCancelled { handler() }
    }
    func uninstall() { value.withLock { $0.handler = nil } }
}

struct ExportNativeResult: Sendable {
    let validated: Bool
}

struct ExportNativeRequest: Sendable {
    let source: DownloadExportSource
    let options: ExportOptions
    let output: URL
}

protocol DownloadExportNativeBackend: Sendable {
    func probe(source: DownloadExportSource, cancellation: ExportCancellation) async throws -> ExportMediaInventory
    func execute(
        request: ExportNativeRequest, cancellation: ExportCancellation, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportNativeResult
}
