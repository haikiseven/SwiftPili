import CoreText
import Foundation
import os
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
    private static let maxFontCacheEntries = 32
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()
    private static let strokeColor = CGColor(gray: 0, alpha: 0.72)
    private static let shadowColor = CGColor(gray: 0, alpha: 0.50)
    private static let foregroundKey = NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String)

    private struct FontCacheKey: Hashable, Sendable {
        let name: String
        let sizeBits: UInt64
    }

    private struct CachedFont: @unchecked Sendable {
        let font: CTFont
        let ascent: CGFloat
        let descent: CGFloat
    }

    private static let fontCache = OSAllocatedUnfairLock<[FontCacheKey: CachedFont]>(initialState: [:])

    private static func cachedFont(named name: String, size: CGFloat) -> CachedFont {
        let key = FontCacheKey(name: name, sizeBits: Double(size).bitPattern)
        if let hit = fontCache.withLock({ $0[key] }) {
            return hit
        }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let entry = CachedFont(
            font: font,
            ascent: CTFontGetAscent(font),
            descent: CTFontGetDescent(font)
        )
        fontCache.withLock { cache in
            if cache.count >= maxFontCacheEntries {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = entry
        }
        return entry
    }

    typealias Render = @Sendable (Key, @Sendable (CGFloat) -> Bool) -> Image?
    private let render: Render

    private final class CacheNode {
        let key: Key
        var image: Image
        var byteCost: Int
        var prev: CacheNode?
        var next: CacheNode?

        init(key: Key, image: Image, byteCost: Int) {
            self.key = key
            self.image = image
            self.byteCost = byteCost
        }
    }

    private let queue = DispatchQueue(label: "danmaku.raster", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [Key: CacheNode] = [:]
    private var lruHead: CacheNode?
    private var lruTail: CacheNode?
    private var totalCacheBytes = 0
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
        clearCache()
    }

    func clearCache() {
        lock.lock()
        var node = lruHead
        while let current = node {
            let next = current.next
            current.prev = nil
            current.next = nil
            node = next
        }
        lruHead = nil
        lruTail = nil
        cache.removeAll()
        totalCacheBytes = 0
        lock.unlock()
        Self.fontCache.withLock { $0.removeAll() }
    }

    private func moveToFront(_ node: CacheNode) {
        guard lruHead !== node else { return }
        detach(node)
        prepend(node)
    }

    private func prepend(_ node: CacheNode) {
        node.prev = nil
        node.next = lruHead
        lruHead?.prev = node
        lruHead = node
        if lruTail == nil { lruTail = node }
    }

    private func detach(_ node: CacheNode) {
        let prev = node.prev
        let next = node.next
        if let prev { prev.next = next } else { lruHead = next }
        if let next { next.prev = prev } else { lruTail = prev }
        node.prev = nil
        node.next = nil
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
        if let hit = cache[key] {
            moveToFront(hit)
            let image = hit.image
            lock.unlock()
            return canRender(image.width) ? image : nil
        }
        lock.unlock()
        guard let made = render(key, canRender) else { return nil }
        let cost = made.contents.bytesPerRow * made.contents.height
        if cost <= Self.maxCacheByteCost / 2 {
            lock.lock()
            if let existing = cache[key] {
                totalCacheBytes -= existing.byteCost
                existing.image = made
                existing.byteCost = cost
                totalCacheBytes += cost
                moveToFront(existing)
            } else {
                let node = CacheNode(key: key, image: made, byteCost: cost)
                cache[key] = node
                prepend(node)
                totalCacheBytes += cost
            }
            while cache.count > Self.maxCacheEntries || totalCacheBytes > Self.maxCacheByteCost {
                guard let victim = lruTail, victim.key != key else { break }
                detach(victim)
                cache.removeValue(forKey: victim.key)
                totalCacheBytes -= victim.byteCost
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

    private static func makeLineMetrics(
        text: String,
        font: CTFont,
        fontAscent: CGFloat,
        fontDescent: CGFloat,
        color: CGColor,
        hasStroke: Bool
    ) -> LineMetrics {
        let colorLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [
                .font: font,
                foregroundKey: color,
            ])
        )
        let blackLine: CTLine? = hasStroke
            ? CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [
                    .font: font,
                    foregroundKey: strokeColor,
                ])
            )
            : nil
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(colorLine, &ascent, &descent, nil))
        return LineMetrics(
            colorLine: colorLine,
            blackLine: blackLine,
            width: lineWidth,
            ascent: ascent > 0 ? ascent : fontAscent,
            descent: descent > 0 ? descent : fontDescent
        )
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
        let cached = cachedFont(named: key.fontPostScriptName, size: fontSize)
        let font = cached.font
        let fontAscent = cached.ascent
        let fontDescent = cached.descent
        let color = CGColor(
            red: CGFloat((key.colorRGB >> 16) & 0xFF) / 255,
            green: CGFloat((key.colorRGB >> 8) & 0xFF) / 255,
            blue: CGFloat(key.colorRGB & 0xFF) / 255,
            alpha: 1
        )
        let isMultiline = key.text.utf8.contains { $0 == 0x0A || $0 == 0x0D }
        let singleLine: LineMetrics?
        var measuredLines: [LineMetrics] = []
        let maxLineWidth: CGFloat
        let lineGap: CGFloat
        let totalLineHeight: CGFloat
        if !isMultiline {
            let line = makeLineMetrics(
                text: key.text,
                font: font,
                fontAscent: fontAscent,
                fontDescent: fontDescent,
                color: color,
                hasStroke: key.hasStroke
            )
            singleLine = line
            maxLineWidth = line.width
            lineGap = 0
            totalLineHeight = line.height
        } else {
            singleLine = nil
            let rawLines = key.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
            measuredLines.reserveCapacity(rawLines.count)
            var widest: CGFloat = 0
            var heightSum: CGFloat = 0
            for rawLine in rawLines {
                let line = makeLineMetrics(
                    text: String(rawLine),
                    font: font,
                    fontAscent: fontAscent,
                    fontDescent: fontDescent,
                    color: color,
                    hasStroke: key.hasStroke
                )
                widest = max(widest, line.width)
                heightSum += line.height
                measuredLines.append(line)
            }
            maxLineWidth = widest
            lineGap = measuredLines.count > 1 ? ceil(fontSize * 0.15) : 0
            totalLineHeight = heightSum + lineGap * CGFloat(max(0, measuredLines.count - 1))
        }
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
            space: deviceRGB,
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
        if let line = singleLine {
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
        } else {
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
            let bx = baseline.x
            let by = baseline.y
            context.textPosition = CGPoint(x: bx - edge, y: by)
            CTLineDraw(blackLine, context)
            context.textPosition = CGPoint(x: bx + edge, y: by)
            CTLineDraw(blackLine, context)
            context.textPosition = CGPoint(x: bx, y: by - edge)
            CTLineDraw(blackLine, context)
            context.textPosition = CGPoint(x: bx, y: by + edge)
            CTLineDraw(blackLine, context)
            context.textPosition = CGPoint(x: bx - diag, y: by - diag)
            CTLineDraw(blackLine, context)
            context.textPosition = CGPoint(x: bx + diag, y: by - diag)
            CTLineDraw(blackLine, context)
            context.textPosition = CGPoint(x: bx - diag, y: by + diag)
            CTLineDraw(blackLine, context)
            context.textPosition = CGPoint(x: bx + diag, y: by + diag)
            CTLineDraw(blackLine, context)
        }
        context.saveGState()
        if blackLine != nil {
            context.setShadow(
                offset: CGSize(width: 0, height: -0.6),
                blur: 1.2,
                color: shadowColor
            )
        }
        context.textPosition = baseline
        CTLineDraw(colorLine, context)
        context.restoreGState()
    }
}
