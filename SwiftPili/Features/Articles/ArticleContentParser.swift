import Foundation

enum ArticleBlock: Sendable, Hashable {
    case heading(String)
    case paragraph(String)
    case quote(String)
    case listItem(String)
    case caption(String)
    case image(URL)
}

struct IndexedArticleBlock: Identifiable, Sendable, Equatable {
    let id: String
    let block: ArticleBlock
    let imageIndex: Int?
}

enum ArticleContentParser {
    private static let blockRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<(p|h1|h2|h3|h4|h5|h6|figure|blockquote|ul|ol)[^>]*>(.*?)</\\1>",
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
        var content = pageHTML
        if let start = content.range(of: "id=\"read-article-holder\"") {
            content = String(content[start.upperBound...])
        }
        for endMarker in ["id=\"read-interaction-holder\"", "class=\"read-more\"", "id=\"comment-holder\""] {
            if let end = content.range(of: endMarker) {
                content = String(content[..<end.lowerBound])
                break
            }
        }

        guard let regex = blockRegex else { return [] }
        var blocks: [ArticleBlock] = []
        let nsText = content as NSString
        regex.enumerateMatches(in: content, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match else { return }
            let tag = nsText.substring(with: match.range(at: 1)).lowercased()
            let inner = nsText.substring(with: match.range(at: 2))
            blocks.append(contentsOf: parseBlock(tag: tag, inner: inner))
        }
        return blocks
    }

    static func indexBlocks(_ blocks: [ArticleBlock]) -> [IndexedArticleBlock] {
        var counts: [ArticleBlock: Int] = [:]
        var nextImageIndex = 0
        return blocks.map { block in
            let occurrence = counts[block, default: 0]
            counts[block] = occurrence + 1
            let imageIndex: Int?
            if case .image = block {
                imageIndex = nextImageIndex
                nextImageIndex += 1
            } else {
                imageIndex = nil
            }
            let baseID: String = switch block {
            case .heading(let text): "h:\(text)"
            case .paragraph(let text): "p:\(text)"
            case .quote(let text): "q:\(text)"
            case .listItem(let text): "li:\(text)"
            case .caption(let text): "cap:\(text)"
            case .image(let url): "img:\(url.absoluteString)"
            }
            return IndexedArticleBlock(
                id: "\(baseID)#\(occurrence)",
                block: block,
                imageIndex: imageIndex
            )
        }
    }

    private static func parseBlock(tag: String, inner: String) -> [ArticleBlock] {
        var result: [ArticleBlock] = []
        let images = extractImages(inner)
        let text = cleanText(inner)

        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if !text.isEmpty { result.append(.heading(text)) }
        case "blockquote":
            if !text.isEmpty { result.append(.quote(text)) }
        case "ul", "ol":
            for item in listItems(inner) where !item.isEmpty {
                result.append(.listItem(item))
            }
        case "figure":
            result.append(contentsOf: images.map { .image($0) })
            if !text.isEmpty { result.append(.caption(text)) }
            return result
        default:
            if !text.isEmpty { result.append(.paragraph(text)) }
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

    private static func listItems(_ html: String) -> [String] {
        guard let regex = listItemRegex else { return [] }
        let nsHTML = html as NSString
        var items: [String] = []
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: nsHTML.length)) { match, _, _ in
            guard let match else { return }
            items.append(cleanText(nsHTML.substring(with: match.range(at: 1))))
        }
        return items
    }

    static func cleanText(_ html: String) -> String {
        var working = html
        if working.contains("<") {
            if let lineBreakRegex {
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
        working = HTMLEntityDecoder.decode(working)
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
