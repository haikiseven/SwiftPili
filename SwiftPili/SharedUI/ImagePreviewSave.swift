import Foundation
import Kingfisher
import Photos
import UIKit
import UniformTypeIdentifiers

/// Attempt-fenced save feedback state so delayed completions never overwrite a newer attempt.
struct ImagePreviewSaveState: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case idle, saving, done, failed

        var icon: String {
            switch self {
            case .idle: "arrow.down"
            case .saving: "circle.dotted"
            case .done: "checkmark"
            case .failed: "exclamationmark.triangle"
            }
        }
    }

    struct Attempt: Equatable, Sendable {
        fileprivate let identifier: UUID
    }

    private(set) var status: Status = .idle
    private var currentAttempt: Attempt?

    mutating func begin() -> Attempt? {
        guard status != .saving else { return nil }
        let attempt = Attempt(identifier: UUID())
        currentAttempt = attempt
        status = .saving
        return attempt
    }

    @discardableResult
    mutating func finish(succeeded: Bool, for attempt: Attempt) -> Bool {
        guard currentAttempt == attempt, status == .saving else { return false }
        status = succeeded ? .done : .failed
        return true
    }

    @discardableResult
    mutating func expireFeedback(for attempt: Attempt) -> Bool {
        guard currentAttempt == attempt, status == .done || status == .failed else { return false }
        status = .idle
        currentAttempt = nil
        return true
    }
}

/// Kingfisher retains animated GIF bytes separately from the first-frame UIImage.
enum ImagePreviewSavePayload: Sendable {
    case encodedGIF(Data)
    case stillImage(UIImage)

    init(image: UIImage) {
        if let data = image.kf.gifRepresentation() {
            self = .encodedGIF(data)
        } else {
            self = .stillImage(image)
        }
    }
}

/// Owns Save (Photos), Copy (UIPasteboard), and Share payload loading for the active viewer.
@MainActor final class ImagePreviewActions {
    private(set) var saveState = ImagePreviewSaveState()
    var onSaveStateChange: ((ImagePreviewSaveState.Status) -> Void)?
    var onCopyCompleted: (() -> Void)?

    func save(url: URL) {
        guard let attempt = saveState.begin() else { return }
        onSaveStateChange?(saveState.status)
        Task { [weak self] in
            do {
                let image = try await KingfisherManager.shared.retrieveImage(with: url).image
                try await Self.writeToPhotoLibrary(image)
                if let self, self.saveState.finish(succeeded: true, for: attempt) {
                    self.onSaveStateChange?(self.saveState.status)
                }
            } catch {
                PlayerLog.log("[ImagePreview] save failed: \(error)")
                if let self, self.saveState.finish(succeeded: false, for: attempt) {
                    self.onSaveStateChange?(self.saveState.status)
                }
            }
            try? await Task.sleep(for: .seconds(1.6))
            if let self, self.saveState.expireFeedback(for: attempt) {
                self.onSaveStateChange?(self.saveState.status)
            }
        }
    }

    func copy(url: URL, fallbackImage: UIImage?) {
        Task { [weak self] in
            let image: UIImage?
            if let loaded = try? await KingfisherManager.shared.retrieveImage(with: url).image {
                image = loaded
            } else {
                image = fallbackImage
            }
            guard let image else { return }
            switch ImagePreviewSavePayload(image: image) {
            case .encodedGIF(let data):
                UIPasteboard.general.setData(data, forPasteboardType: UTType.gif.identifier)
            case .stillImage(let still):
                UIPasteboard.general.image = still
            }
            self?.onCopyCompleted?()
        }
    }

    func shareItems(for url: URL, fallbackImage: UIImage?) async -> [Any] {
        let image: UIImage?
        if let loaded = try? await KingfisherManager.shared.retrieveImage(with: url).image {
            image = loaded
        } else {
            image = fallbackImage
        }
        guard let image else { return [url] }
        switch ImagePreviewSavePayload(image: image) {
        case .encodedGIF(let data): return [data]
        case .stillImage(let still): return [still]
        }
    }

    /// PhotoKit invokes the change block off-main; keep it nonisolated for Swift 6 strict concurrency.
    private nonisolated static func writeToPhotoLibrary(_ image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            switch ImagePreviewSavePayload(image: image) {
            case .encodedGIF(let data):
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = UTType.gif.identifier
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
            case .stillImage(let image):
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }
}
