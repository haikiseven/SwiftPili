import Kingfisher
import UIKit

/// Shared UIKit cover and avatar URL sizing, downsampling, and Kingfisher
/// application policy matching SwiftUI `CoverImage` and `AvatarImage`.
enum UIKitCoverPipeline {
    struct CoverRequest: Equatable, Sendable {
        let url: URL?
        let requestBox: CGSize
        let scale: CGFloat
        let displayMode: CoverDisplayMode
        let sourceURL: String

        var contentMode: UIView.ContentMode {
            displayMode == .fill ? .scaleAspectFill : .scaleAspectFit
        }
    }

    private struct RequestSpec {
        let sourceURL: String
        let drawnBox: CGSize
        let displayMode: CoverDisplayMode
        let requestsServerCrop: Bool
        let headroom: CoverRequestHeadroom
        let scale: CGFloat
    }

    static func request(
        sources: VideoCoverSources,
        drawnBox: CGSize,
        presentation: CoverPresentation,
        scale: CGFloat,
        headroom: CoverRequestHeadroom = .officialCoverAspects
    ) -> CoverRequest {
        makeRequest(RequestSpec(
            sourceURL: presentation.url(for: sources),
            drawnBox: drawnBox,
            displayMode: presentation.display,
            requestsServerCrop: false,
            headroom: headroom,
            scale: scale
        ))
    }

    static func request(
        urlString: String,
        drawnBox: CGSize,
        displayMode: CoverDisplayMode = .fill,
        requestsServerCrop: Bool = false,
        scale: CGFloat
    ) -> CoverRequest {
        makeRequest(RequestSpec(
            sourceURL: urlString.trimmingCharacters(in: .whitespacesAndNewlines),
            drawnBox: drawnBox,
            displayMode: displayMode,
            requestsServerCrop: requestsServerCrop,
            headroom: .none,
            scale: scale
        ))
    }

    static func avatarRequest(
        urlString: String?,
        pointSize: CGFloat,
        scale: CGFloat
    ) -> CoverRequest {
        let safeScale = scale > 0 ? scale : 1
        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let box = CGSize(width: pointSize, height: pointSize)
        guard !trimmed.isEmpty, pointSize > 1 else {
            return CoverRequest(
                url: nil,
                requestBox: box,
                scale: safeScale,
                displayMode: .fill,
                sourceURL: trimmed
            )
        }
        let pixelSize = CGSize(width: pointSize * safeScale, height: pointSize * safeScale)
        let resized = trimmed.biliResized(toPixel: pixelSize, crop: true)
        return CoverRequest(
            url: URL(string: resized),
            requestBox: box,
            scale: safeScale,
            displayMode: .fill,
            sourceURL: trimmed
        )
    }

    static func options(for request: CoverRequest) -> KingfisherOptionsInfo {
        let processor = DownsamplingImageProcessor(size: request.requestBox)
        var items = KingfisherManager.shared.defaultOptions
        items.append(contentsOf: [
            .processor(processor),
            .scaleFactor(request.scale),
            .transition(.none),
        ])
        return items
    }

    @MainActor
    static func apply(
        to imageView: UIImageView,
        request: CoverRequest,
        activeRequest: inout CoverRequest?,
        placeholderImage: UIImage? = nil
    ) {
        imageView.contentMode = request.contentMode
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemFill

        guard activeRequest != request else { return }
        activeRequest = request

        guard let url = request.url else {
            imageView.kf.cancelDownloadTask()
            imageView.image = placeholderImage
            return
        }
        imageView.kf.setImage(
            with: url,
            placeholder: placeholderImage,
            options: options(for: request)
        )
    }

    @MainActor
    static func cancel(
        on imageView: UIImageView,
        activeRequest: inout CoverRequest?,
        placeholderImage: UIImage? = nil
    ) {
        imageView.kf.cancelDownloadTask()
        imageView.image = placeholderImage
        activeRequest = nil
    }

    private static func makeRequest(_ spec: RequestSpec) -> CoverRequest {
        let safeScale = spec.scale > 0 ? spec.scale : 1
        let whole = CGSize(
            width: spec.drawnBox.width.rounded(),
            height: spec.drawnBox.height.rounded()
        )
        let quantized = ImagePipelinePolicy.quantizedRequestBox(whole)
        let requestBox: CGSize = if spec.requestsServerCrop && whole.width > 1 && whole.height > 1 {
            serverCropBox(quantized, drawnBox: whole)
        } else if spec.displayMode == .fill {
            spec.headroom.box(quantized, drawnBox: whole)
        } else {
            quantized
        }

        guard !spec.sourceURL.isEmpty, requestBox.width > 1, requestBox.height > 1 else {
            return CoverRequest(
                url: nil,
                requestBox: requestBox,
                scale: safeScale,
                displayMode: spec.displayMode,
                sourceURL: spec.sourceURL
            )
        }
        let pixelSize = CGSize(
            width: requestBox.width * safeScale,
            height: requestBox.height * safeScale
        )
        let resized = spec.sourceURL.biliResized(toPixel: pixelSize, crop: spec.requestsServerCrop)
        return CoverRequest(
            url: URL(string: resized),
            requestBox: requestBox,
            scale: safeScale,
            displayMode: spec.displayMode,
            sourceURL: spec.sourceURL
        )
    }

    private static func serverCropBox(_ requested: CGSize, drawnBox drawn: CGSize) -> CGSize {
        guard drawn.width > 1, drawn.height > 1,
              requested.width > 1, requested.height > 1,
              drawn.width.isFinite, drawn.height.isFinite,
              requested.width.isFinite, requested.height.isFinite
        else { return requested }
        let factor = max(1, requested.width / drawn.width, requested.height / drawn.height)
        return CGSize(
            width: (drawn.width * factor).rounded(),
            height: (drawn.height * factor).rounded()
        )
    }
}

/// Token-fenced `Kingfisher.ImagePrefetcher` manager for UIKit collection views.
/// Ensures an older cancelled prefetcher's completion never evicts a newer
/// prefetcher registered at the same `IndexPath`.
@MainActor
final class UIKitPrefetchCoordinator {
    private struct Entry {
        let token: UUID
        let prefetchers: [ImagePrefetcher]
        var remaining: Int
    }

    private var activeEntries: [IndexPath: Entry] = [:]

    func prefetch(
        at indexPaths: [IndexPath],
        requestForIndexPath: (IndexPath) -> UIKitCoverPipeline.CoverRequest?
    ) {
        prefetch(at: indexPaths) { indexPath in
            requestForIndexPath(indexPath).map { [$0] } ?? []
        }
    }

    func prefetch(
        at indexPaths: [IndexPath],
        requestsForIndexPath: (IndexPath) -> [UIKitCoverPipeline.CoverRequest]
    ) {
        for indexPath in indexPaths where activeEntries[indexPath] == nil {
            let valid = requestsForIndexPath(indexPath).filter { $0.url != nil }
            guard !valid.isEmpty else { continue }
            let token = UUID()
            let prefetchers = valid.compactMap { request -> ImagePrefetcher? in
                guard let url = request.url else { return nil }
                return ImagePrefetcher(
                    urls: [url],
                    options: UIKitCoverPipeline.options(for: request)
                ) { [weak self] _, _, _ in
                    Task { @MainActor [weak self] in
                        guard let self, var entry = self.activeEntries[indexPath],
                              entry.token == token else { return }
                        entry.remaining -= 1
                        if entry.remaining <= 0 {
                            self.activeEntries.removeValue(forKey: indexPath)
                        } else {
                            self.activeEntries[indexPath] = entry
                        }
                    }
                }
            }
            guard !prefetchers.isEmpty else { continue }
            activeEntries[indexPath] = Entry(
                token: token, prefetchers: prefetchers, remaining: prefetchers.count
            )
            prefetchers.forEach { $0.start() }
        }
    }

    func cancelPrefetching(at indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            if let entry = activeEntries.removeValue(forKey: indexPath) {
                entry.prefetchers.forEach { $0.stop() }
            }
        }
    }

    func cancelAll() {
        for entry in activeEntries.values {
            entry.prefetchers.forEach { $0.stop() }
        }
        activeEntries.removeAll()
    }
}
