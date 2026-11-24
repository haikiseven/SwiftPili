import Foundation

struct ChatMessageCardModule: Equatable, Sendable {
    let title: String
    let detail: String

    var summary: String {
        if !title.isEmpty && !detail.isEmpty { return "\(title): \(detail)" }
        return title.isEmpty ? detail : title
    }
}

struct ChatMessageCard: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let thumb: String?
    let url: String?
    let modules: [ChatMessageCardModule]
    let jumpText: String?
}

enum ChatMessagePayload: Equatable, Sendable {
    case recalled
    case image(String)
    case sticker(url: String, text: String?)
    case card(ChatMessageCard)
    case systemNotice(text: String, url: String?)
    case text(String)
}

enum BiliIMMessageParser {
    private static let cardLikeTypes: Set<Int> = [10, 16, 19]
    private static let bareURLRegex = try? NSRegularExpression(pattern: "(?:https?://|bilibili://)[^\\s<>\"'\\)\\]}]+")
    private static let truncatedJSONRegex = try? NSRegularExpression(pattern: "^(?:\\{\\s*\"|\\[\\s*\\{\\s*\")")
    private static let truncatedFieldRegexes: [NSRegularExpression] = [
        "title", "headline", "text", "content", "desc", "summary",
    ].compactMap { key in
        try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])+)\"")
    }

    static func parse(msgType: Int?, rawContent: String?) -> ChatMessagePayload {
        if msgType == 5 { return .recalled }
        let raw = rawContent ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyPayload(for: msgType) }

        let payload: ChatMessagePayload
        if let jsonObject = parseJSONObject(from: trimmed) {
            payload = parseStructuredPayload(msgType: msgType, object: jsonObject)
        } else if looksLikeTruncatedJSON(trimmed) {
            payload = parseTruncatedJSON(msgType: msgType, raw: trimmed)
        } else if msgType == 18 {
            payload = .systemNotice(text: trimmed, url: extractFirstURL(in: trimmed))
        } else {
            payload = .text(raw)
        }
        return enforcingNoRawJSON(payload, msgType: msgType)
    }

    static func previewText(msgType: Int?, rawContent: String?) -> String {
        if msgType == 5 { return String(localized: "[Message recalled]") }
        let raw = rawContent ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyPreview(for: msgType) }
        let payload = parse(msgType: msgType, rawContent: raw)
        let preview = renderPreview(msgType: msgType, payload: payload)
        return collapseWhitespace(sanitizeNoRawJSON(preview, msgType: msgType))
    }

    private static func parseStructuredPayload(msgType: Int?, object: Any) -> ChatMessagePayload {
        if let array = object as? [Any] { return parseArrayPayload(msgType: msgType, array: array) }
        guard let dict = object as? [String: Any] else { return .text(fallbackLabel(for: msgType)) }
        switch msgType {
        case 1: return parseTextDict(dict)
        case 2, 6: return parseMediaDict(dict, isSticker: msgType == 6)
        case 7, 11, 12, 14: return parseContentCardDict(dict, msgType: msgType ?? 7)
        case 10, 16: return parseModuleCardDict(dict, msgType: msgType)
        case 13: return parsePictureCardDict(dict)
        case 18: return parseSystemNoticeDict(dict)
        default: return parseFallbackDict(dict, msgType: msgType)
        }
    }

    private static func parseTextDict(_ dict: [String: Any]) -> ChatMessagePayload {
        guard let rawInner = dict["content"] as? String else { return parseFallbackDict(dict, msgType: 1) }
        let trimmed = rawInner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text("") }
        if let nested = parseJSONObject(from: trimmed) {
            return parseStructuredPayload(msgType: nil, object: nested)
        }
        if looksLikeTruncatedJSON(trimmed) { return parseTruncatedJSON(msgType: 1, raw: trimmed) }
        return .text(rawInner)
    }

    private static func parseMediaDict(_ dict: [String: Any], isSticker: Bool) -> ChatMessagePayload {
        let imageURL = extractImageURL(from: dict, extraKeys: isSticker ? ["emote_url"] : [], includePlainURL: true)
        if !isSticker {
            return imageURL.map(ChatMessagePayload.image) ?? .text(String(localized: "[Image]"))
        }
        let label = sanitizeOptionalText(firstString(in: dict, keys: ["text", "title", "content"]))
        return imageURL.map { .sticker(url: $0, text: label) } ?? .text(label ?? String(localized: "[Sticker]"))
    }

    private static func parseContentCardDict(_ dict: [String: Any], msgType: Int) -> ChatMessagePayload {
        let (subtitleKeys, defaultTitle): ([String], String) = switch msgType {
        case 11: (["desc", "text", "author", "times", "source_desc"], String(localized: "Video"))
        case 12: (["summary", "desc", "text", "author"], String(localized: "Article"))
        case 14: (["desc", "text", "author", "uname", "source_desc", "source"], String(localized: "Shared Content"))
        default: (["source_desc", "author", "desc", "text", "summary"], String(localized: "Shared Content"))
        }
        let title = sanitizeOptionalText(firstString(in: dict, keys: ["title", "headline"]))
        let subtitle = sanitizeOptionalText(firstString(in: dict, keys: subtitleKeys))
        let imageURLs = msgType == 12 ? (dict["image_urls"] as? [Any]) : nil
        let arrayThumb = imageURLs?.compactMap { stringValue($0).flatMap(normalizeURL) }.first(where: isHTTPURL)
        let thumb = extractImageURL(from: dict, extraKeys: ["bili_cover"]) ?? arrayThumb
        let url = extractActionURL(from: dict) ?? synthesizeContentURL(from: dict, msgType: msgType)
        let cardTitle = title ?? (msgType == 7 ? subtitle : nil) ?? defaultTitle
        return .card(ChatMessageCard(
            title: cardTitle, subtitle: subtitle == cardTitle ? nil : subtitle, thumb: thumb, url: url,
            modules: msgType == 7 ? extractModules(from: dict) : [], jumpText: extractJumpText(from: dict)
        ))
    }

    private static func parseModuleCardDict(_ dict: [String: Any], msgType: Int?) -> ChatMessagePayload {
        let rawTitle = firstString(in: dict, keys: ["title", "main_title", "headline"])
            ?? (dict["notifier"] as? [String: Any]).flatMap { firstString(in: $0, keys: ["nickname", "name"]) }
        let rawSubtitle = firstString(
            in: dict, keys: ["text", "sub_title", "headline", "summary", "desc", "reply_content", "content"]
        )
        let parsedSubtitle = SystemNotifyResult.parseContent(rawSubtitle)
        let modules = extractModules(from: dict)
        let title = sanitizeOptionalText(rawTitle)
        let subtitle = sanitizeOptionalText(parsedSubtitle.text)
        let fallbackTitle = modules.isEmpty ? nil : String(localized: "Notification")
        guard let cardTitle = title ?? subtitle ?? fallbackTitle else { return .text(fallbackLabel(for: msgType)) }
        return .card(ChatMessageCard(
            title: cardTitle, subtitle: (title != nil && subtitle != cardTitle) ? subtitle : nil,
            thumb: extractImageURL(from: dict),
            url: extractActionURL(from: dict) ?? normalizeURL(parsedSubtitle.url),
            modules: modules, jumpText: extractJumpText(from: dict) ?? parsedSubtitle.linkLabel
        ))
    }

    private static func parsePictureCardDict(_ dict: [String: Any]) -> ChatMessagePayload {
        let imageURL = extractImageURL(from: dict, includePlainURL: true)
        let title = sanitizeOptionalText(firstString(in: dict, keys: ["title", "headline"]))
        let subtitle = sanitizeOptionalText(firstString(in: dict, keys: ["text", "desc", "summary"]))
        let jumpURL = extractActionURL(from: dict, includePlainURL: false)
        if title == nil, subtitle == nil, jumpURL == nil, let imageURL { return .image(imageURL) }
        return .card(ChatMessageCard(
            title: title ?? subtitle ?? String(localized: "[Image]"),
            subtitle: title != nil ? subtitle : nil,
            thumb: imageURL, url: jumpURL, modules: [], jumpText: extractJumpText(from: dict)
        ))
    }

    private static func parseSystemNoticeDict(_ dict: [String: Any]) -> ChatMessagePayload {
        let baseURL = extractActionURL(from: dict)
        if let nodes = dict["content"] as? [Any] ?? dict["nodes"] as? [Any] ?? dict["items"] as? [Any] {
            return parseNoticeSegments(nodes, fallbackURL: baseURL)
        }
        if let contentString = stringValue(dict["content"]) {
            if let nested = parseJSONObject(from: contentString) {
                if let array = nested as? [Any] { return parseNoticeSegments(array, fallbackURL: baseURL) }
                if let subDict = nested as? [String: Any] { return parseSystemNoticeDict(subDict) }
            }
            if looksLikeTruncatedJSON(contentString) { return parseTruncatedJSON(msgType: 18, raw: contentString) }
            let parsed = SystemNotifyResult.parseContent(contentString)
            return .systemNotice(text: sanitizeNoticeText(parsed.text), url: baseURL ?? normalizeURL(parsed.url))
        }
        let extracted = extractReadableText(from: dict, depth: 0) ?? String(localized: "[Notification]")
        return .systemNotice(text: sanitizeNoticeText(extracted), url: baseURL)
    }

    private static func parseArrayPayload(msgType: Int?, array: [Any]) -> ChatMessagePayload {
        let notice = parseNoticeSegments(array, fallbackURL: nil)
        if msgType == 18 { return notice }
        if case .systemNotice(let text, let url) = notice,
           !text.isEmpty, text != String(localized: "[Notification]") {
            return url != nil ? .systemNotice(text: text, url: url) : .text(text)
        }
        return .text(extractReadableText(from: array, depth: 0) ?? fallbackLabel(for: msgType))
    }

    static func parseNoticeSegments(_ nodes: [Any], fallbackURL: String?) -> ChatMessagePayload {
        var parts: [String] = []
        var firstURL = fallbackURL
        for node in nodes {
            if let dict = node as? [String: Any] {
                if let piece = firstString(in: dict, keys: ["text", "content", "title"]) { parts.append(piece) }
                if firstURL == nil { firstURL = extractActionURL(from: dict) }
            } else if let text = stringValue(node) {
                parts.append(text)
            }
        }
        let parsed = SystemNotifyResult.parseContent(parts.joined())
        return .systemNotice(text: sanitizeNoticeText(parsed.text), url: firstURL ?? normalizeURL(parsed.url))
    }

    private static func parseFallbackDict(_ dict: [String: Any], msgType: Int?) -> ChatMessagePayload {
        let modules = extractModules(from: dict)
        let title = sanitizeOptionalText(firstString(in: dict, keys: ["title", "main_title", "headline"]))
        let subtitle = sanitizeOptionalText(
            firstString(in: dict, keys: ["text", "summary", "desc", "sub_title", "brief", "card_brief"])
        )
        let thumb = extractImageURL(from: dict)
        let hasCardBody = subtitle != nil || thumb != nil || extractActionURL(from: dict) != nil
        if !modules.isEmpty || (title != nil && hasCardBody) { return parseModuleCardDict(dict, msgType: msgType) }
        if title == nil, subtitle == nil, let imageURL = thumb { return .image(imageURL) }
        return .text(extractReadableText(from: dict, depth: 0) ?? fallbackLabel(for: msgType))
    }
}

// MARK: - Preview & Field Extraction

extension BiliIMMessageParser {
    private static func renderPreview(msgType: Int?, payload: ChatMessagePayload) -> String {
        switch payload {
        case .recalled: String(localized: "[Message recalled]")
        case .image: String(localized: "[Image]")
        case .sticker(_, let text): text?.isEmpty == false ? (text ?? "") : String(localized: "[Sticker]")
        case .systemNotice(let text, _): text.isEmpty ? String(localized: "[Notification]") : text
        case .card(let card): cardPreview(msgType: msgType, card: card)
        case .text(let text): text
        }
    }

    private static func cardPreview(msgType: Int?, card: ChatMessageCard) -> String {
        let summary = cardSummary(card)
        let prefix: (String, String)? = switch msgType {
        case 7, 14: (String(localized: "[Share]"), String(localized: "Shared Content"))
        case 11: (String(localized: "[Video]"), String(localized: "Video"))
        case 12: (String(localized: "[Article]"), String(localized: "Article"))
        case 13: (String(localized: "[Image]"), String(localized: "[Image]"))
        default: nil
        }
        if let (tag, skip) = prefix {
            return summary.isEmpty || summary == skip ? tag : "\(tag) \(summary)"
        }
        return summary.isEmpty ? String(localized: "[Notification Card]") : summary
    }

    private static func cardSummary(_ card: ChatMessageCard) -> String {
        let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !(title == String(localized: "Notification") && !card.modules.isEmpty) { return title }
        if let sub = card.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty { return sub }
        return card.modules.first?.summary ?? title
    }

    private static func emptyPayload(for msgType: Int?) -> ChatMessagePayload {
        switch msgType {
        case 2: .text(String(localized: "[Image]"))
        case 5: .recalled
        case 6: .text(String(localized: "[Sticker]"))
        case 18: .systemNotice(text: String(localized: "[Notification]"), url: nil)
        default: .text("")
        }
    }

    private static func emptyPreview(for msgType: Int?) -> String {
        switch msgType {
        case 7, 14: String(localized: "[Share]")
        case 11: String(localized: "[Video]")
        case 12: String(localized: "[Article]")
        case 13: String(localized: "[Image]")
        case 10, 16, 19: String(localized: "[Notification Card]")
        default: renderPreview(msgType: msgType, payload: emptyPayload(for: msgType))
        }
    }

    private static func fallbackLabel(for msgType: Int?) -> String {
        if msgType == 18 { return String(localized: "[Notification]") }
        return msgType.map(cardLikeTypes.contains) == true
            ? String(localized: "[Notification Card]") : String(localized: "[Rich Message]")
    }

    private static func extractModules(from dict: [String: Any]) -> [ChatMessageCardModule] {
        guard let rawList = dict["modules"] as? [[String: Any]] else { return [] }
        return rawList.compactMap { entry in
            let titleKey = firstString(in: entry, keys: ["title", "key", "label", "name"])
            let detailKey = firstString(in: entry, keys: ["detail", "value", "content", "text", "desc"])
            let title = SystemNotifyResult.parseContent(titleKey).text
            let detail = SystemNotifyResult.parseContent(detailKey).text
            return (!title.isEmpty || !detail.isEmpty) ? ChatMessageCardModule(title: title, detail: detail) : nil
        }
    }

    static func extractActionURL(from dict: [String: Any], includePlainURL: Bool = true) -> String? {
        let configURL = extractConfigURL(dict["jump_uri_config"]) ?? extractConfigURL(dict["jump_uri_2_config"])
        let keys = includePlainURL
            ? ["jump_uri", "jump_url", "url", "uri", "jump_uri_2", "web", "link"]
            : ["jump_uri", "jump_url", "uri", "jump_uri_2", "web", "link"]
        let directURL = firstString(in: dict, keys: keys).flatMap(normalizeURL)
        if let directURL, isHTTPURL(directURL) { return directURL }
        if let configURL, isHTTPURL(configURL) { return configURL }
        return directURL ?? configURL
    }

    private static func extractConfigURL(_ raw: Any?) -> String? {
        guard let config = raw as? [String: Any] else { return nil }
        var fallback: String?
        for key in ["all_uri", "web_uri", "ios_uri", "uri", "url"] {
            guard let url = stringValue(config[key]).flatMap(normalizeURL) else { continue }
            if isHTTPURL(url) { return url }
            if fallback == nil { fallback = url }
        }
        return fallback
    }

    private static func extractJumpText(from dict: [String: Any]) -> String? {
        if let direct = sanitizeOptionalText(firstString(in: dict, keys: ["jump_text", "jump_text_2"])) {
            return direct
        }
        for key in ["jump_uri_config", "jump_uri_2_config"] {
            if let config = dict[key] as? [String: Any],
               let text = sanitizeOptionalText(firstString(in: config, keys: ["text", "title"])) {
                return text
            }
        }
        return nil
    }

    private static func extractImageURL(
        from dict: [String: Any], extraKeys: [String] = [], includePlainURL: Bool = false
    ) -> String? {
        for key in ["thumb", "cover", "pic", "pic_url", "image_url", "img_url"] {
            if let url = stringValue(dict[key]).flatMap(normalizeURL), isHTTPURL(url) { return url }
        }
        for key in extraKeys {
            if let url = stringValue(dict[key]).flatMap(normalizeURL), isHTTPURL(url) { return url }
        }
        if includePlainURL, let url = stringValue(dict["url"]).flatMap(normalizeURL), isHTTPURL(url) {
            return url
        }
        return nil
    }

    private static func synthesizeContentURL(from dict: [String: Any], msgType: Int) -> String? {
        let base = "https://www.bilibili.com"
        if let bvid = stringValue(dict["bvid"]), bvid.hasPrefix("BV") { return "\(base)/video/\(bvid)" }
        switch msgType {
        case 11: return positiveInt(dict, ["rid", "aid", "id"]).map { "\(base)/video/av\($0)" }
        case 12: return positiveInt(dict, ["rid", "id"]).map { "\(base)/read/cv\($0)" }
        case 14: return positiveInt(dict, ["room_id", "roomid"]).map { "https://live.bilibili.com/\($0)" }
        case 7: return synthesizeShareURL(from: dict)
        default: return nil
        }
    }

    private static func synthesizeShareURL(from dict: [String: Any]) -> String? {
        guard let targetID = positiveInt(dict, ["id", "rid"]) else { return nil }
        switch intValue(dict["source"]) {
        case 5: return "https://www.bilibili.com/video/av\(targetID)"
        case 6: return "https://www.bilibili.com/read/cv\(targetID)"
        default: return nil
        }
    }

    private static func extractReadableText(from value: Any, depth: Int) -> String? {
        guard depth < 4 else { return nil }
        if let string = stringValue(value) {
            if let nested = parseJSONObject(from: string) { return extractReadableText(from: nested, depth: depth + 1) }
            return isHumanReadableFragment(string) ? string : nil
        }
        if let dict = value as? [String: Any] { return extractReadableTextFromDict(dict, depth: depth) }
        guard let array = value as? [Any] else { return nil }
        let joined = array.compactMap { extractReadableText(from: $0, depth: depth + 1) }
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func extractReadableTextFromDict(_ dict: [String: Any], depth: Int) -> String? {
        let priorityKeys = [
            "title", "headline", "main_title", "sub_title", "text", "summary", "desc",
            "content", "msg", "message", "brief", "card_brief", "source_desc", "reply_content", "detail", "body",
        ]
        for key in priorityKeys {
            if let nested = dict[key], let text = extractReadableText(from: nested, depth: depth + 1) { return text }
        }
        if let first = extractModules(from: dict).first { return first.summary }
        for (_, child) in dict where child is [String: Any] || child is [Any] {
            if let text = extractReadableText(from: child, depth: depth + 1) { return text }
        }
        return nil
    }

    private static func parseTruncatedJSON(msgType: Int?, raw: String) -> ChatMessagePayload {
        let extracted = extractFirstTruncatedField(from: raw) ?? fallbackLabel(for: msgType)
        return msgType == 18 ? .systemNotice(text: extracted, url: nil) : .text(extracted)
    }

    static func extractFirstTruncatedField(from raw: String, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        let nsRaw = raw as NSString
        let range = NSRange(location: 0, length: nsRaw.length)
        for regex in truncatedFieldRegexes {
            guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges > 1 else { continue }
            let captured = nsRaw.substring(with: match.range(at: 1))
            let decoded: String
            if captured.contains("\\"),
               let parsed = try? JSONSerialization.jsonObject(
                   with: Data("\"\(captured)\"".utf8),
                   options: .fragmentsAllowed
               ) as? String {
                decoded = parsed
            } else {
                decoded = captured
            }
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let nested = parseJSONObject(from: trimmed) {
                if let text = extractReadableText(from: nested, depth: depth + 1) { return text }
            } else if looksLikeTruncatedJSON(trimmed) {
                if let text = extractFirstTruncatedField(from: trimmed, depth: depth + 1) { return text }
            } else {
                return trimmed
            }
        }
        return nil
    }

    private static func enforcingNoRawJSON(_ payload: ChatMessagePayload, msgType: Int?) -> ChatMessagePayload {
        switch payload {
        case .text(let text):
            return text.isEmpty ? .text("") : .text(sanitizeNoRawJSON(text, msgType: msgType))
        case .systemNotice(let text, let url):
            return .systemNotice(text: sanitizeNoticeText(text), url: url)
        default:
            return payload
        }
    }

    private static func sanitizeNoticeText(_ text: String) -> String {
        let clean = sanitizeNoRawJSON(text, msgType: 18)
        return clean.isEmpty ? String(localized: "[Notification]") : clean
    }

    // MARK: - Shared Primitive Helpers

    static func parseJSONObject(from text: String) -> Any? {
        guard (text.hasPrefix("{") && text.hasSuffix("}")) || (text.hasPrefix("[") && text.hasSuffix("]")),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              object is [String: Any] || object is [Any] else { return nil }
        return object
    }

    static func normalizeURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            let upgraded = trimmed.httpsURL
            return URL(string: upgraded) != nil ? upgraded : nil
        }
        return trimmed.hasPrefix("bilibili://") && URL(string: trimmed) != nil ? trimmed : nil
    }

    static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(dict[key]) { return value }
        }
        return nil
    }

    static func extractFirstURL(in text: String) -> String? {
        guard text.contains("://"), let regex = bareURLRegex else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        var raw = nsText.substring(with: match.range)
        while let last = raw.last, ".,;:!?。，；：！？".contains(last) { raw.removeLast() }
        return normalizeURL(raw)
    }

    static func looksLikeTruncatedJSON(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[",
              let regex = truncatedJSONRegex else { return false }
        let nsText = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) != nil
    }

    private static func sanitizeNoRawJSON(_ text: String, msgType: Int?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let nested = parseJSONObject(from: trimmed) {
            return extractReadableText(from: nested, depth: 0) ?? fallbackLabel(for: msgType)
        }
        if looksLikeTruncatedJSON(trimmed) {
            return extractFirstTruncatedField(from: trimmed) ?? fallbackLabel(for: msgType)
        }
        return text
    }

    private static func sanitizeOptionalText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let nested = parseJSONObject(from: trimmed) { return extractReadableText(from: nested, depth: 0) }
        if looksLikeTruncatedJSON(trimmed) { return extractFirstTruncatedField(from: trimmed) }
        return trimmed
    }

    private static func isHumanReadableFragment(_ text: String) -> Bool {
        guard !text.isEmpty, !text.allSatisfy(\.isNumber), !looksLikeTruncatedJSON(text) else { return false }
        if text.hasPrefix("http://") || text.hasPrefix("https://")
            || text.hasPrefix("//") || text.hasPrefix("bilibili://") { return false }
        let isHexColor = text.hasPrefix("#") && (text.count == 7 || text.count == 9)
            && text.dropFirst().allSatisfy(\.isHexDigit)
        return !isHexColor
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positiveInt(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(dict[key]), value > 0 { return value }
        }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if raw is Bool { return nil }
        if let intVal = raw as? Int { return intVal }
        if let numVal = raw as? NSNumber { return numVal.intValue }
        return (raw as? String).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func isHTTPURL(_ url: String) -> Bool { url.hasPrefix("https://") || url.hasPrefix("http://") }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
