import Foundation
import Observation

/// Coordinates two-stage on-device AI comment filtering:
/// - Stage 1: synchronous offline heuristics (`scoreAccount` + `scoreText` + `ownerLink` + user rules)
///   augmented asynchronously with `avatarBlue` (32×32 whale-blue avatar analysis).
/// - Stage 2: bounded iOS 26 `FoundationModels` borderline refinement.
@MainActor
@Observable
final class CommentAIFilterEngine {
    static let shared = CommentAIFilterEngine()

    private static let maxCacheEntries = 400
    private static let maxAvatarCacheEntries = 500

    /// Observed counter incremented whenever avatar analysis, Stage 2 refinement,
    /// or rule configuration updates land, updating visible comment rows reactively.
    private(set) var refinementVersion: Int = 0

    @ObservationIgnored private var heuristicCache: [Int: CommentAIAssessment] = [:]
    @ObservationIgnored private var heuristicOrder: [Int] = []
    @ObservationIgnored private var refinedCache: [Int: CommentAIAssessment] = [:]
    @ObservationIgnored private var refinedOrder: [Int] = []
    @ObservationIgnored private var avatarCache: [String: CommentAIAvatarBlueResult] = [:]
    @ObservationIgnored private var avatarOrder: [String] = []
    @ObservationIgnored private var inFlightTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var inFlightAvatarTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastAppliedRules: CommentAIFilterRuleSet

    private let settings = ExperimentalSettingsStore.shared

    private init() {
        lastAppliedRules = settings.commentAIFilter.rules
        settings.addObserver(owner: self) { engine, changes in
            guard changes.contains(.aiCommentFilter) else { return }
            if !engine.isEnabled {
                engine.cancelAllRefinements()
                return
            }
            if !engine.config.foundationModelsRefinerEnabled {
                engine.cancelAllRefinements()
            }
            if engine.config.rules != engine.lastAppliedRules {
                engine.lastAppliedRules = engine.config.rules
                engine.invalidateScoreCaches()
            }
        }
    }

    var isEnabled: Bool {
        settings.isAllowed(.aiCommentFilter)
    }

    var config: CommentAIFilterConfiguration {
        settings.commentAIFilter
    }

    func isAllowedAuthor(mid: Int) -> Bool {
        config.allowedAuthorMIDs.contains(mid)
    }

    /// Synchronous assessment lookup: returns cached Stage 2 refined verdict if available,
    /// otherwise computes and caches the fast Stage 1 offline heuristic score (including cached avatarBlue).
    func assessment(
        for comment: CommentResult.CommentItem,
        upMid: Int?
    ) -> CommentAIAssessment? {
        guard isEnabled, !isAllowedAuthor(mid: comment.mid) else { return nil }
        _ = refinementVersion
        if let refined = refinedCache[comment.rpid] {
            return refined
        }
        if let cached = heuristicCache[comment.rpid] {
            return cached
        }
        let avatarKey = CommentAIAvatarAnalyzer.normalizedCacheKey(for: comment.member.avatar)
        let avatarBlue = config.rules.avatarBlueEnabled ? avatarCache[avatarKey] : nil
        let scored = CommentAIHeuristicScorer.score(
            comment: comment,
            upMid: upMid,
            currentUserMid: AuthManager.shared.dedeUserID,
            rules: config.rules,
            avatarBlue: avatarBlue
        )
        storeHeuristic(scored, for: comment.rpid)
        return scored
    }

    /// Whether a comment should be omitted from visible feed rows in `.hideCompletely` mode.
    func shouldHide(_ comment: CommentResult.CommentItem, upMid: Int?) -> Bool {
        guard isEnabled, config.mode == .hideCompletely else { return false }
        guard let result = assessment(for: comment, upMid: upMid) else { return false }
        return result.matches(config)
    }

    /// Returns comments visible in the current filter mode without mutating source arrays
    /// or breaking pagination cursors.
    func visibleComments(
        from comments: [CommentResult.CommentItem],
        upMid: Int?
    ) -> [CommentResult.CommentItem] {
        guard isEnabled, config.mode == .hideCompletely else { return comments }
        return comments.filter { !shouldHide($0, upMid: upMid) }
    }

    /// Enqueues async `avatarBlue` palette check (when enabled) and bounded Stage 2
    /// `FoundationModels` refinement when Stage 1 produces a borderline score (30–69).
    func requestRefinementIfNeeded(
        for comment: CommentResult.CommentItem,
        upMid: Int?
    ) {
        guard isEnabled, !isAllowedAuthor(mid: comment.mid) else { return }

        if config.rules.avatarBlueEnabled {
            requestAvatarAnalysisIfNeeded(for: comment, upMid: upMid)
        }
        enqueueFoundationRefinementIfNeeded(for: comment, upMid: upMid)
    }

    /// Cancels any in-flight Stage 2 refinement for a comment leaving the viewport.
    func cancelRefinement(for rpid: Int) {
        inFlightTasks.removeValue(forKey: rpid)?.cancel()
    }

    func cancelAllRefinements() {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        for task in inFlightAvatarTasks.values {
            task.cancel()
        }
        inFlightAvatarTasks.removeAll()
    }

    @discardableResult
    func allowAuthor(mid: Int, name: String) -> Bool {
        settings.allowCommentAIFilterAuthor(mid: mid, name: name)
    }

    // MARK: - Async Pipeline

    private func requestAvatarAnalysisIfNeeded(
        for comment: CommentResult.CommentItem,
        upMid: Int?
    ) {
        let avatarURL = comment.member.avatar
        let key = CommentAIAvatarAnalyzer.normalizedCacheKey(for: avatarURL)
        guard !key.isEmpty, avatarCache[key] == nil, inFlightAvatarTasks[key] == nil else { return }

        let rpid = comment.rpid
        let authorMid = comment.mid
        let task = Task { @MainActor [weak self] in
            let analysis = await CommentAIAvatarAnalyzer.analyze(urlString: avatarURL)
            guard let self else { return }
            self.inFlightAvatarTasks.removeValue(forKey: key)
            guard !Task.isCancelled, self.isEnabled, self.config.rules.avatarBlueEnabled,
                  let analysis else { return }
            self.storeAvatar(analysis, for: key)
            if analysis.tier != .none {
                self.heuristicCache.removeValue(forKey: rpid)
                self.refinedCache.removeValue(forKey: rpid)
                self.refinementVersion &+= 1
                if !self.isAllowedAuthor(mid: authorMid) {
                    self.enqueueFoundationRefinementIfNeeded(for: comment, upMid: upMid)
                }
            }
        }
        inFlightAvatarTasks[key] = task
    }

    private func enqueueFoundationRefinementIfNeeded(
        for comment: CommentResult.CommentItem,
        upMid: Int?
    ) {
        guard isEnabled,
              config.foundationModelsRefinerEnabled,
              !isAllowedAuthor(mid: comment.mid),
              CommentAIFilterAvailability.current.isAvailable else { return }
        guard refinedCache[comment.rpid] == nil, inFlightTasks[comment.rpid] == nil else { return }
        guard let stage1 = assessment(for: comment, upMid: upMid), stage1.isBorderline else { return }

        let input = CommentAIRefinementInput(
            rpid: comment.rpid,
            authorName: comment.member.uname,
            authorLevel: comment.member.levelInfo?.currentLevel,
            authorSign: comment.member.sign,
            message: comment.content.displayMessage,
            stage1: stage1
        )
        let rpid = comment.rpid
        let authorMid = comment.mid

        let task = Task { @MainActor [weak self] in
            let refined = await CommentAIFoundationRefiner.refine(input)
            guard let self else { return }
            self.inFlightTasks.removeValue(forKey: rpid)
            guard !Task.isCancelled,
                  self.isEnabled,
                  self.config.foundationModelsRefinerEnabled,
                  !self.isAllowedAuthor(mid: authorMid),
                  let refined else { return }
            self.storeRefined(refined, for: rpid)
            self.refinementVersion &+= 1
        }
        inFlightTasks[rpid] = task
    }

    private func invalidateScoreCaches() {
        cancelAllRefinements()
        heuristicCache.removeAll()
        heuristicOrder.removeAll()
        refinedCache.removeAll()
        refinedOrder.removeAll()
        refinementVersion &+= 1
    }

    // MARK: - Bounded Cache Helpers

    private func storeHeuristic(_ assessment: CommentAIAssessment, for rpid: Int) {
        if heuristicCache[rpid] == nil {
            heuristicOrder.append(rpid)
            if heuristicOrder.count > Self.maxCacheEntries {
                let evicted = heuristicOrder.removeFirst()
                heuristicCache.removeValue(forKey: evicted)
            }
        }
        heuristicCache[rpid] = assessment
    }

    private func storeRefined(_ assessment: CommentAIAssessment, for rpid: Int) {
        if refinedCache[rpid] == nil {
            refinedOrder.append(rpid)
            if refinedOrder.count > Self.maxCacheEntries {
                let evicted = refinedOrder.removeFirst()
                refinedCache.removeValue(forKey: evicted)
            }
        }
        refinedCache[rpid] = assessment
    }

    private func storeAvatar(_ result: CommentAIAvatarBlueResult, for key: String) {
        if avatarCache[key] == nil {
            avatarOrder.append(key)
            if avatarOrder.count > Self.maxAvatarCacheEntries {
                let evicted = avatarOrder.removeFirst()
                avatarCache.removeValue(forKey: evicted)
            }
        }
        avatarCache[key] = result
    }
}
