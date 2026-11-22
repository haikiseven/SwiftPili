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

struct ClipboardLinkSuggestion: Equatable, Sendable, Identifiable {
    let id: String
    let target: BiliLinkTarget
    let sourceContent: String

    init(target: BiliLinkTarget, sourceContent: String) {
        self.target = target
        self.sourceContent = sourceContent
        id = ClipboardSuggestionGate.identity(sourceContent)
    }
}

enum ClipboardLinkDetector {
    static let settingsKey = "clipboard_link_detection"

    static func suggestion(for content: String) -> ClipboardLinkSuggestion? {
        guard case .resolved(let target, _) = BiliLinkResolver.resolve(text: content) else {
            return nil
        }
        return ClipboardLinkSuggestion(target: target, sourceContent: content)
    }
}
