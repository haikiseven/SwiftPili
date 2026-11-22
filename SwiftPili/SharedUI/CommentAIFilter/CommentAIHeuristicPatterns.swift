import Foundation

/// Pure pattern matchers shared by `CommentAIHeuristicScorer`.
enum CommentAIHeuristicPatterns {
    static func countMatches(in text: String, phrases: [String]) -> Int {
        var hits = 0
        for phrase in phrases where text.contains(phrase) {
            hits += 1
        }
        return hits
    }

    static func containsAny(in text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    static func hasAsciiBotToken(in lower: String) -> Bool {
        let tokens = lower.split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
        for token in tokens {
            let word = String(token)
            if word == "bot" || word == "agent" || word == "ai" || word == "llm" || word == "token" {
                return true
            }
            if word.hasSuffix("bot") && word.count >= 4 {
                return true
            }
        }
        return false
    }

    static func hasRoleplayActionParenthetical(_ text: String) -> Bool {
        let segments = extractParentheticalSegments(from: text)
        guard !segments.isEmpty else { return false }
        var shortStageDirections = 0
        for segment in segments {
            if containsAny(in: segment, phrases: CommentAIHeuristicDictionaries.roleplayActionKeywords) {
                return true
            }
            if (2...12).contains(segment.count), !segment.contains("http") {
                shortStageDirections += 1
            }
        }
        return shortStageDirections >= 2
    }

    private static func extractParentheticalSegments(from text: String) -> [String] {
        var results: [String] = []
        let chars = Array(text)
        var openIndex: Int?
        var expectedClose: Character = ")"
        for (idx, char) in chars.enumerated() {
            if openIndex == nil {
                if char == "（" {
                    openIndex = idx + 1
                    expectedClose = "）"
                } else if char == "(" {
                    openIndex = idx + 1
                    expectedClose = ")"
                }
            } else if char == expectedClose, let start = openIndex {
                if idx > start {
                    let slice = String(chars[start..<idx]).trimmingCharacters(in: .whitespaces)
                    if !slice.isEmpty { results.append(slice) }
                }
                openIndex = nil
            }
        }
        return results
    }

    /// Detects `dafeiyu-cleaner`'s `ownerLink` pattern: a top-level comment mentioning `@owner`
    /// where the mentioned handle shares a 2+ char stem with the bot's own username, or mentions `@... 主人`.
    static func hasOwnerLinkMention(in text: String, authorName: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanText: String
        if trimmed.hasPrefix("回复 @") || trimmed.hasPrefix("回复@") {
            guard let colonIndex = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
                return false
            }
            scanText = String(trimmed[trimmed.index(after: colonIndex)...])
        } else {
            scanText = trimmed
        }

        guard scanText.contains("@") else { return false }
        if scanText.contains("主人") { return true }

        let authorLower = authorName.lowercased()
        let parts = scanText.split(separator: "@", omittingEmptySubsequences: true)
        for part in parts.dropFirst(scanText.hasPrefix("@") ? 0 : 1) {
            let mention = part.prefix { !$0.isWhitespace && $0 != "，" && $0 != "," && $0 != "：" && $0 != ":" }
            let mentionLower = mention.lowercased()
            if mentionLower.count >= 2, sharesStem(mentionLower, authorLower) {
                return true
            }
        }
        return false
    }

    private static func sharesStem(_ mention: String, _ author: String) -> Bool {
        if author.contains(mention) || mention.contains(author) {
            return min(mention.count, author.count) >= 2
        }
        let chars = Array(mention)
        guard chars.count >= 2 else { return false }
        return author.contains(String(chars.prefix(2)))
    }

    static func hasMarkdownArtifacts(_ text: String) -> Bool {
        if text.contains("**"), text.components(separatedBy: "**").count >= 3 {
            return true
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ")
                || trimmed.hasPrefix("- **") || trimmed.hasPrefix("* **") {
                return true
            }
        }
        return false
    }

    static func hasStructuredNumberedList(_ text: String) -> Bool {
        let pairs: [(String, String)] = [
            ("1.", "2."), ("1、", "2、"), ("①", "②"), ("一、", "二、"), ("第一", "第二")
        ]
        return pairs.contains { text.contains($0.0) && text.contains($0.1) }
    }

    static func countEmojiBullets(in text: String) -> Int {
        let scalars = CommentAIHeuristicDictionaries.bulletEmojiScalars
        return text.unicodeScalars.reduce(0) { $0 + (scalars.contains($1.value) ? 1 : 0) }
    }

    static func isSuspiciousBatchUsername(_ lower: String) -> Bool {
        if lower.hasPrefix("bili_") || lower.hasPrefix("用户"), lower.filter(\.isNumber).count >= 6 {
            return true
        }
        return lower.reversed().prefix(while: \.isNumber).count >= 5 && lower.count >= 8
    }

    static func hasTimestampReference(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 4 else { return false }
        for idx in 1..<(chars.count - 2) {
            let isColon = chars[idx] == ":" || chars[idx] == "："
            if isColon, chars[idx - 1].isNumber, chars[idx + 1].isNumber, chars[idx + 2].isNumber {
                return true
            }
        }
        return false
    }

    static func punctuationDensityScore(_ text: String) -> Int {
        text.reduce(0) { $0 + ("，。；：".contains($1) ? 1 : 0) }
    }
}
