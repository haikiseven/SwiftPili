import Foundation

/// Deduplicates clipboard link suggestions using `UIPasteboard.changeCount` to gate
/// privacy-visible reads and trimmed content identity to avoid re-prompting dismissed text.
struct ClipboardSuggestionGate: Equatable, Sendable {
    /// Last pasteboard generation inspected.
    private(set) var lastSeenChangeCount: Int?
    /// Identity of the last content surfaced or dismissed.
    private(set) var lastHandledContent: String?

    /// Whether the pasteboard generation changed and warrants reading its string.
    func shouldInspect(changeCount: Int) -> Bool {
        lastSeenChangeCount != changeCount
    }

    /// Whether this content should be surfaced, having been read.
    func shouldSuggest(content: String) -> Bool {
        let key = Self.identity(content)
        guard !key.isEmpty else { return false }
        return lastHandledContent != key
    }

    mutating func noteInspected(changeCount: Int) {
        lastSeenChangeCount = changeCount
    }

    /// Called for BOTH acceptance and dismissal: either way the user has
    /// answered for this content and must not be asked again.
    mutating func noteHandled(content: String) {
        lastHandledContent = Self.identity(content)
    }

    /// Whitespace-insensitive identity, so a re-copy that differs only in a
    /// trailing newline is the same suggestion.
    static func identity(_ content: String) -> String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A detected clipboard link awaiting the user's decision.
///
/// Held rather than acted on: the requirement is a non-disruptive affordance,
/// not navigation the user did not ask for.
struct ClipboardLinkSuggestion: Equatable, Sendable, Identifiable {
    let id: String
    let target: BiliLinkTarget
    /// The clipboard text that produced it, for the dedup gate.
    let sourceContent: String

    init(target: BiliLinkTarget, sourceContent: String) {
        self.target = target
        self.sourceContent = sourceContent
        id = ClipboardSuggestionGate.identity(sourceContent)
    }
}

/// Turns clipboard text into a suggestion, or nothing.
///
/// Only the locally-resolvable cases produce a suggestion. A `.needsRedirect`
/// short link is deliberately NOT followed here: firing a network request at
/// whatever happens to be on the clipboard, unprompted, is exactly the kind of
/// thing a conservative default exists to avoid. The user can still paste it
/// into a place that does resolve it.
enum ClipboardLinkDetector {
    static let settingsKey = "clipboard_link_detection"

    static func suggestion(for content: String) -> ClipboardLinkSuggestion? {
        guard case .resolved(let target, _) = BiliLinkResolver.resolve(text: content) else {
            return nil
        }
        return ClipboardLinkSuggestion(target: target, sourceContent: content)
    }
}
