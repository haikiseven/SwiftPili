import Foundation
import CoreGraphics

/// Preview identity includes the cell, even when adjacent samples share a URL.
struct PlayerAmbientArtwork: Hashable, Sendable {
    let url: String
    let tile: PlayerAmbientAtlasTile?

    init(url: String, tile: PlayerAmbientAtlasTile? = nil) {
        self.url = url
        self.tile = tile
    }
}

struct PlayerAmbientSource: Equatable, Sendable {
    let artwork: PlayerAmbientArtwork
    let fallbackCover: String?
}

struct PlayerAmbientAtlasTile: Hashable, Sendable {
    static let maximumPixelEdge = 1024
    private static let tilePixelEdge = 64

    let columns: Int
    let rows: Int
    let column: Int
    let row: Int
    let cellWidth: Int
    let cellHeight: Int

    init?(manifest: VideoStoryboardManifest, ordinal: Int) {
        let maximumGrid = Self.maximumPixelEdge / Self.tilePixelEdge
        guard manifest.columns > 0, manifest.columns <= maximumGrid,
              manifest.rows > 0, manifest.rows <= maximumGrid,
              manifest.cellWidth > 0, manifest.cellHeight > 0, ordinal >= 0 else { return nil }
        columns = manifest.columns
        rows = manifest.rows
        column = ordinal % columns
        row = ordinal / columns % rows
        cellWidth = manifest.cellWidth
        cellHeight = manifest.cellHeight
        guard requestSize.width >= CGFloat(columns), requestSize.height >= CGFloat(rows) else { return nil }
    }

    var aspect: Double { Double(columns) * Double(cellWidth) / (Double(rows) * Double(cellHeight)) }

    /// Physical pixels at scale1; host geometry and retina scale never enter.
    var requestSize: CGSize {
        let edge = CGFloat(Self.maximumPixelEdge)
        let ratio = CGFloat(aspect)
        return ratio >= 1
            ? CGSize(width: edge, height: max(1, (edge / ratio).rounded()))
            : CGSize(width: max(1, (edge * ratio).rounded()), height: edge)
    }

    var processorIdentifier: String {
        "com.swiftpili.ambient.tile.v1.\(columns)x\(rows).\(cellWidth)x\(cellHeight).\(column).\(row)"
    }

    /// Resize only supported CDN image paths, preserving the source's query.
    func resizedURL(_ rawURL: String) -> URL? {
        guard var components = URLComponents(string: rawURL),
              let host = components.host?.lowercased(),
              host == "hdslb.com" || host.hasSuffix(".hdslb.com")
                || host == "biliimg.com" || host.hasSuffix(".biliimg.com") else { return nil }
        let query = components.percentEncodedQuery
        let fragment = components.percentEncodedFragment
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil
        guard let base = components.string,
              var resized = URLComponents(string: base.biliResized(toPixel: requestSize)) else { return nil }
        resized.percentEncodedQuery = query
        resized.percentEncodedFragment = fragment
        return resized.url
    }
}

struct PlayerAmbientStoryboardSample: Equatable, Sendable {
    let from: TimeInterval
    let artwork: PlayerAmbientArtwork

    static func admitted(_ manifest: VideoStoryboardManifest) -> [Self] {
        guard !manifest.index.isEmpty, !manifest.images.isEmpty,
              PlayerAmbientAtlasTile(manifest: manifest, ordinal: 0) != nil else { return [] }
        let hasLeadingHeader = manifest.index.count > 1
            && manifest.index[0] == 0
            && manifest.index[1] == 0
        // The recognized web encoding may carry a duplicate leading zero header;
        // some manifests omit that header and list strictly increasing sample times directly.
        // Never independently sort/deduplicate these times: their original ordinal selects the cell.
        let times = hasLeadingHeader ? Array(manifest.index.dropFirst()) : manifest.index
        let capacity = manifest.columns.multipliedReportingOverflow(by: manifest.rows)
        let total = capacity.partialValue.multipliedReportingOverflow(by: manifest.images.count)
        guard !capacity.overflow, !total.overflow, !times.isEmpty,
              total.partialValue >= times.count, validTimes(times) else { return [] }
        let count = min(times.count, PlayerAmbientStoryboardFrame.maxAdmittedFrames)
        return (0..<count).compactMap { slot in
            let ordinal = count == 1 ? 0 : Int(
                (Double(slot) / Double(count - 1) * Double(times.count - 1)).rounded(.down)
            )
            let imageIndex = ordinal / capacity.partialValue
            guard let tile = PlayerAmbientAtlasTile(manifest: manifest, ordinal: ordinal),
                  let url = PlayerAmbientStoryboardFrame.normalizedURL(manifest.images[imageIndex]),
                  tile.resizedURL(url) != nil else { return nil }
            return Self(from: times[ordinal], artwork: PlayerAmbientArtwork(url: url, tile: tile))
        }
    }

    private static func validTimes(_ times: [Double]) -> Bool {
        var previous: Double = -1
        for time in times {
            guard time.isFinite, time >= 0, time > previous else { return false }
            previous = time
        }
        return true
    }
}
