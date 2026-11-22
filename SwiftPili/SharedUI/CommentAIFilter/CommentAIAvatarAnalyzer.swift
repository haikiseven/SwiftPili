import CoreGraphics
import Foundation
import Kingfisher
import UIKit

/// Result of 32×32 HSV/HSL whale-blue palette analysis on a commenter's avatar,
/// aligned with `liyupi/dafeiyu-cleaner`'s `DFY.avatarBlue` detector.
struct CommentAIAvatarBlueResult: Equatable, Sendable {
    enum Tier: Equatable, Sendable {
        case none
        case moderate
        case strong
    }

    /// Fraction of all pixels matching the DeepSeek / whale-blue hue & saturation band.
    let totalBlueRatio: Double
    /// Fraction of chromatic (non-gray/white/black) pixels that are whale-blue.
    let chromaticBlueRatio: Double
    let tier: Tier
}

/// Asynchronous avatar color analyzer that reuses Kingfisher's image cache
/// so comment scrolling does not trigger redundant image downloads.
enum CommentAIAvatarAnalyzer {
    private static let sampleSize = 32

    static func normalizedCacheKey(for urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.httpsURL
    }

    static func analyze(urlString: String) async -> CommentAIAvatarBlueResult? {
        let key = normalizedCacheKey(for: urlString)
        guard !key.isEmpty, let url = URL(string: key) else { return nil }
        guard !Task.isCancelled else { return nil }

        guard let cgImage = await loadCGImage(for: url) else { return nil }
        guard !Task.isCancelled else { return nil }

        return await Task.detached(priority: .utility) {
            classifyWhaleBlue(cgImage: cgImage)
        }.value
    }

    private static func loadCGImage(for url: URL) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options: KingfisherOptionsInfo = [
                .backgroundDecode,
                .processor(DownsamplingImageProcessor(size: CGSize(width: 64, height: 64))),
                .scaleFactor(1.0)
            ]
            KingfisherManager.shared.retrieveImage(with: url, options: options) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value.image.cgImage)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Downsamples `cgImage` to 32×32 RGBA8 and computes DeepSeek whale-blue coverage.
    private static func classifyWhaleBlue(cgImage: CGImage) -> CommentAIAvatarBlueResult {
        guard let pixels = renderSampleRGBA(cgImage: cgImage) else {
            return CommentAIAvatarBlueResult(totalBlueRatio: 0, chromaticBlueRatio: 0, tier: .none)
        }
        let counts = countBluePixels(in: pixels)
        guard counts.visible > 0 else {
            return CommentAIAvatarBlueResult(totalBlueRatio: 0, chromaticBlueRatio: 0, tier: .none)
        }

        let totalRatio = Double(counts.whaleBlue) / Double(counts.visible)
        let chromaticRatio = counts.chromatic > 0
            ? Double(counts.whaleBlue) / Double(counts.chromatic)
            : 0.0

        let tier: CommentAIAvatarBlueResult.Tier
        if totalRatio >= 0.36 || (totalRatio >= 0.22 && chromaticRatio >= 0.70) {
            tier = .strong
        } else if totalRatio >= 0.18 || (totalRatio >= 0.12 && chromaticRatio >= 0.52) {
            tier = .moderate
        } else {
            tier = .none
        }

        return CommentAIAvatarBlueResult(
            totalBlueRatio: totalRatio,
            chromaticBlueRatio: chromaticRatio,
            tier: tier
        )
    }

    private static func renderSampleRGBA(cgImage: CGImage) -> [UInt8]? {
        let width = sampleSize
        let height = sampleSize
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private struct PixelCounts {
        let visible: Int
        let chromatic: Int
        let whaleBlue: Int
    }

    private static func countBluePixels(in pixels: [UInt8]) -> PixelCounts {
        var visible = 0
        var chromatic = 0
        var whaleBlue = 0

        for idx in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[idx + 3] < 32 { continue }
            visible += 1

            let red = Double(pixels[idx]) / 255.0
            let green = Double(pixels[idx + 1]) / 255.0
            let blue = Double(pixels[idx + 2]) / 255.0

            let maxChannel = max(red, max(green, blue))
            let minChannel = min(red, min(green, blue))
            let delta = maxChannel - minChannel
            let saturation = maxChannel > 0.001 ? (delta / maxChannel) : 0.0

            if saturation >= 0.16 && maxChannel >= 0.15 {
                chromatic += 1
            }
            guard delta > 0.001, saturation >= 0.28, maxChannel >= 0.22 else { continue }
            let hue = computeHueDegrees(red: red, green: green, blue: blue, maxChannel: maxChannel, delta: delta)
            if hue >= 190.0 && hue <= 252.0 {
                whaleBlue += 1
            }
        }
        return PixelCounts(visible: visible, chromatic: chromatic, whaleBlue: whaleBlue)
    }

    private static func computeHueDegrees(
        red: Double,
        green: Double,
        blue: Double,
        maxChannel: Double,
        delta: Double
    ) -> Double {
        var hue: Double
        if maxChannel == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxChannel == green {
            hue = ((blue - red) / delta) + 2.0
        } else {
            hue = ((red - green) / delta) + 4.0
        }
        hue *= 60.0
        if hue < 0 { hue += 360.0 }
        return hue
    }
}
