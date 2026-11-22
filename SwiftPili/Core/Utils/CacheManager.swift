import Foundation
import Kingfisher

enum CacheManager {
    static let sizeLimitKey = "cache_size_limit_mb"

    static var sizeLimitMB: Int {
        UserDefaults.standard.object(forKey: sizeLimitKey) as? Int ?? 500
    }

    static func apply() {
        let mb = sizeLimitMB
        ImageCache.default.diskStorage.config.sizeLimit = mb == 0 ? 0 : UInt(mb) * 1024 * 1024
        ImageCache.default.memoryStorage.config.totalCostLimit = 120 * 1024 * 1024

        let transition = ImagePipelinePolicy.fadeSeconds(reduceMotion: false)
            .map { ImageTransition.fade($0) } ?? ImageTransition.none
        KingfisherManager.shared.defaultOptions = [
            .transition(transition),
            .backgroundDecode,
            .cacheSerializer(FastCoverCacheSerializer.shared),
            .diskCacheAccessExtendingExpiration(.none),
            .retryStrategy(DelayRetryStrategy(maxRetryCount: 2, retryInterval: .seconds(1))),
        ]

        if ImagePipelinePolicy.usesAsyncCacheTypeCheck {
            KingfisherManager.shared.defaultOptions.append(.asyncCacheTypeCheck)
        }

        ImageDownloader.default.downloadTimeout = 8
    }

    static func performLaunchCleanup() {
        apply()
        ImageCache.default.cleanExpiredDiskCache()
    }

    static func currentDiskUsage() async -> UInt {
        await withCheckedContinuation { continuation in
            ImageCache.default.calculateDiskStorageSize { result in
                continuation.resume(returning: (try? result.get()) ?? 0)
            }
        }
    }

    static func clearAll() async {
        ImageCache.default.clearMemoryCache()
        await withCheckedContinuation { continuation in
            ImageCache.default.clearDiskCache {
                continuation.resume()
            }
        }
        URLCache.shared.removeAllCachedResponses()
        await SmartCDNSelector.shared.invalidateCache(reason: "manual Clear Cache")
    }

    static func format(_ bytes: UInt) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct FastCoverCacheSerializer: CacheSerializer {
    static let shared = FastCoverCacheSerializer()

    func data(with image: KFCrossPlatformImage, original: Data?) -> Data? {
        if let original {
            let format = original.kf.imageFormat
            if format == .GIF {
                return DefaultCacheSerializer.default.data(with: image, original: original)
            }
            if format == .JPEG {
                return image.jpegData(compressionQuality: 0.85)
            }
        }
        if Self.hasAlpha(image) {
            return image.pngData()
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    func image(with data: Data, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        DefaultCacheSerializer.default.image(with: data, options: options)
    }

    private static func hasAlpha(_ image: KFCrossPlatformImage) -> Bool {
        guard let alpha = image.cgImage?.alphaInfo else { return false }
        switch alpha {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return false
        }
    }
}
