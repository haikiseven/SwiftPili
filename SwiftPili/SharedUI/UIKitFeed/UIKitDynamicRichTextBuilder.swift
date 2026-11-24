import os
import SwiftUI
import UIKit

enum UIKitDynamicRichTextBuilder {
    private static let urlRegex = try? NSRegularExpression(
        pattern: #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#
    )
    private static let bvRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([Bb][Vv][A-HJ-NP-Za-km-z1-9]{10})(?![A-Za-z0-9])"#
    )
    private static let avRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([Aa][Vv]\d{1,12})(?![A-Za-z0-9])"#
    )

    struct StyleOptions {
        let font: UIFont
        let lineSpacing: CGFloat
        let accent: UIColor
        let detectTimestamps: Bool
    }

    static func makeAttributedString(
        for segment: DynamicRichContent.TextSegment,
        options: StyleOptions,
        emoteImage: (String) -> UIImage?
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = options.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: options.font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]

        if let fallback = segment.fallback {
            return makePlainAttributedString(
                fallback,
                baseAttributes: baseAttributes,
                accent: options.accent,
                detectTimestamps: options.detectTimestamps
            )
        }

        let result = NSMutableAttributedString()
        for node in segment.nodes {
            if node.type == "RICH_TEXT_NODE_TYPE_EMOJI",
               let source = DynamicRichContent.imageURL(node.emoji?.source)?.absoluteString,
               let image = emoteImage(source) {
                let attachment = NSTextAttachment()
                attachment.image = image
                let boxHeight = options.font.emoteBoxHeight
                let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
                attachment.bounds = CGRect(
                    x: 0,
                    y: options.font.emoteBaselineOffset,
                    width: max(1, boxHeight * ratio),
                    height: boxHeight
                )
                let attr = NSMutableAttributedString(attachment: attachment)
                attr.addAttributes(baseAttributes, range: NSRange(location: 0, length: attr.length))
                result.append(attr)
                continue
            }

            let label = DynamicRichContent.displayText(node)
            guard !label.isEmpty else { continue }
            if let target = linkTarget(node) {
                var attrs = baseAttributes
                attrs[.link] = target
                attrs[.foregroundColor] = options.accent
                result.append(NSAttributedString(string: label, attributes: attrs))
            } else {
                result.append(makePlainAttributedString(
                    label,
                    baseAttributes: baseAttributes,
                    accent: options.accent,
                    detectTimestamps: options.detectTimestamps
                ))
            }
        }
        return result
    }

    static func makePlainAttributedString(
        _ text: String,
        baseAttributes: [NSAttributedString.Key: Any],
        accent: UIColor,
        detectTimestamps: Bool
    ) -> NSAttributedString {
        var links = inlineLinks(in: text)
        if detectTimestamps {
            links.merge(EmoteText.timestampLinks(in: text)) { explicit, _ in explicit }
        }
        guard !links.isEmpty else {
            return NSAttributedString(string: text, attributes: baseAttributes)
        }
        let runs = EmoteText.linkRuns(text, links: links)
        let result = NSMutableAttributedString()
        for run in runs {
            if let url = run.url {
                var attrs = baseAttributes
                attrs[.link] = url
                attrs[.foregroundColor] = accent
                result.append(NSAttributedString(string: run.text, attributes: attrs))
            } else {
                result.append(NSAttributedString(string: run.text, attributes: baseAttributes))
            }
        }
        return result
    }

    private struct TruncationCacheKey: Hashable, Sendable {
        let text: String
        let widthHalfPoints: Int
        let lineLimit: Int
        let fontName: String
        let fontSizeTenths: Int
        let lineSpacingTenths: Int
        let attachmentSignature: Int
    }

    private static let truncationCache = OSAllocatedUnfairLock(initialState: [TruncationCacheKey: Bool]())
    private static let inlineLinkCache = OSAllocatedUnfairLock(initialState: [String: [String: URL]]())

    static func isAttributedText(
        _ attributed: NSAttributedString,
        truncatedAtWidth width: CGFloat,
        lineLimit: Int
    ) -> Bool {
        guard lineLimit > 0, width.isFinite, width > 1, attributed.length > 0 else { return false }

        let rawString = attributed.string
        var newlineCount = 0
        var mayHaveAttachment = false
        for byte in rawString.utf8 {
            if byte == 0x0A { // '\n'
                newlineCount += 1
                if newlineCount > lineLimit { return true }
            } else if byte == 0xEF { // UTF-8 lead byte of U+FFFC (NSTextAttachment)
                mayHaveAttachment = true
            }
        }

        let firstFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let firstParagraph = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        var attachmentSignature = 0
        if mayHaveAttachment {
            attributed.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: attributed.length),
                options: []
            ) { value, _, _ in
                if let attachment = value as? NSTextAttachment {
                    let w = Int((attachment.bounds.width * 2).rounded())
                    let h = Int((attachment.bounds.height * 2).rounded())
                    attachmentSignature = attachmentSignature &* 31 &+ (w &* 997 ^ h)
                }
            }
        }

        let cacheKey = TruncationCacheKey(
            text: rawString,
            widthHalfPoints: Int((width * 2).rounded()),
            lineLimit: lineLimit,
            fontName: firstFont?.fontName ?? "",
            fontSizeTenths: Int(((firstFont?.pointSize ?? 0) * 10).rounded()),
            lineSpacingTenths: Int(((firstParagraph?.lineSpacing ?? 0) * 10).rounded()),
            attachmentSignature: attachmentSignature
        )
        if let cached = truncationCache.withLock({ $0[cacheKey] }) {
            return cached
        }

        let truncated = measureTruncation(of: attributed, width: width, lineLimit: lineLimit)
        truncationCache.withLock { cache in
            if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
            cache[cacheKey] = truncated
        }
        return truncated
    }

    private static func measureTruncation(
        of attributed: NSAttributedString,
        width: CGFloat,
        lineLimit: Int
    ) -> Bool {
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lineLimit + 1
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        let laidOutGlyphs = manager.glyphRange(for: container)
        if laidOutGlyphs.upperBound < manager.numberOfGlyphs {
            return true
        }
        var lineCount = 0
        manager.enumerateLineFragments(forGlyphRange: laidOutGlyphs) { _, _, _, _, stop in
            lineCount += 1
            if lineCount > lineLimit {
                stop.pointee = true
            }
        }
        if lineCount <= lineLimit, manager.extraLineFragmentRect.height > 0 {
            lineCount += 1
        }
        return lineCount > lineLimit
    }

    static func linkTarget(_ node: DynamicRichContent.Node) -> URL? {
        switch node.type {
        case "RICH_TEXT_NODE_TYPE_AT":
            if let rid = node.rid, let mid = Int(rid), mid > 0 {
                return URL(string: "https://space.bilibili.com/\(rid)")
            }
        case "RICH_TEXT_NODE_TYPE_BV", "RICH_TEXT_NODE_TYPE_AV":
            if let rid = node.rid, !rid.isEmpty {
                if let bvid = BiliLinkResolver.normalizedBVID(rid) {
                    return URL(string: "https://www.bilibili.com/video/\(bvid)")
                }
                if let aid = BiliLinkResolver.parsedAID(rid, allowBareNumeric: true) {
                    return URL(string: "https://www.bilibili.com/video/av\(aid)")
                }
                return URL(string: "https://www.bilibili.com/video/\(rid)")
            }
        default:
            break
        }
        guard let rawJump = node.jumpUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawJump.isEmpty else { return nil }
        let normalized = rawJump.hasPrefix("//") ? "https:" + rawJump : rawJump
        return URL(string: normalized) ?? URL(string: normalized, encodingInvalidCharacters: true)
    }

    private static func scanInlineLinkHints(in text: String) -> (hasURL: Bool, hasBV: Bool, hasAV: Bool) {
        var hasURL = false
        var hasBV = false
        var hasAV = false
        var prev2: UInt8 = 0
        var prev1: UInt8 = 0
        for byte in text.utf8 {
            if !hasURL, prev2 == 0x3A, prev1 == 0x2F, byte == 0x2F { // "://"
                hasURL = true
            }
            if !hasBV, (prev1 == 0x42 || prev1 == 0x62), (byte == 0x56 || byte == 0x76) { // "BV"/"bv"
                hasBV = true
            }
            if !hasAV,
               (prev2 == 0x41 || prev2 == 0x61),
               (prev1 == 0x56 || prev1 == 0x76),
               byte >= 0x30, byte <= 0x39 { // "av" + digit
                hasAV = true
            }
            if hasURL, hasBV, hasAV { break }
            prev2 = prev1
            prev1 = byte
        }
        return (hasURL, hasBV, hasAV)
    }

    static func inlineLinks(in text: String) -> [String: URL] {
        guard text.utf8.count >= 3 else { return [:] }
        let hints = scanInlineLinkHints(in: text)
        guard hints.hasURL || hints.hasBV || hints.hasAV else { return [:] }
        if let cached = inlineLinkCache.withLock({ $0[text] }) { return cached }

        var found: [String: URL] = [:]
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if hints.hasURL, let urlRegex {
            for match in urlRegex.matches(in: text, range: fullRange) {
                var raw = nsText.substring(with: match.range)
                while let last = raw.last, ".,;:!?)]}。，！？；：】」》）".contains(last) { raw.removeLast() }
                if let url = URL(string: raw) { found[raw] = url }
            }
        }
        if hints.hasBV, let bvRegex {
            for match in bvRegex.matches(in: text, range: fullRange) {
                let token = nsText.substring(with: match.range(at: 1))
                if let bvid = BiliLinkResolver.normalizedBVID(token),
                   let url = URL(string: "https://www.bilibili.com/video/\(bvid)") {
                    found[token] = url
                }
            }
        }
        if hints.hasAV, let avRegex {
            for match in avRegex.matches(in: text, range: fullRange) {
                let token = nsText.substring(with: match.range(at: 1))
                if let aid = BiliLinkResolver.parsedAID(token, allowBareNumeric: false),
                   let url = URL(string: "https://www.bilibili.com/video/av\(aid)") {
                    found[token] = url
                }
            }
        }
        let result = found
        inlineLinkCache.withLock { cache in
            if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
            cache[text] = result
        }
        return result
    }

    static func mediaItems(
        from pictures: [DynamicRichContent.Picture]
    ) -> [UIKitDynamicDrawGridView.MediaItem] {
        pictures.compactMap { picture in
            guard let url = DynamicRichContent.imageURL(picture.source) else { return nil }
            let size: CGSize?
            if let width = picture.width, let height = picture.height, width > 0, height > 0 {
                size = CGSize(width: width, height: height)
            } else {
                size = nil
            }
            return UIKitDynamicDrawGridView.MediaItem(url: url, pixelSize: size)
        }
    }

    @MainActor
    static func pin(_ subview: UIView, inside container: UIView, verticalInset: CGFloat = 0) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset),
        ])
    }

    @MainActor
    static func hasLink(at point: CGPoint, in textView: UITextView) -> Bool {
        guard let attributed = textView.attributedText, attributed.length > 0 else { return false }
        let adjusted = CGPoint(
            x: point.x - textView.textContainerInset.left,
            y: point.y - textView.textContainerInset.top
        )
        guard let position = textView.closestPosition(to: adjusted) else { return false }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        for candidate in [offset, offset - 1] where candidate >= 0 && candidate < attributed.length {
            guard attributed.attribute(.link, at: candidate, effectiveRange: nil) != nil,
                  let start = textView.position(from: textView.beginningOfDocument, offset: candidate),
                  let end = textView.position(from: start, offset: 1),
                  let range = textView.textRange(from: start, to: end) else { continue }
            let rect = textView.convert(textView.firstRect(for: range), from: textView.textInputView)
            if rect.insetBy(dx: -6, dy: -6).contains(point) { return true }
        }
        return false
    }

    @MainActor
    static func showFallback(_ message: String, inside container: UIView, traitCollection: UITraitCollection) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let label = UILabel()
        label.text = message
        label.font = UIKitFeedFont.systemFont(textStyle: .footnote, traitCollection: traitCollection)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        pin(label, inside: container, verticalInset: 4)
    }
}
