import Foundation

enum ArticleBlock: Sendable, Hashable {
    case heading(AttributedString)
    case paragraph(AttributedString)
    case quote(AttributedString)
    case listItem(AttributedString)
    case caption(AttributedString)
    case image(URL)
}

struct IndexedArticleBlock: Identifiable, Sendable, Equatable {
    let id: String
    let block: ArticleBlock
    let imageIndex: Int?
}

struct ParsedArticleContent: Sendable {
    let blocks: [ArticleBlock]
    let indexedBlocks: [IndexedArticleBlock]
    let imageURLs: [URL]
}

enum ArticleContentParser {
    private static let blockRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<(p|h1|h2|h3|h4|h5|h6|figure|blockquote|ul|ol)[^>]*>(.*?)</\\1>",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let anchorRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<a\\b[^>]*?\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')[^>]*>(.*?)</a>",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let imageSrcRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<img[^>]*?(?:data-src|src)=\"([^\"]+)\"",
        options: .caseInsensitive
    )
    private static let listItemRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<li[^>]*>(.*?)</li>",
        options: [.dotMatchesLineSeparators, .caseInsensitive]
    )
    private static let lineBreakRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<br[^>]*>",
        options: .caseInsensitive
    )
    private static let htmlTagRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<[^>]+>"
    )

    static func parse(pageHTML: String) -> [ArticleBlock] {
        let startIndex = pageHTML.range(of: "id=\"read-article-holder\"")?.upperBound ?? pageHTML.startIndex
        var endIndex = pageHTML.endIndex
        for endMarker in ["id=\"read-interaction-holder\"", "class=\"read-more\"", "id=\"comment-holder\""] {
            if let end = pageHTML.range(of: endMarker, range: startIndex..<endIndex) {
                endIndex = end.lowerBound
                break
            }
        }

        guard let regex = blockRegex, startIndex < endIndex else { return [] }
        var blocks: [ArticleBlock] = []
        let nsText = pageHTML as NSString
        let searchRange = NSRange(startIndex..<endIndex, in: pageHTML)
        regex.enumerateMatches(in: pageHTML, range: searchRange) { match, _, _ in
            guard let match else { return }
            let tag = nsText.substring(with: match.range(at: 1)).lowercased()
            let inner = nsText.substring(with: match.range(at: 2))
            blocks.append(contentsOf: parseBlock(tag: tag, inner: inner))
        }
        return blocks
    }

    static func parseIndexed(pageHTML: String) -> ParsedArticleContent {
        let blocks = parse(pageHTML: pageHTML)
        let (indexed, imageURLs) = indexBlocksWithImages(blocks)
        return ParsedArticleContent(blocks: blocks, indexedBlocks: indexed, imageURLs: imageURLs)
    }

    static func indexBlocks(_ blocks: [ArticleBlock]) -> [IndexedArticleBlock] {
        indexBlocksWithImages(blocks).indexed
    }

    static func indexBlocksWithImages(
        _ blocks: [ArticleBlock]
    ) -> (indexed: [IndexedArticleBlock], imageURLs: [URL]) {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(blocks.count)
        var indexed: [IndexedArticleBlock] = []
        indexed.reserveCapacity(blocks.count)
        var imageURLs: [URL] = []

        for block in blocks {
            let imageIndex: Int?
            let baseID: String
            switch block {
            case .heading(let text):
                imageIndex = nil
                baseID = "h:\(stableHash(text))"
            case .paragraph(let text):
                imageIndex = nil
                baseID = "p:\(stableHash(text))"
            case .quote(let text):
                imageIndex = nil
                baseID = "q:\(stableHash(text))"
            case .listItem(let text):
                imageIndex = nil
                baseID = "li:\(stableHash(text))"
            case .caption(let text):
                imageIndex = nil
                baseID = "cap:\(stableHash(text))"
            case .image(let url):
                imageIndex = imageURLs.count
                imageURLs.append(url)
                baseID = "img:\(url.absoluteString)"
            }
            let occurrence = counts[baseID, default: 0]
            counts[baseID] = occurrence + 1
            indexed.append(IndexedArticleBlock(
                id: "\(baseID)#\(occurrence)",
                block: block,
                imageIndex: imageIndex
            ))
        }
        return (indexed, imageURLs)
    }

    private static func stableHash(_ text: AttributedString) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for character in text.characters {
            for byte in character.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
        }
        return hash
    }

    private static func parseBlock(tag: String, inner: String) -> [ArticleBlock] {
        var result: [ArticleBlock] = []
        let images = extractImages(inner)
        let text = parseRichText(inner)

        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if !text.characters.isEmpty { result.append(.heading(text)) }
        case "blockquote":
            if !text.characters.isEmpty { result.append(.quote(text)) }
        case "ul", "ol":
            for item in listItems(inner) where !item.characters.isEmpty {
                result.append(.listItem(item))
            }
        case "figure":
            result.append(contentsOf: images.map { .image($0) })
            if !text.characters.isEmpty { result.append(.caption(text)) }
            return result
        default:
            if !text.characters.isEmpty { result.append(.paragraph(text)) }
        }
        result.append(contentsOf: images.map { .image($0) })
        return result
    }

    private static func extractImages(_ html: String) -> [URL] {
        guard html.contains("<"), let regex = imageSrcRegex else { return [] }
        let nsHTML = html as NSString
        var urls: [URL] = []
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: nsHTML.length)) { match, _, _ in
            guard let match else { return }
            var src = nsHTML.substring(with: match.range(at: 1))
            if src.hasPrefix("//") { src = "https:" + src }
            src = src.replacingOccurrences(of: "http://", with: "https://")
            if let atIndex = src.firstIndex(of: "@") { src = String(src[..<atIndex]) }
            if let url = URL(string: src), url.scheme == "https" {
                urls.append(url)
            }
        }
        return urls
    }

    private static func listItems(_ html: String) -> [AttributedString] {
        guard let regex = listItemRegex else { return [] }
        let nsHTML = html as NSString
        var items: [AttributedString] = []
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: nsHTML.length)) { match, _, _ in
            guard let match else { return }
            items.append(parseRichText(nsHTML.substring(with: match.range(at: 1))))
        }
        return items
    }

    static func parseRichText(_ html: String) -> AttributedString {
        guard let anchorRegex, html.range(of: "<a", options: .caseInsensitive) != nil else {
            let plain = cleanText(html)
            return plain.isEmpty ? AttributedString() : linkifiedPlainText(plain)
        }

        let nsHTML = html as NSString
        let matches = anchorRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else {
            let plain = cleanText(html)
            return plain.isEmpty ? AttributedString() : linkifiedPlainText(plain)
        }

        var result = AttributedString()
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let prefixHTML = nsHTML.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                let prefixText = cleanRawFragment(prefixHTML)
                if !prefixText.isEmpty {
                    result.append(linkifiedPlainText(prefixText))
                }
            }

            let rawHref: String
            if match.range(at: 1).location != NSNotFound {
                rawHref = nsHTML.substring(with: match.range(at: 1))
            } else if match.range(at: 2).location != NSNotFound {
                rawHref = nsHTML.substring(with: match.range(at: 2))
            } else {
                rawHref = ""
            }
            let innerHTML = nsHTML.substring(with: match.range(at: 3))
            let label = cleanRawFragment(innerHTML)
            if !label.isEmpty {
                var piece = AttributedString(label)
                if let url = normalizedHref(rawHref) {
                    piece.link = url
                }
                result.append(piece)
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < nsHTML.length {
            let suffixHTML = nsHTML.substring(from: cursor)
            let suffixText = cleanRawFragment(suffixHTML)
            if !suffixText.isEmpty {
                result.append(linkifiedPlainText(suffixText))
            }
        }
        return trimmed(result)
    }

    private static func linkifiedPlainText(_ text: String) -> AttributedString {
        let links = UIKitDynamicRichTextBuilder.inlineLinks(in: text)
        guard !links.isEmpty else { return AttributedString(text) }
        let runs = EmoteText.linkRuns(text, links: links)
        var attributed = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if let url = run.url {
                piece.link = url
            }
            attributed.append(piece)
        }
        return attributed
    }

    private static func normalizedHref(_ raw: String) -> URL? {
        var decoded = HTMLEntityDecoder.decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        if decoded.hasPrefix("//") {
            decoded = "https:" + decoded
        }
        let lower = decoded.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("bilibili://") else {
            return nil
        }
        return URL(string: decoded) ?? URL(string: decoded, encodingInvalidCharacters: true)
    }

    private static func trimmed(_ attributed: AttributedString) -> AttributedString {
        let chars = attributed.characters
        guard let start = chars.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) else {
            return AttributedString()
        }
        var end = chars.endIndex
        while end > start {
            let prev = chars.index(before: end)
            if !chars[prev].isWhitespace && !chars[prev].isNewline {
                break
            }
            end = prev
        }
        return AttributedString(attributed[start..<end])
    }

    private static func cleanRawFragment(_ html: String) -> String {
        var working = html
        if working.contains("<") {
            if let lineBreakRegex, working.range(of: "<br", options: .caseInsensitive) != nil {
                working = lineBreakRegex.stringByReplacingMatches(
                    in: working,
                    range: NSRange(working.startIndex..., in: working),
                    withTemplate: "\n"
                )
            }
            if let htmlTagRegex {
                working = htmlTagRegex.stringByReplacingMatches(
                    in: working,
                    range: NSRange(working.startIndex..., in: working),
                    withTemplate: ""
                )
            }
        }
        return HTMLEntityDecoder.decode(working)
    }

    static func cleanText(_ html: String) -> String {
        cleanRawFragment(html).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
