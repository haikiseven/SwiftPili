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

    static func isAttributedText(
        _ attributed: NSAttributedString,
        truncatedAtWidth width: CGFloat,
        lineLimit: Int
    ) -> Bool {
        let fullHeight = measuredHeight(of: attributed, width: width, maximumNumberOfLines: 0)
        let cappedHeight = measuredHeight(of: attributed, width: width, maximumNumberOfLines: lineLimit)
        return fullHeight > cappedHeight + 1
    }

    private static func measuredHeight(
        of attributed: NSAttributedString,
        width: CGFloat,
        maximumNumberOfLines: Int
    ) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maximumNumberOfLines
        container.lineBreakMode = maximumNumberOfLines > 0 ? .byTruncatingTail : .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height
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

    static func inlineLinks(in text: String) -> [String: URL] {
        var found: [String: URL] = [:]
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if let urlRegex {
            for match in urlRegex.matches(in: text, range: fullRange) {
                var raw = nsText.substring(with: match.range)
                while let last = raw.last, ".,;:!?)]}。，！？；：】」》）".contains(last) { raw.removeLast() }
                if let url = URL(string: raw) { found[raw] = url }
            }
        }
        if let bvRegex {
            for match in bvRegex.matches(in: text, range: fullRange) {
                let token = nsText.substring(with: match.range(at: 1))
                if let bvid = BiliLinkResolver.normalizedBVID(token),
                   let url = URL(string: "https://www.bilibili.com/video/\(bvid)") {
                    found[token] = url
                }
            }
        }
        if let avRegex {
            for match in avRegex.matches(in: text, range: fullRange) {
                let token = nsText.substring(with: match.range(at: 1))
                if let aid = BiliLinkResolver.parsedAID(token, allowBareNumeric: false),
                   let url = URL(string: "https://www.bilibili.com/video/av\(aid)") {
                    found[token] = url
                }
            }
        }
        return found
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
