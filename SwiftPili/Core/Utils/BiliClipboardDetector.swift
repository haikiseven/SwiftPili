import Foundation

struct ClipboardSuggestionGate: Equatable, Sendable {
    private(set) var lastSeenChangeCount: Int?
    private(set) var lastHandledContent: String?

    func shouldInspect(changeCount: Int) -> Bool {
        lastSeenChangeCount != changeCount
    }

    func shouldSuggest(content: String) -> Bool {
        let key = Self.identity(content)
        guard !key.isEmpty else { return false }
        return lastHandledContent != key
    }

    mutating func noteInspected(changeCount: Int) {
        lastSeenChangeCount = changeCount
    }

    mutating func noteHandled(content: String) {
        lastHandledContent = Self.identity(content)
    }

    static func identity(_ content: String) -> String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ClipboardLinkTarget: Equatable, Sendable {
    case video
    case liveRoom
    case userSpace
    case moment
    case article
    case music
    case link

    init?(target: BiliLinkTarget) {
        switch target {
        case .video, .bangumi: self = .video
        case .liveRoom: self = .liveRoom
        case .userSpace: self = .userSpace
        case .moment: self = .moment
        case .article: self = .article
        case .music: self = .music
        case .search: return nil
        }
    }
}

enum ClipboardLinkAction: Equatable, Sendable {
    case target(BiliLinkTarget)
    case shortLink(URL)
}

struct ClipboardLinkSuggestion: Equatable, Sendable, Identifiable {
    let id: String
    let target: ClipboardLinkTarget
    let action: ClipboardLinkAction
    let sourceContent: String

    init?(target: BiliLinkTarget, sourceContent: String) {
        guard let displayTarget = ClipboardLinkTarget(target: target) else { return nil }
        self.target = displayTarget
        action = .target(target)
        self.sourceContent = sourceContent
        id = ClipboardSuggestionGate.identity(sourceContent)
    }

    init(shortLink: URL, sourceContent: String) {
        target = .link
        action = .shortLink(shortLink)
        self.sourceContent = sourceContent
        id = ClipboardSuggestionGate.identity(sourceContent)
    }
}

enum ClipboardLinkDetector {
    static let settingsKey = "clipboard_link_detection"

    static func suggestion(for content: String) -> ClipboardLinkSuggestion? {
        switch BiliLinkResolver.resolve(text: content) {
        case .resolved(let target, _):
            return ClipboardLinkSuggestion(target: target, sourceContent: content)
        case .needsRedirect(let url):
            return ClipboardLinkSuggestion(shortLink: url, sourceContent: content)
        case .none:
            return nil
        }
    }
}
