import Foundation

/// Stage 1 synchronous, 100% offline heuristic scorer aligned with `liyupi/dafeiyu-cleaner`:
/// combines `scoreAccount` (dafeiyu/AI-agent username, bio, `avatarBlue`, level, decoration),
/// user custom rules, and `scoreText` & `ownerLink`.
enum CommentAIHeuristicScorer {
    private struct Signals {
        var score: Int = 0
        var reasons: [String] = []
        var hasTextSignal: Bool = false
        var hasStrongAccountSignal: Bool = false

        mutating func add(
            _ points: Int,
            reason: String? = nil,
            isText: Bool = false,
            isStrongAccount: Bool = false
        ) {
            score += points
            if isText { hasTextSignal = true }
            if isStrongAccount { hasStrongAccountSignal = true }
            if let reason, !reasons.contains(reason) {
                reasons.append(reason)
            }
        }
    }

    static func score(
        comment: CommentResult.CommentItem,
        upMid: Int?,
        currentUserMid: String?,
        rules: CommentAIFilterRuleSet = .default,
        avatarBlue: CommentAIAvatarBlueResult? = nil
    ) -> CommentAIAssessment {
        if let upMid, comment.mid == upMid {
            return CommentAIAssessment(score: 0, reasons: [], stage: .heuristic)
        }
        if let currentUserMid, currentUserMid == String(comment.mid) {
            return CommentAIAssessment(score: 0, reasons: [], stage: .heuristic)
        }

        let rawText = comment.content.displayMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let charCount = rawText.count

        var signals = Signals()
        scoreCustomRules(comment: comment, rawText: rawText, rules: rules, into: &signals)
        scoreAccountProfile(
            comment: comment,
            charCount: charCount,
            rules: rules,
            avatarBlue: avatarBlue,
            into: &signals
        )
        if charCount > 0 {
            if rules.textPersonaEnabled {
                scoreTextPatterns(rawText, charCount: charCount, authorName: comment.member.uname, into: &signals)
            }
            applyHumanCounterSignals(comment: comment, text: rawText, charCount: charCount, into: &signals)
        }

        if !signals.hasStrongAccountSignal, !signals.hasTextSignal {
            if charCount < 12 {
                signals.score = min(signals.score, 15)
            } else if charCount < 24 {
                signals.score = min(signals.score, 20)
            }
        }

        return CommentAIAssessment(
            score: max(0, min(100, signals.score)),
            reasons: Array(signals.reasons.prefix(4)),
            stage: .heuristic
        )
    }

    // MARK: - User Custom Rules

    private static func scoreCustomRules(
        comment: CommentResult.CommentItem,
        rawText: String,
        rules: CommentAIFilterRuleSet,
        into signals: inout Signals
    ) {
        let accountKeywords = normalizedKeywords(rules.customAccountKeywords)
        if !accountKeywords.isEmpty {
            let unameLower = comment.member.uname.lowercased()
            let signLower = (comment.member.sign ?? "").lowercased()
            if let hit = accountKeywords.first(where: { unameLower.contains($0) || signLower.contains($0) }) {
                signals.add(
                    75,
                    reason: String(localized: "Matches custom account keyword: \(hit)"),
                    isStrongAccount: true
                )
            }
        }

        let contentKeywords = normalizedKeywords(rules.customContentKeywords)
        if !contentKeywords.isEmpty, !rawText.isEmpty {
            let textLower = rawText.lowercased()
            if let hit = contentKeywords.first(where: { textLower.contains($0) }) {
                signals.add(
                    75,
                    reason: String(localized: "Matches custom comment keyword: \(hit)"),
                    isText: true
                )
            }
        }
    }

    private static func normalizedKeywords(_ keywords: [String]) -> [String] {
        keywords.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: - Account Heuristics (`scoreAccount` + `avatarBlue`)

    private static func scoreAccountProfile(
        comment: CommentResult.CommentItem,
        charCount: Int,
        rules: CommentAIFilterRuleSet,
        avatarBlue: CommentAIAvatarBlueResult?,
        into signals: inout Signals
    ) {
        let member = comment.member
        let unameLower = member.uname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let signLower = (member.sign ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let level = member.levelInfo?.currentLevel

        if rules.accountIdentityEnabled {
            scoreUsername(unameLower, into: &signals)
            scoreBio(signLower, level: level, charCount: charCount, into: &signals)
        }
        if rules.avatarBlueEnabled, let avatarBlue {
            scoreAvatarBlue(avatarBlue, into: &signals)
        }
        scoreLevelAndStatus(
            member: member,
            charCount: charCount,
            rules: rules,
            avatarBlue: avatarBlue,
            into: &signals
        )
    }

    private static func scoreAvatarBlue(
        _ avatarBlue: CommentAIAvatarBlueResult,
        into signals: inout Signals
    ) {
        let pct = Int((avatarBlue.totalBlueRatio * 100).rounded())
        switch avatarBlue.tier {
        case .strong:
            signals.add(
                38,
                reason: String(localized: "Avatar matches DeepSeek whale-blue palette (\(pct)%)"),
                isStrongAccount: true
            )
        case .moderate:
            signals.add(
                24,
                reason: String(localized: "Avatar has prominent whale-blue tone (\(pct)%)")
            )
        case .none:
            break
        }
    }

    private static func scoreLevelAndStatus(
        member: CommentResult.CommentItem.CommentMember,
        charCount: Int,
        rules: CommentAIFilterRuleSet,
        avatarBlue: CommentAIAvatarBlueResult?,
        into signals: inout Signals
    ) {
        let level = member.levelInfo?.currentLevel
        let isActiveVip = member.vip?.vipStatus == 1
        let hasDecoration = member.userSailing?.cardbg != nil

        if rules.lowLevelBoostEnabled, let level, level <= 2 {
            if signals.hasStrongAccountSignal {
                let points = avatarBlue?.tier == .strong ? 16 : 12
                signals.add(points, reason: String(localized: "Low-level account matching AI bot traits"))
                if !isActiveVip, !hasDecoration { signals.add(8) }
            } else if charCount >= 70 {
                let points = level <= 1 ? 18 : 12
                signals.add(points, reason: String(localized: "Low-level account posting long structured text"))
            } else if !isActiveVip, !hasDecoration, charCount >= 110, signals.hasTextSignal {
                signals.add(6)
            }
        }

        if let verifyType = member.officialVerify?.type, verifyType == 0 || verifyType == 1,
           !signals.hasStrongAccountSignal {
            signals.add(-24)
        } else if let level, level >= 5, member.vip?.vipType == 2, isActiveVip,
                  !signals.hasStrongAccountSignal {
            signals.add(-8)
        }
    }

    private static func scoreUsername(_ unameLower: String, into signals: inout Signals) {
        guard !unameLower.isEmpty else { return }

        if CommentAIHeuristicPatterns.containsAny(
            in: unameLower, phrases: CommentAIHeuristicDictionaries.strongDafeiyuUsernameKeywords
        ) {
            signals.add(65, reason: String(localized: "Username matches AI bot or Dafeiyu pattern"), isStrongAccount: true)
            return
        }

        if CommentAIHeuristicPatterns.containsAny(
            in: unameLower, phrases: CommentAIHeuristicDictionaries.mediumDafeiyuUsernameKeywords
        ) || CommentAIHeuristicPatterns.hasAsciiBotToken(in: unameLower) {
            signals.add(42, reason: String(localized: "Username contains AI persona or bot markers"), isStrongAccount: true)
            return
        }

        if CommentAIHeuristicPatterns.containsAny(
            in: unameLower, phrases: CommentAIHeuristicDictionaries.weakWhaleUsernameKeywords
        ) {
            signals.add(24, reason: String(localized: "Username contains whale/fish persona cue"))
        }

        if CommentAIHeuristicPatterns.isSuspiciousBatchUsername(unameLower) {
            signals.add(16, reason: String(localized: "Default or batch-style bot username"))
        }
    }

    private static func scoreBio(
        _ signLower: String,
        level: Int?,
        charCount: Int,
        into signals: inout Signals
    ) {
        if !signLower.isEmpty {
            if CommentAIHeuristicPatterns.containsAny(
                in: signLower, phrases: CommentAIHeuristicDictionaries.strongAISignKeywords
            ) {
                signals.add(
                    60,
                    reason: String(localized: "Account bio discloses AI bot or automated agent"),
                    isStrongAccount: true
                )
            } else if CommentAIHeuristicPatterns.containsAny(
                in: signLower, phrases: CommentAIHeuristicDictionaries.secondaryAISignKeywords
            ) {
                signals.add(
                    32,
                    reason: String(localized: "Account bio contains AI persona or token cues"),
                    isStrongAccount: true
                )
            } else if CommentAIHeuristicPatterns.containsAny(
                in: signLower, phrases: CommentAIHeuristicDictionaries.promoSignKeywords
            ) {
                signals.add(18, reason: String(localized: "Account bio contains promotional or bot keywords"))
            }
        } else if let level, level <= 2, charCount >= 90, signals.hasTextSignal {
            signals.add(8, reason: String(localized: "Low-level account with empty bio posting long essay"))
        }
    }

    // MARK: - Text Heuristics (`scoreText` + `ownerLink`)

    private static func scoreTextPatterns(
        _ text: String,
        charCount: Int,
        authorName: String,
        into signals: inout Signals
    ) {
        let lower = text.lowercased()
        if CommentAIHeuristicPatterns.containsAny(
            in: lower, phrases: CommentAIHeuristicDictionaries.aiPersonaSelfReferences
        ) {
            signals.add(36, reason: String(localized: "Uses AI bot or whale persona self-reference"), isText: true)
        }
        if CommentAIHeuristicPatterns.hasRoleplayActionParenthetical(text) {
            signals.add(30, reason: String(localized: "Contains roleplay action stage directions"), isText: true)
        }
        if CommentAIHeuristicPatterns.hasOwnerLinkMention(in: text, authorName: authorName) {
            signals.add(32, reason: String(localized: "Mentions linked owner account in top-level comment"), isText: true)
        }

        let transitionHits = CommentAIHeuristicPatterns.countMatches(
            in: text, phrases: CommentAIHeuristicDictionaries.llmTransitionPhrases
        )
        if transitionHits >= 1 {
            signals.add(
                min(32, 10 + (transitionHits - 1) * 8),
                reason: String(localized: "Contains typical AI transition or summary phrasing"),
                isText: true
            )
        }

        let recapHits = CommentAIHeuristicPatterns.countMatches(
            in: text, phrases: CommentAIHeuristicDictionaries.mechanicalRecapPhrases
        )
        if recapHits >= 2 {
            signals.add(
                recapHits >= 3 ? 26 : 16,
                reason: String(localized: "Uses repetitive generic praise or recap templates"),
                isText: true
            )
        } else if recapHits == 1, charCount >= 70 {
            signals.add(8, isText: true)
        }

        if CommentAIHeuristicPatterns.hasMarkdownArtifacts(text) {
            signals.add(20, reason: String(localized: "Contains raw Markdown formatting artifacts"), isText: true)
        }
        if CommentAIHeuristicPatterns.hasStructuredNumberedList(text) {
            signals.add(18, reason: String(localized: "Rigid multi-point numbered list layout"), isText: true)
        }
        if CommentAIHeuristicPatterns.countEmojiBullets(in: text) >= 2 {
            signals.add(16, reason: String(localized: "Uses AI-style emoji bullet markers"), isText: true)
        }
        if CommentAIHeuristicPatterns.countMatches(
            in: text, phrases: CommentAIHeuristicDictionaries.parallelRhetoricPhrases
        ) >= 2 {
            signals.add(12, reason: String(localized: "High density of parallel essay clauses"), isText: true)
        }
    }

    // MARK: - Counter-Signals

    private static func applyHumanCounterSignals(
        comment: CommentResult.CommentItem,
        text: String,
        charCount: Int,
        into signals: inout Signals
    ) {
        let hasEmotes = !comment.content.emoteURLs.isEmpty
        let hasPictures = !(comment.content.pictures ?? []).isEmpty

        if !signals.hasStrongAccountSignal {
            if hasEmotes { signals.add(-8) }
            if hasPictures { signals.add(-10) }
            if CommentAIHeuristicPatterns.hasTimestampReference(text) { signals.add(-12) }
            if CommentAIHeuristicPatterns.containsAny(
                in: text, phrases: CommentAIHeuristicDictionaries.nativeSlangMarkers
            ) {
                signals.add(-8)
            }
        }

        if charCount >= 110, !hasEmotes, !hasPictures, signals.hasTextSignal,
           CommentAIHeuristicPatterns.punctuationDensityScore(text) >= 4 {
            signals.add(10, reason: String(localized: "Long formal prose with no community interaction cues"))
        }
    }
}
