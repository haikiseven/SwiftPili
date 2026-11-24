import Foundation
import Synchronization

struct DownloadExportSource: Hashable, Sendable {
    let downloadID: String
    let title: String
    let videoURL: URL
    let audioURL: URL?

    init(downloadID: String, title: String, videoURL: URL, audioURL: URL?) {
        self.downloadID = downloadID
        self.title = title
        self.videoURL = videoURL
        self.audioURL = audioURL
    }

    init(snapshot: DownloadFileSnapshot, title: String) throws {
        guard snapshot.filesExist else { throw ExportFailure.sourceUnavailable }
        self.downloadID = snapshot.id
        self.title = title
        self.videoURL = snapshot.videoFileURL
        self.audioURL = snapshot.audioFileURL
    }

    var filesExist: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: videoURL.path) else { return false }
        if let audioURL, !fm.fileExists(atPath: audioURL.path) { return false }
        return true
    }

    var sourceByteCount: Int64 {
        let fm = FileManager.default
        let vSize = (try? fm.attributesOfItem(atPath: videoURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let aSize = audioURL.flatMap { (try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value } ?? 0
        return max(0, vSize) + max(0, aSize)
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

enum ExportJobState: String, Sendable, Equatable {
    case preparing
    case exporting
    case stopping
    case cancelled
    case failed
}

struct ExportJobView: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    var state: ExportJobState
    var progress: Double?
    var error: String?
}

struct ExportArtifact: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let filename: String
    let fileURL: URL
    let fileSizeBytes: Int64
}

enum ExportSaveDestination: Sendable, Equatable {
    case photos
    case files
    case share
}

enum ExportFailure: Error, LocalizedError, Sendable, Equatable {
    case sourceUnavailable
    case busy
    case backendUnavailable
    case invalidFilename
    case diskSpace
    case cancelled
    case invalidOutput
    case photoLibraryDenied
    case native(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: String(localized: "Downloaded files are unavailable.")
        case .busy: String(localized: "Another export is still running.")
        case .backendUnavailable: String(localized: "The export component is not ready.")
        case .invalidFilename: String(localized: "Enter a file name.")
        case .diskSpace: String(localized: "There is not enough space for this export.")
        case .cancelled: String(localized: "Export cancelled.")
        case .invalidOutput: String(localized: "The exported file could not be validated.")
        case .photoLibraryDenied: String(localized: "Photo Library access was denied. Enable it in Settings to save videos.")
        case .native(let message): message
        }
    }
}

final class ExportCancellation: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var handler: (@Sendable () -> Void)?
    }
    private let value = Mutex(State())

    func cancel() {
        let handler = value.withLock { state -> (@Sendable () -> Void)? in
            guard !state.cancelled else { return nil }
            state.cancelled = true
            return state.handler
        }
        handler?()
    }

    var isCancelled: Bool { value.withLock { $0.cancelled } }

    func install(_ handler: @escaping @Sendable () -> Void) {
        let alreadyCancelled = value.withLock { state in
            state.handler = handler
            return state.cancelled
        }
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
