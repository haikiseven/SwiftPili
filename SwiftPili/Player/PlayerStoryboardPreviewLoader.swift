import CoreGraphics
import Foundation
import Kingfisher
import Observation
import UIKit

// MARK: - Storyboard Frame Slot & Pure Lookup Math

struct VideoStoryboardFrameSlot: Equatable, Sendable {
    let frameIndex: Int
    let sheetIndex: Int
    let row: Int
    let column: Int
    let cellWidth: Int
    let cellHeight: Int
    let columns: Int
    let rows: Int
    let sheetURL: String
    let timestamp: TimeInterval

    var aspectRatio: CGFloat {
        guard cellWidth > 0, cellHeight > 0 else { return 16.0 / 9.0 }
        let ratio = CGFloat(cellWidth) / CGFloat(cellHeight)
        return ratio.isFinite && ratio > 0.25 && ratio < 4.0 ? ratio : (16.0 / 9.0)
    }

    func pixelCropRect(imagePixelWidth: Int, imagePixelHeight: Int) -> CGRect? {
        guard columns > 0, rows > 0,
              column >= 0, column < columns,
              row >= 0, row < rows,
              imagePixelWidth > 0, imagePixelHeight > 0 else {
            return nil
        }

        let expectedWidth = columns * cellWidth
        let expectedHeight = rows * cellHeight
        let tileWidth: CGFloat
        let tileHeight: CGFloat
        if cellWidth > 0, cellHeight > 0,
           imagePixelWidth >= expectedWidth,
           imagePixelHeight >= expectedHeight {
            tileWidth = CGFloat(cellWidth)
            tileHeight = CGFloat(cellHeight)
        } else {
            tileWidth = CGFloat(imagePixelWidth) / CGFloat(columns)
            tileHeight = CGFloat(imagePixelHeight) / CGFloat(rows)
        }

        let rect = CGRect(
            x: (CGFloat(column) * tileWidth).rounded(.down),
            y: (CGFloat(row) * tileHeight).rounded(.down),
            width: tileWidth.rounded(.down),
            height: tileHeight.rounded(.down)
        )
        let bounds = CGRect(x: 0, y: 0, width: imagePixelWidth, height: imagePixelHeight)
        let clamped = rect.intersection(bounds)
        return clamped.width >= 1 && clamped.height >= 1 ? clamped : nil
    }
}

enum VideoStoryboardFrameLocator {
    nonisolated static func normalizedTimes(from manifest: VideoStoryboardManifest) -> [Double] {
        guard !manifest.index.isEmpty else { return [] }
        if manifest.index.count > 1, manifest.index[0] == 0, manifest.index[1] == 0 {
            return Array(manifest.index.dropFirst())
        }
        return manifest.index
    }

    nonisolated static func frameIndex(at time: TimeInterval, in times: [Double]) -> Int? {
        guard !times.isEmpty, time.isFinite else { return nil }
        let clamped = max(0, time)
        var low = 0
        var high = times.count - 1
        var best = 0
        while low <= high {
            let mid = low + (high - low) / 2
            if times[mid] <= clamped {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    nonisolated static func normalizedSheetURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.hasPrefix("//") ? "https:\(trimmed)" : trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return candidate
    }

    nonisolated static func frameSlot(
        in manifest: VideoStoryboardManifest,
        at time: TimeInterval
    ) -> VideoStoryboardFrameSlot? {
        guard manifest.columns > 0, manifest.rows > 0,
              manifest.cellWidth > 0, manifest.cellHeight > 0,
              !manifest.images.isEmpty else {
            return nil
        }
        let perSheetResult = manifest.columns.multipliedReportingOverflow(by: manifest.rows)
        guard !perSheetResult.overflow, perSheetResult.partialValue > 0 else { return nil }
        let perSheet = perSheetResult.partialValue

        let times = normalizedTimes(from: manifest)
        guard let rawFrameIndex = frameIndex(at: time, in: times) else { return nil }

        let sheetIndex = rawFrameIndex / perSheet
        guard manifest.images.indices.contains(sheetIndex),
              let sheetURL = normalizedSheetURL(manifest.images[sheetIndex]) else {
            return nil
        }

        let offsetInSheet = rawFrameIndex % perSheet
        let row = offsetInSheet / manifest.columns
        let column = offsetInSheet % manifest.columns

        return VideoStoryboardFrameSlot(
            frameIndex: rawFrameIndex,
            sheetIndex: sheetIndex,
            row: row,
            column: column,
            cellWidth: manifest.cellWidth,
            cellHeight: manifest.cellHeight,
            columns: manifest.columns,
            rows: manifest.rows,
            sheetURL: sheetURL,
            timestamp: times[rawFrameIndex]
        )
    }
}

// MARK: - Lazy Storyboard Preview Loader

@MainActor
@Observable
final class PlayerStoryboardPreviewLoader {
    struct ContentKey: Hashable, Sendable {
        let aid: Int
        let cid: Int
    }

    private enum ManifestEntry {
        case loaded(VideoStoryboardManifest)
        case unavailable
    }

    static let shared = PlayerStoryboardPreviewLoader()

    private static let maxManifestCacheEntries = 16
    private static let maxDecodedSheetEntries = 8

    private(set) var previewImage: UIImage?
    private(set) var previewTime: TimeInterval = 0
    private(set) var previewAspectRatio: CGFloat = 16.0 / 9.0

    @ObservationIgnored private var activeKey: ContentKey?
    @ObservationIgnored private var requestedTime: TimeInterval = 0
    @ObservationIgnored private var lastRenderedSlot: VideoStoryboardFrameSlot?

    @ObservationIgnored private var manifests: [ContentKey: ManifestEntry] = [:]
    @ObservationIgnored private var manifestOrder: [ContentKey] = []
    @ObservationIgnored private var inflightManifestTasks: [ContentKey: Task<Void, Never>] = [:]

    @ObservationIgnored private var decodedSheets: [String: CGImage] = [:]
    @ObservationIgnored private var sheetOrder: [String] = []
    @ObservationIgnored private var inflightSheetTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var memoryWarningObserver: (any NSObjectProtocol)?

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearMemoryCaches()
            }
        }
    }

    func updatePreview(
        aid: Int?,
        cid: Int?,
        time: TimeInterval,
        isSeekableOnlineVOD: Bool
    ) {
        guard isSeekableOnlineVOD,
              let aid, aid > 0,
              let cid, cid > 0,
              time.isFinite else {
            clearActivePreview()
            return
        }

        let key = ContentKey(aid: aid, cid: cid)
        if activeKey != key {
            activeKey = key
            lastRenderedSlot = nil
            previewImage = nil
            previewAspectRatio = 16.0 / 9.0
        }
        let clampedTime = max(0, time)
        requestedTime = clampedTime
        previewTime = clampedTime

        guard let entry = manifests[key] else {
            fetchManifestIfNeeded(for: key)
            return
        }

        switch entry {
        case .unavailable:
            if previewImage != nil { previewImage = nil }
        case .loaded(let manifest):
            renderFrame(from: manifest, at: clampedTime, for: key)
        }
    }

    func clearActivePreview() {
        activeKey = nil
        lastRenderedSlot = nil
        if previewImage != nil { previewImage = nil }
    }

    func clearMemoryCaches() {
        decodedSheets.removeAll()
        sheetOrder.removeAll()
        lastRenderedSlot = nil
    }

    private func fetchManifestIfNeeded(for key: ContentKey) {
        guard inflightManifestTasks[key] == nil else { return }
        inflightManifestTasks[key] = Task { @MainActor [weak self] in
            defer { self?.inflightManifestTasks.removeValue(forKey: key) }
            let fetched = try? await VideoAPI.getStoryboard(aid: key.aid, cid: key.cid)
            guard !Task.isCancelled, let self else { return }
            let entry: ManifestEntry
            if let fetched,
               VideoStoryboardFrameLocator.frameSlot(in: fetched, at: 0) != nil {
                entry = .loaded(fetched)
            } else {
                entry = .unavailable
            }
            self.storeManifest(entry, for: key)
            if self.activeKey == key, case .loaded(let manifest) = entry {
                self.renderFrame(from: manifest, at: self.requestedTime, for: key)
            }
        }
    }

    private func storeManifest(_ entry: ManifestEntry, for key: ContentKey) {
        if manifests[key] == nil {
            manifestOrder.append(key)
            while manifestOrder.count > Self.maxManifestCacheEntries {
                let evicted = manifestOrder.removeFirst()
                manifests.removeValue(forKey: evicted)
            }
        }
        manifests[key] = entry
    }

    private func renderFrame(
        from manifest: VideoStoryboardManifest,
        at time: TimeInterval,
        for key: ContentKey
    ) {
        guard let slot = VideoStoryboardFrameLocator.frameSlot(in: manifest, at: time) else {
            return
        }
        if lastRenderedSlot == slot, previewImage != nil { return }
        if let sheet = decodedSheets[slot.sheetURL] {
            publishCroppedImage(from: sheet, slot: slot)
            return
        }
        fetchSheetIfNeeded(urlString: slot.sheetURL, for: key)
    }

    private func fetchSheetIfNeeded(urlString: String, for key: ContentKey) {
        guard inflightSheetTasks[urlString] == nil else { return }
        inflightSheetTasks[urlString] = Task { @MainActor [weak self] in
            defer { self?.inflightSheetTasks.removeValue(forKey: urlString) }
            let cgImage = await Task.detached(priority: .userInitiated) {
                await Self.loadSpriteSheet(urlString: urlString)
            }.value
            guard !Task.isCancelled, let self, let cgImage else { return }
            self.storeSheet(cgImage, for: urlString)
            if self.activeKey == key,
               case .loaded(let manifest)? = self.manifests[key] {
                self.renderFrame(from: manifest, at: self.requestedTime, for: key)
            }
        }
    }

    private func storeSheet(_ image: CGImage, for urlString: String) {
        if decodedSheets[urlString] == nil {
            sheetOrder.append(urlString)
            while sheetOrder.count > Self.maxDecodedSheetEntries {
                let evicted = sheetOrder.removeFirst()
                decodedSheets.removeValue(forKey: evicted)
            }
        }
        decodedSheets[urlString] = image
    }

    private func publishCroppedImage(from sheet: CGImage, slot: VideoStoryboardFrameSlot) {
        guard let cropRect = slot.pixelCropRect(
            imagePixelWidth: sheet.width,
            imagePixelHeight: sheet.height
        ),
              let cropped = sheet.cropping(to: cropRect) else {
            return
        }
        lastRenderedSlot = slot
        previewAspectRatio = slot.aspectRatio
        previewImage = UIImage(cgImage: cropped)
    }

    private nonisolated static func loadSpriteSheet(urlString: String) async -> CGImage? {
        guard let url = URL(string: urlString) else { return nil }
        let cache = ImageCache.default
        let cacheKey = url.cacheKey

        if let cachedData = try? cache.diskStorage.value(forKey: cacheKey),
           let image = UIImage(data: cachedData)?.cgImage {
            return image
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        guard !Task.isCancelled,
              let (data, response) = try? await URLSession.shared.data(for: request),
              !data.isEmpty else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            return nil
        }
        guard !Task.isCancelled, let image = UIImage(data: data)?.cgImage else {
            return nil
        }
        cache.storeToDisk(data, forKey: cacheKey, completionHandler: nil)
        return image
    }
}
