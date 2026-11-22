import CoreText
import Foundation
import UIKit

/// Rasterizes bullet text off the main thread.
///
/// `CATextLayer` redraws CJK on the main thread when its string changes. The
/// cache key is the visible identity of a bullet: the same line is drawn once
/// and reused. `image(for:)` only schedules serial work; measuring and
/// drawing the glyphs stay off the main thread.
final class DanmakuTextRasterizer: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let text: String
        let fontSize: Int
        let colorRGB: UInt32
        let hasStroke: Bool
        /// Pixels per point. Part of the key so a 1× bitmap is never reused at 3×.
        let scale: CGFloat
        /// PostScript name. Scroll bullets leave the default, which is PingFang
        /// SC. Advanced bullets pass `DanmakuAdvancedFontMapping`. Part of the
        /// key so two faces of one string do not share a bitmap.
        let fontPostScriptName: String
        /// Multiplies the wire size after it is scaled to the picture.
        /// 1 leaves that size unchanged. Part of the key so two scales do not
        /// share a bitmap.
        let fontScale: CGFloat
        /// Overlay height in points. Part of the key so a portrait bitmap is
        /// never reused in landscape. Missing or non-finite becomes the 360pt
        /// font reference, not the 720 mode-7 stage. The rim is decided by
        /// `hasStroke`, not a separate bit.
        let pictureHeight: CGFloat
        /// Ordinary bullets: sized by presentation (`DanmakuRenderPreferences
        /// .bulletPointSize(wireFontSize:presentation:fontScale:)`), and
        /// `pictureHeight` is left at the reference. Nil is mode 7, which is
        /// still sized by `pictureHeight`.
        let presentation: DanmakuPresentation?
        /// The viewer's own bullet: a thin frame around the text, the way
        /// Bilibili marks what you sent. Part of the key so the framed and
        /// unframed copies of one line never share a bitmap.
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
        /// Typographic size in points. Layer bounds use this, not the bitmap's pixel size.
        let width: CGFloat
        let height: CGFloat
        /// Scale the bitmap was drawn at. The layer's `contentsScale` must match.
        let scale: CGFloat
        /// Pixel buffer. Its pixel dimensions are `width × scale` by `height × scale`.
        let contents: CGImage
    }

    /// Frame around the viewer's own bullet: line width and the clear space
    /// between the frame and the glyphs, in points.
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
            // Width zero is a conservative cancellation check before any
            // cache/CoreText work. The exact width check follows measurement.
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
        // An empty line has no glyphs. `max(1, …)` would still build a 1px
        // image and the placer would give it a lane. Drop it here.
        guard !key.text.isEmpty else { return nil }
        // Caller passes the screen scale. This runs off the main thread, so it
        // must not touch UIScreen. Pixel size is the typographic point size × scale.
        let scale = key.scale > 0 ? key.scale : 1
        // Ordinary bullets: wire size against the presentation's reference
        // size. Mode 7: wire size against the picture height. Both then take
        // the user's font scale and clamp. The face is the key's PostScript name. Scroll bullets leave
        // it at PingFang SC. Helvetica — what Core Text substitutes for a name
        // it cannot find — has no CJK, so callers must pass a mapped name.
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
        // Core Text ignores NSAttributedString.Key.foregroundColor when the
        // value is a CGColor, so every bullet was drawn in one default color.
        let foreground = NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String)
        let colorLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: key.text, attributes: [
                .font: font,
                foreground: color,
            ])
        )
        // A contour stroke follows every hole in a CJK glyph, so 口/日/目 grow a
        // black interior. Bilibili's edge is the filled shape shifted in eight
        // directions, then the colored fill on top with a subtle drop shadow.
        // Using ~0.85pt with 0.72 alpha keeps CJK counters open while giving
        // crisp separation against bright video frames on @2x/@3x displays.
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
        // Zero-width (and a line with no ascent or descent) is the same miss
        // as an empty string: do not promote it to a 1px layer.
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
        // The actual bitmap width includes the rim/frame and pixel rounding.
        // Check cancellation/expiry before allocating or drawing the buffer.
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
        // CGBitmapContext's origin is the bottom. CALayer shows that bottom at
        // the bottom of the layer, so Core Text's upward draw is already
        // upright. Flipping Y here turned every glyph upside down.
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        if key.selfSentFrame {
            // In the bullet's own color, stroked on the half-width inset so the
            // whole line lands inside the bitmap.
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
