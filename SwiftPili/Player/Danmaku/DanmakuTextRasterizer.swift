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

    static let selfSentFrameWidth: CGFloat = 1
    static let selfSentFramePadding: CGFloat = 2

    typealias Render = @Sendable (Key, @Sendable (CGFloat) -> Bool) -> Image?
    private let render: Render

    init(render: Render? = nil) {
        self.render = render ?? Self.render
    }

    private let queue = DispatchQueue(label: "danmaku.raster", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [Key: Image] = [:]
    private static let cacheCapacity = 256

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
            lock.unlock()
            return canRender(hit.width) ? hit : nil
        }
        lock.unlock()
        guard let made = render(key, canRender) else { return nil }
        lock.lock()
        cache[key] = made
        while cache.count > Self.cacheCapacity {
            guard let victim = cache.first(where: { $0.key != key })?.key else { break }
            cache.removeValue(forKey: victim)
        }
        lock.unlock()
        return made
    }

    private static func render(_ key: Key, canRender: @Sendable (CGFloat) -> Bool) -> Image? {
        guard !key.text.isEmpty else { return nil }
        let scale = key.scale > 0 ? key.scale : 1
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
        let colorLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: key.text, attributes: [
                .font: font,
                foreground: color,
            ])
        )
        let edge: CGFloat = key.hasStroke ? max(0.85, 2.0 / scale) : 0
        let shadowPad: CGFloat = key.hasStroke ? 1.5 : 0
        let blackLine: CTLine? = key.hasStroke
            ? CTLineCreateWithAttributedString(
                NSAttributedString(string: key.text, attributes: [
                    .font: font,
                    foreground: CGColor(gray: 0, alpha: 0.72),
                ])
            )
            : nil
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let typographicWidth = CGFloat(CTLineGetTypographicBounds(colorLine, &ascent, &descent, nil))
        guard typographicWidth > 0, ascent + descent > 0 else { return nil }
        let typographicHeight = ascent + descent
        let frameInset: CGFloat = key.selfSentFrame
            ? Self.selfSentFrameWidth + Self.selfSentFramePadding
            : 0
        let pad = edge + shadowPad
        let pointWidth = typographicWidth + pad * 2 + frameInset * 2
        let pointHeight = typographicHeight + pad * 2 + frameInset * 2
        let pixelWidth = max(1, Int(ceil(pointWidth * scale)))
        let pixelHeight = max(1, Int(ceil(pointHeight * scale)))
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
        let baseline = CGPoint(x: pad + frameInset, y: descent + pad + frameInset)
        drawGlyphs(
            in: context,
            colorLine: colorLine,
            blackLine: blackLine,
            baseline: baseline,
            edge: edge
        )
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
