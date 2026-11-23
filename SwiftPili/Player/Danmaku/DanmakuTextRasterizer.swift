import CoreText
import Foundation
import UIKit

final class DanmakuTextRasterizer: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let text: String
        let fontSize: Int
        let colorRGB: UInt32
        let hasStroke: Bool
        let scale: CGFloat
        let fontPostScriptName: String
        let fontScale: CGFloat
        let pictureHeight: CGFloat
        let presentation: DanmakuPresentation?
        let selfSentFrame: Bool

        init(
            text: String,
            fontSize: Int,
            colorRGB: UInt32,
            hasStroke: Bool,
            scale: CGFloat,
            fontPostScriptName: String = DanmakuAdvancedFontMapping.fallbackPostScriptName,
            fontScale: CGFloat = 1,
            pictureHeight: CGFloat = CGFloat(DanmakuRenderPreferences.fontPictureReference),
            presentation: DanmakuPresentation? = nil,
            selfSentFrame: Bool = false
        ) {
            self.presentation = presentation
            self.selfSentFrame = selfSentFrame
            self.text = text
            self.fontSize = fontSize
            self.colorRGB = colorRGB
            self.hasStroke = hasStroke
            self.scale = scale
            self.fontPostScriptName = fontPostScriptName
            self.fontScale = fontScale.isFinite && fontScale > 0 ? fontScale : 1
            if pictureHeight.isFinite, pictureHeight > 0 {
                self.pictureHeight = pictureHeight
            } else {
                self.pictureHeight = CGFloat(DanmakuRenderPreferences.fontPictureReference)
            }
        }
    }

    struct Image: Sendable {
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
        let contents: CGImage
    }

    static let shared = DanmakuTextRasterizer()
    static let selfSentFrameWidth: CGFloat = 1
    static let selfSentFramePadding: CGFloat = 2
    static let maxPixelWidth = 4096
    static let maxPixelHeight = 2048
    static let maxPixelArea = 4096 * 1024
    private static let minimumEffectiveScale: CGFloat = 0.5
    private static let maxCacheEntries = 256
    private static let maxCacheByteCost = 16 * 1024 * 1024

    typealias Render = @Sendable (Key, @Sendable (CGFloat) -> Bool) -> Image?
    private let render: Render

    private struct CacheEntry {
        let image: Image
        let byteCost: Int
        var lastUsedStamp: UInt64
    }

    private let queue = DispatchQueue(label: "danmaku.raster", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [Key: CacheEntry] = [:]
    private var totalCacheBytes = 0
    private var nextUseStamp: UInt64 = 0
    private nonisolated(unsafe) var memoryWarningToken: NSObjectProtocol?

    init(render: Render? = nil) {
        self.render = render ?? Self.render
        memoryWarningToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clearCache()
        }
    }

    deinit {
        if let memoryWarningToken {
            NotificationCenter.default.removeObserver(memoryWarningToken)
        }
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        totalCacheBytes = 0
        lock.unlock()
    }

    func image(
        for key: Key,
        canRender: @escaping @Sendable (CGFloat) -> Bool = { _ in true },
        completion: @escaping @Sendable (Image?) -> Void
    ) {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.async { [weak self] in
            guard let self, canRender(0) else {
                completion(nil)
                return
            }
            completion(self.cachedImage(for: key, canRender: canRender))
        }
    }

    private func cachedImage(for key: Key, canRender: @Sendable (CGFloat) -> Bool) -> Image? {
        lock.lock()
        if var hit = cache[key] {
            nextUseStamp &+= 1
            hit.lastUsedStamp = nextUseStamp
            cache[key] = hit
            lock.unlock()
            return canRender(hit.image.width) ? hit.image : nil
        }
        lock.unlock()
        guard let made = render(key, canRender) else { return nil }
        let cost = made.contents.bytesPerRow * made.contents.height
        if cost <= Self.maxCacheByteCost / 2 {
            lock.lock()
            nextUseStamp &+= 1
            if let existing = cache.removeValue(forKey: key) {
                totalCacheBytes -= existing.byteCost
            }
            cache[key] = CacheEntry(image: made, byteCost: cost, lastUsedStamp: nextUseStamp)
            totalCacheBytes += cost
            while cache.count > Self.maxCacheEntries || totalCacheBytes > Self.maxCacheByteCost {
                guard let victim = cache.min(by: { $0.value.lastUsedStamp < $1.value.lastUsedStamp })?.key,
                      victim != key else { break }
                if let removed = cache.removeValue(forKey: victim) {
                    totalCacheBytes -= removed.byteCost
                }
            }
            lock.unlock()
        }
        return made
    }

    private struct LineMetrics {
        let colorLine: CTLine
        let blackLine: CTLine?
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        var height: CGFloat { ascent + descent }
    }

    private static func render(_ key: Key, canRender: @Sendable (CGFloat) -> Bool) -> Image? {
        guard !key.text.isEmpty else { return nil }
        let requestedScale = key.scale > 0 ? key.scale : 1
        let fontSize: CGFloat
        if let presentation = key.presentation {
            fontSize = CGFloat(DanmakuRenderPreferences.bulletPointSize(
                wireFontSize: key.fontSize,
                presentation: presentation,
                fontScale: Double(key.fontScale)
            ))
        } else {
            fontSize = CGFloat(DanmakuRenderPreferences.bulletPointSize(
                wireFontSize: key.fontSize,
                pictureHeight: Double(key.pictureHeight),
                fontScale: Double(key.fontScale)
            ))
        }
        let font = CTFontCreateWithName(key.fontPostScriptName as CFString, fontSize, nil)
        let color = CGColor(
            red: CGFloat((key.colorRGB >> 16) & 0xFF) / 255,
            green: CGFloat((key.colorRGB >> 8) & 0xFF) / 255,
            blue: CGFloat(key.colorRGB & 0xFF) / 255,
            alpha: 1
        )
        let foreground = NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String)
        let strokeColor = CGColor(gray: 0, alpha: 0.72)
        let fontAscent = CTFontGetAscent(font)
        let fontDescent = CTFontGetDescent(font)
        let rawLines = key.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var measuredLines: [LineMetrics] = []
        measuredLines.reserveCapacity(rawLines.count)
        var maxLineWidth: CGFloat = 0
        for lineText in rawLines {
            let colorLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: lineText, attributes: [
                    .font: font,
                    foreground: color,
                ])
            )
            let blackLine: CTLine? = key.hasStroke
                ? CTLineCreateWithAttributedString(
                    NSAttributedString(string: lineText, attributes: [
                        .font: font,
                        foreground: strokeColor,
                    ])
                )
                : nil
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(colorLine, &ascent, &descent, nil))
            let resolvedAscent = ascent > 0 ? ascent : fontAscent
            let resolvedDescent = descent > 0 ? descent : fontDescent
            maxLineWidth = max(maxLineWidth, lineWidth)
            measuredLines.append(LineMetrics(
                colorLine: colorLine,
                blackLine: blackLine,
                width: lineWidth,
                ascent: resolvedAscent,
                descent: resolvedDescent
            ))
        }
        let lineGap: CGFloat = measuredLines.count > 1 ? ceil(fontSize * 0.15) : 0
        let totalLineHeight = measuredLines.reduce(0) { $0 + $1.height }
            + lineGap * CGFloat(max(0, measuredLines.count - 1))
        guard maxLineWidth > 0, totalLineHeight > 0 else { return nil }

        let edge: CGFloat = key.hasStroke ? max(0.85, 2.0 / requestedScale) : 0
        let shadowPad: CGFloat = key.hasStroke ? 1.5 : 0
        let frameInset: CGFloat = key.selfSentFrame
            ? Self.selfSentFrameWidth + Self.selfSentFramePadding
            : 0
        let pad = edge + shadowPad
        let pointWidth = maxLineWidth + pad * 2 + frameInset * 2
        let pointHeight = totalLineHeight + pad * 2 + frameInset * 2

        let maxScaleByWidth = CGFloat(Self.maxPixelWidth) / pointWidth
        let maxScaleByHeight = CGFloat(Self.maxPixelHeight) / pointHeight
        let maxScaleByArea = sqrt(CGFloat(Self.maxPixelArea) / (pointWidth * pointHeight))
        let scale = min(requestedScale, maxScaleByWidth, maxScaleByHeight, maxScaleByArea)
        guard scale.isFinite, scale >= Self.minimumEffectiveScale else { return nil }

        let pixelWidth = min(Self.maxPixelWidth, max(1, Int(ceil(pointWidth * scale))))
        let pixelHeight = min(Self.maxPixelHeight, max(1, Int(ceil(pointHeight * scale))))
        guard pixelWidth * pixelHeight <= Self.maxPixelArea else { return nil }
        guard canRender(CGFloat(pixelWidth) / scale) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        if key.selfSentFrame {
            let half = Self.selfSentFrameWidth / 2
            context.setStrokeColor(color)
            context.setLineWidth(Self.selfSentFrameWidth)
            context.stroke(CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight).insetBy(dx: half, dy: half))
        }
        var topCursor = pointHeight - pad - frameInset
        for (index, line) in measuredLines.enumerated() {
            let baselineY = topCursor - line.ascent
            if line.width > 0 {
                drawGlyphs(
                    in: context,
                    colorLine: line.colorLine,
                    blackLine: line.blackLine,
                    baseline: CGPoint(x: pad + frameInset, y: baselineY),
                    edge: edge
                )
            }
            topCursor -= line.height
            if index + 1 < measuredLines.count {
                topCursor -= lineGap
            }
        }
        guard let contents = context.makeImage() else { return nil }
        return Image(
            width: CGFloat(pixelWidth) / scale,
            height: CGFloat(pixelHeight) / scale,
            scale: scale,
            contents: contents
        )
    }

    private static func drawGlyphs(
        in context: CGContext,
        colorLine: CTLine,
        blackLine: CTLine?,
        baseline: CGPoint,
        edge: CGFloat
    ) {
        if let blackLine {
            let diag = edge * 0.72
            let steps: [(CGFloat, CGFloat)] = [
                (-edge, 0), (edge, 0), (0, -edge), (0, edge),
                (-diag, -diag), (diag, -diag), (-diag, diag), (diag, diag),
            ]
            for step in steps {
                context.textPosition = CGPoint(x: baseline.x + step.0, y: baseline.y + step.1)
                CTLineDraw(blackLine, context)
            }
        }
        context.saveGState()
        if blackLine != nil {
            context.setShadow(
                offset: CGSize(width: 0, height: -0.6),
                blur: 1.2,
                color: CGColor(gray: 0, alpha: 0.50)
            )
        }
        context.textPosition = baseline
        CTLineDraw(colorLine, context)
        context.restoreGState()
    }
}
