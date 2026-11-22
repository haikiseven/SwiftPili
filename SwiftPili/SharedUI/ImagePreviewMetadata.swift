import Foundation
import ImageIO
import Kingfisher
import UIKit

/// Reads true original pixel dimensions without rasterizing the full image on the main thread.
enum ImagePreviewMetadata {
    @MainActor static func originalSize(
        result: RetrieveImageResult, options: KingfisherParsedOptionsInfo
    ) async -> CGSize? {
        guard !Task.isCancelled else { return nil }
        let cache = options.originalCache ?? options.targetCache ?? KingfisherManager.shared.cache
        let key = result.source.cacheKey
        var originalOptions = options
        originalOptions.processor = DefaultImageProcessor.default
        if let image = cache.retrieveImageInMemoryCache(forKey: key, options: originalOptions) {
            return pixelDimensions(of: image)
        }
        let type = await cache.imageCachedTypeAsync(forKey: key, forcedExtension: options.forcedExtension)
        guard !Task.isCancelled else { return nil }
        if type == .memory,
           let image = cache.retrieveImageInMemoryCache(forKey: key, options: originalOptions) {
            return pixelDimensions(of: image)
        }
        guard type == .disk || type == .memory else { return nil }
        let fileExtension = options.forcedExtension
        return await Task.detached(priority: .userInitiated) { () -> CGSize? in
            guard let data = try? cache.diskStorage.value(forKey: key, forcedExtension: fileExtension) else {
                return nil
            }
            return headerSize(data)
        }.value
    }

    nonisolated static func headerSize(_ data: Data) -> CGSize? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let size = CGSize(width: width.doubleValue, height: height.doubleValue)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
    }

    private static func pixelDimensions(of image: UIImage) -> CGSize? {
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
