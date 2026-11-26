import Foundation
import NaturalLanguage
import Observation
#if canImport(Translation)
import Translation
#endif

// MARK: - Translation Session Identity & Status

struct SubtitleTranslationSessionKey: Equatable, Sendable {
    let sourceIdentifier: String?
    let targetIdentifier: String
    let revision: UInt64
}

enum SubtitleTranslationStatus: Equatable, Sendable {
    case idle
    case waitingForPrimaryTrack
    case preparing
    case translating(completed: Int, total: Int)
    case ready(translatedCount: Int, totalCount: Int)
    case liveActive
    case sameLanguage
    case unsupportedPair
    case failed(String)
}

// MARK: - Language Resolution Helpers

enum SubtitleSourceLanguageResolver {
    /// Maps a Bilibili subtitle `lan` identifier (including `ai-*` tracks) to a canonical BCP-47 identifier.
    static func sourceIdentifier(forBilibiliLan rawLan: String?) -> String? {
        guard let rawLan else { return nil }
        var normalized = rawLan
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        if normalized.hasPrefix("ai-") {
            normalized.removeFirst(3)
        }
        if normalized == "zh" || normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-hans")
            || normalized.hasPrefix("zh-sg") {
            return "zh-Hans"
        }
        if normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk")
            || normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-mo") {
            return "zh-Hant"
        }
        if normalized.hasPrefix("en") {
            return "en"
        }
        if normalized.hasPrefix("ja") || normalized == "jp" {
            return "ja"
        }
        if normalized.hasPrefix("ko") || normalized == "kr" {
            return "ko"
        }
        if normalized.hasPrefix("fr") {
            return "fr"
        }
        if normalized.hasPrefix("de") {
            return "de"
        }
        if normalized.hasPrefix("es") {
            return "es"
        }
        if normalized.hasPrefix("ru") {
            return "ru"
        }
        if normalized.hasPrefix("pt") {
            return "pt"
        }
        if normalized.hasPrefix("it") {
            return "it"
        }
        if normalized.hasPrefix("ar") {
            return "ar"
        }
        if normalized.hasPrefix("th") {
            return "th"
        }
        if normalized.hasPrefix("vi") {
            return "vi"
        }
        if normalized.hasPrefix("id") {
            return "id"
        }
        return nil
    }

    static func sourceIdentifier(for speechLocale: SpeechSubtitleLocale) -> String? {
        switch speechLocale {
        case .auto:
            nil
        case .chineseSimplified:
            "zh-Hans"
        case .english:
            "en"
        case .japanese:
            "ja"
        case .cantonese:
            "zh-Hant"
        }
    }

    /// Infers a dominant source language identifier offline from sample cue texts when no track code is known.
    static func inferSourceIdentifier(from cues: [PlayerViewModel.SubtitleCue]) -> String? {
        var sampleLines: [String] = []
        sampleLines.reserveCapacity(14)
        for cue in cues {
            let trimmed = cue.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SubtitleTranslationBatchPlanner.isTranslatable(trimmed) else { continue }
            sampleLines.append(trimmed)
            if sampleLines.count >= 14 { break }
        }
        guard !sampleLines.isEmpty else { return nil }
        let sample = sampleLines.joined(separator: "\n")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        guard let best = hypotheses.max(by: { $0.value < $1.value }),
              best.value >= 0.55,
              best.key != .undetermined else {
            return nil
        }
        switch best.key {
        case .simplifiedChinese:
            return "zh-Hans"
        case .traditionalChinese:
            return "zh-Hant"
        case .english:
            return "en"
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .spanish:
            return "es"
        case .russian:
            return "ru"
        case .portuguese:
            return "pt"
        case .italian:
            return "it"
        case .arabic:
            return "ar"
        case .thai:
            return "th"
        case .vietnamese:
            return "vi"
        case .indonesian:
            return "id"
        default:
            return best.key.rawValue
        }
    }

    static func isEquivalentLanguage(
        sourceIdentifier: String?,
        target: SubtitleTranslationTargetLanguage
    ) -> Bool {
        guard let sourceIdentifier, !sourceIdentifier.isEmpty else { return false }
        let normalized = sourceIdentifier.lowercased()
        switch target {
        case .chineseSimplified:
            return normalized == "zh-hans" || normalized == "zh-cn" || normalized == "zh"
        case .english:
            return normalized == "en" || normalized.hasPrefix("en-")
        case .japanese:
            return normalized == "ja" || normalized.hasPrefix("ja-")
        }
    }
}

// MARK: - Bounded LRU Translation Cache

/// Bounded least-recently-used cache keyed by `(targetLanguageID, normalizedSourceText)`.
struct SubtitleTranslationCache: Sendable {
    struct Key: Hashable, Sendable {
        let targetLanguageID: String
        let sourceText: String
    }

    private struct Entry: Sendable {
        var translatedText: String
        var lastAccessTick: UInt64
    }

    let capacity: Int
    private var storage: [Key: Entry] = [:]
    private var tick: UInt64 = 0

    init(capacity: Int = 4_096) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-mutating lookup suitable for fast per-tick subtitle rendering.
    func peek(for sourceText: String, targetLanguageID: String) -> String? {
        let normalized = Self.normalize(sourceText)
        guard !normalized.isEmpty else { return nil }
        return storage[Key(targetLanguageID: targetLanguageID, sourceText: normalized)]?.translatedText
    }

    /// Mutating lookup that refreshes recency for LRU ordering.
    mutating func value(for sourceText: String, targetLanguageID: String) -> String? {
        let normalized = Self.normalize(sourceText)
        guard !normalized.isEmpty else { return nil }
        let key = Key(targetLanguageID: targetLanguageID, sourceText: normalized)
        guard var entry = storage[key] else { return nil }
        tick &+= 1
        entry.lastAccessTick = tick
        storage[key] = entry
        return entry.translatedText
    }

    mutating func set(_ translatedText: String, for sourceText: String, targetLanguageID: String) {
        let normalizedSource = Self.normalize(sourceText)
        let normalizedTarget = Self.normalize(translatedText)
        guard !normalizedSource.isEmpty, !normalizedTarget.isEmpty else { return }
        let key = Key(targetLanguageID: targetLanguageID, sourceText: normalizedSource)
        tick &+= 1
        storage[key] = Entry(translatedText: normalizedTarget, lastAccessTick: tick)
        if storage.count > capacity {
            evictLeastRecentlyUsed()
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        tick = 0
    }

    private mutating func evictLeastRecentlyUsed() {
        while storage.count > capacity {
            guard let oldestKey = storage.min(by: { $0.value.lastAccessTick < $1.value.lastAccessTick })?.key else {
                break
            }
            storage.removeValue(forKey: oldestKey)
        }
    }
}

// MARK: - Window-Prioritized Cue Translation Batch Planner

/// Pure, testable scheduler that prioritizes cues around the active playback timestamp first,
/// then streams remaining cues forward and wraps around to earlier cues.
enum SubtitleTranslationBatchPlanner {
    static let defaultWindowLeadSeconds: TimeInterval = 5.0
    static let defaultWindowTrailSeconds: TimeInterval = 60.0
    static let defaultPriorityBatchSize = 20
    static let defaultBackgroundBatchSize = 30

    static func isTranslatable(_ text: String) -> Bool {
        let normalized = SubtitleTranslationCache.normalize(text)
        guard !normalized.isEmpty else { return false }
        return normalized.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// Counts unique translatable normalized source strings across all cues.
    static func uniqueTranslatableTexts(in cues: [PlayerViewModel.SubtitleCue]) -> Set<String> {
        var result = Set<String>()
        result.reserveCapacity(cues.count)
        for cue in cues {
            let normalized = SubtitleTranslationCache.normalize(cue.content)
            if isTranslatable(normalized) {
                result.insert(normalized)
            }
        }
        return result
    }

    /// Returns the next batch of unique normalized cue texts to translate.
    /// Cues overlapping `[focusTime - windowLeadSeconds, focusTime + windowTrailSeconds]`
    /// are returned first (active cue first, then upcoming, then recent), followed by
    /// forward-streaming background batches wrapping around to the start of the video.
    static func nextBatch(
        cues: [PlayerViewModel.SubtitleCue],
        focusTime: TimeInterval,
        alreadyHandled: (String) -> Bool,
        windowLeadSeconds: TimeInterval = defaultWindowLeadSeconds,
        windowTrailSeconds: TimeInterval = defaultWindowTrailSeconds,
        priorityBatchSize: Int = defaultPriorityBatchSize,
        backgroundBatchSize: Int = defaultBackgroundBatchSize
    ) -> [String] {
        guard !cues.isEmpty else { return [] }
        let safeFocus = focusTime.isFinite ? max(0, focusTime) : 0
        let windowStart = max(0, safeFocus - max(0, windowLeadSeconds))
        let windowEnd = safeFocus + max(0, windowTrailSeconds)

        var activeNow: [(index: Int, text: String)] = []
        var upcomingInWindow: [(from: TimeInterval, index: Int, text: String)] = []
        var recentInWindow: [(to: TimeInterval, index: Int, text: String)] = []

        for (index, cue) in cues.enumerated() {
            guard cue.from.isFinite, cue.to.isFinite else { continue }
            guard cue.to >= windowStart && cue.from <= windowEnd else { continue }
            let normalized = SubtitleTranslationCache.normalize(cue.content)
            guard isTranslatable(normalized), !alreadyHandled(normalized) else { continue }

            if cue.from <= safeFocus && cue.to >= safeFocus {
                activeNow.append((index, normalized))
            } else if cue.from > safeFocus {
                upcomingInWindow.append((cue.from, index, normalized))
            } else {
                recentInWindow.append((cue.to, index, normalized))
            }
        }

        if !activeNow.isEmpty || !upcomingInWindow.isEmpty || !recentInWindow.isEmpty {
            upcomingInWindow.sort {
                if $0.from != $1.from { return $0.from < $1.from }
                return $0.index < $1.index
            }
            recentInWindow.sort {
                if $0.to != $1.to { return $0.to > $1.to }
                return $0.index > $1.index
            }

            let limit = max(1, priorityBatchSize)
            var batch: [String] = []
            batch.reserveCapacity(limit)
            var seen = Set<String>()

            func appendUnique(_ text: String) -> Bool {
                guard seen.insert(text).inserted else { return false }
                batch.append(text)
                return batch.count >= limit
            }

            for item in activeNow where appendUnique(item.text) { return batch }
            for item in upcomingInWindow where appendUnique(item.text) { return batch }
            for item in recentInWindow where appendUnique(item.text) { return batch }
            if !batch.isEmpty { return batch }
        }

        // Priority window is complete; stream forward after windowEnd, then wrap around before windowStart.
        var afterWindow: [(from: TimeInterval, index: Int, text: String)] = []
        var beforeWindow: [(from: TimeInterval, index: Int, text: String)] = []

        for (index, cue) in cues.enumerated() {
            guard cue.from.isFinite, cue.to.isFinite else { continue }
            let normalized = SubtitleTranslationCache.normalize(cue.content)
            guard isTranslatable(normalized), !alreadyHandled(normalized) else { continue }
            if cue.from > windowEnd {
                afterWindow.append((cue.from, index, normalized))
            } else if cue.to < windowStart {
                beforeWindow.append((cue.from, index, normalized))
            }
        }

        afterWindow.sort {
            if $0.from != $1.from { return $0.from < $1.from }
            return $0.index < $1.index
        }
        beforeWindow.sort {
            if $0.from != $1.from { return $0.from < $1.from }
            return $0.index < $1.index
        }

        let bgLimit = max(1, backgroundBatchSize)
        var backgroundBatch: [String] = []
        backgroundBatch.reserveCapacity(bgLimit)
        var seen = Set<String>()

        for item in afterWindow {
            if seen.insert(item.text).inserted {
                backgroundBatch.append(item.text)
                if backgroundBatch.count >= bgLimit { return backgroundBatch }
            }
        }
        for item in beforeWindow {
            if seen.insert(item.text).inserted {
                backgroundBatch.append(item.text)
                if backgroundBatch.count >= bgLimit { return backgroundBatch }
            }
        }
        return backgroundBatch
    }
}

// MARK: - MainActor Translation Coordinator & Session Runner

@MainActor
@Observable
final class SystemSubtitleTranslationService {
    private struct HostRegistration: Equatable {
        let id: UUID
        let priority: Int
    }

    private enum WorkMode {
        case none
        case cues(trackID: String, cues: [PlayerViewModel.SubtitleCue], uniqueTotal: Int)
        case liveSpeech
    }

    enum NextTranslationWork: Sendable {
        case cueBatch(targetID: String, texts: [String])
        case liveText(targetID: String, text: String)
        case wait(epoch: UInt64)
        case stop
    }

    private(set) var status: SubtitleTranslationStatus = .idle
    private(set) var sessionKey: SubtitleTranslationSessionKey?
    private(set) var activeHostID: UUID?

    @ObservationIgnored var onTranslationsUpdated: (@MainActor () -> Void)?

    @ObservationIgnored private var hostRegistrations: [HostRegistration] = []
    @ObservationIgnored private var cache = SubtitleTranslationCache(capacity: 4_096)
    @ObservationIgnored private var skippedByTarget: [String: Set<String>] = [:]
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var targetLanguage: SubtitleTranslationTargetLanguage = .chineseSimplified
    @ObservationIgnored private var mode: WorkMode = .none
    @ObservationIgnored private var activeSourceIdentifier: String?
    @ObservationIgnored private var focusTime: TimeInterval = 0
    @ObservationIgnored private var pendingLiveTexts: [String] = []
    @ObservationIgnored private var sessionRevision: UInt64 = 0
    @ObservationIgnored private var workEpoch: UInt64 = 0
    @ObservationIgnored private var workWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    // MARK: - SwiftUI Translation Host Election

    func registerHost(_ id: UUID, priority: Int) {
        hostRegistrations.removeAll { $0.id == id }
        hostRegistrations.append(HostRegistration(id: id, priority: priority))
        recomputeActiveHost()
    }

    func unregisterHost(_ id: UUID) {
        hostRegistrations.removeAll { $0.id == id }
        recomputeActiveHost()
    }

    func activeSessionKey(for hostID: UUID) -> SubtitleTranslationSessionKey? {
        guard activeHostID == hostID else { return nil }
        return sessionKey
    }

    private func recomputeActiveHost() {
        var best: HostRegistration?
        for entry in hostRegistrations {
            if let current = best {
                if entry.priority >= current.priority {
                    best = entry
                }
            } else {
                best = entry
            }
        }
        if activeHostID != best?.id {
            activeHostID = best?.id
        }
    }

    // MARK: - Configuration & Lookup

    func configure(
        enabled: Bool,
        targetLanguage: SubtitleTranslationTargetLanguage,
        primaryTrackID: String?,
        primaryCues: [PlayerViewModel.SubtitleCue],
        explicitSourceHint: String?,
        focusTime: TimeInterval
    ) {
        self.isEnabled = enabled
        self.targetLanguage = targetLanguage
        if focusTime.isFinite {
            self.focusTime = max(0, focusTime)
        }

        guard enabled else {
            mode = .none
            activeSourceIdentifier = nil
            pendingLiveTexts.removeAll()
            sessionKey = nil
            status = .idle
            bumpWorkEpochAndWake()
            return
        }

        guard let primaryTrackID else {
            mode = .none
            activeSourceIdentifier = nil
            pendingLiveTexts.removeAll()
            sessionKey = nil
            status = .waitingForPrimaryTrack
            bumpWorkEpochAndWake()
            return
        }

        let resolvedSource: String?
        if let explicitSourceHint, !explicitSourceHint.isEmpty {
            resolvedSource = explicitSourceHint
        } else if !PlayerSubtitleTrackID.isSystemSpeech(primaryTrackID), !primaryCues.isEmpty {
            resolvedSource = SubtitleSourceLanguageResolver.inferSourceIdentifier(from: primaryCues)
        } else {
            resolvedSource = nil
        }

        activeSourceIdentifier = resolvedSource

        if SubtitleSourceLanguageResolver.isEquivalentLanguage(
            sourceIdentifier: resolvedSource,
            target: targetLanguage
        ) {
            mode = .none
            pendingLiveTexts.removeAll()
            sessionKey = nil
            status = .sameLanguage
            bumpWorkEpochAndWake()
            return
        }

        if PlayerSubtitleTrackID.isSystemSpeech(primaryTrackID) {
            mode = .liveSpeech
            status = .liveActive
        } else {
            let uniqueCount = SubtitleTranslationBatchPlanner.uniqueTranslatableTexts(in: primaryCues).count
            mode = .cues(trackID: primaryTrackID, cues: primaryCues, uniqueTotal: uniqueCount)
            pendingLiveTexts.removeAll()
            updateCueProgressStatus(cues: primaryCues, uniqueTotal: uniqueCount)
        }

        let nextKey = SubtitleTranslationSessionKey(
            sourceIdentifier: resolvedSource,
            targetIdentifier: targetLanguage.rawValue,
            revision: sessionRevision
        )
        if sessionKey != nextKey {
            sessionKey = nextKey
        }
        bumpWorkEpochAndWake()
    }

    func prioritize(focusTime: TimeInterval) {
        guard focusTime.isFinite else { return }
        let clamped = max(0, focusTime)
        if abs(clamped - self.focusTime) < 1.0 { return }
        self.focusTime = clamped
        if case .cues = mode {
            bumpWorkEpochAndWake()
        }
    }

    func enqueueLiveText(_ rawText: String) {
        guard isEnabled, case .liveSpeech = mode else { return }
        let normalized = SubtitleTranslationCache.normalize(rawText)
        guard SubtitleTranslationBatchPlanner.isTranslatable(normalized) else { return }
        let targetID = targetLanguage.rawValue
        if cache.peek(for: normalized, targetLanguageID: targetID) != nil { return }
        if skippedByTarget[targetID]?.contains(normalized) == true { return }

        pendingLiveTexts.removeAll { $0 == normalized }
        pendingLiveTexts.append(normalized)
        if pendingLiveTexts.count > 6 {
            pendingLiveTexts.removeFirst(pendingLiveTexts.count - 6)
        }
        bumpWorkEpochAndWake()
    }

    func cachedTranslation(
        for rawText: String,
        targetLanguage: SubtitleTranslationTargetLanguage? = nil
    ) -> String? {
        let targetID = (targetLanguage ?? self.targetLanguage).rawValue
        let normalized = SubtitleTranslationCache.normalize(rawText)
        guard !normalized.isEmpty else { return nil }
        if let direct = cache.peek(for: normalized, targetLanguageID: targetID) {
            return direct
        }
        if normalized.contains("\n") {
            let lines = normalized
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { SubtitleTranslationCache.normalize(String($0)) }
            guard lines.count > 1 else { return nil }
            var translatedLines: [String] = []
            translatedLines.reserveCapacity(lines.count)
            for line in lines {
                guard let translated = cache.peek(for: line, targetLanguageID: targetID) else {
                    return nil
                }
                translatedLines.append(translated)
            }
            return translatedLines.joined(separator: "\n")
        }
        return nil
    }

    /// Injects a pre-translated entry directly into the cache (useful for unit tests and pre-warming).
    func storeCachedTranslation(
        _ translatedText: String,
        for sourceText: String,
        targetLanguage: SubtitleTranslationTargetLanguage
    ) {
        cache.set(translatedText, for: sourceText, targetLanguageID: targetLanguage.rawValue)
    }

    func retry() {
        guard isEnabled else { return }
        skippedByTarget[targetLanguage.rawValue]?.removeAll()
        sessionRevision &+= 1
        if let current = sessionKey {
            sessionKey = SubtitleTranslationSessionKey(
                sourceIdentifier: current.sourceIdentifier,
                targetIdentifier: current.targetIdentifier,
                revision: sessionRevision
            )
        } else if case .cues = mode {
            sessionKey = SubtitleTranslationSessionKey(
                sourceIdentifier: activeSourceIdentifier,
                targetIdentifier: targetLanguage.rawValue,
                revision: sessionRevision
            )
        } else if case .liveSpeech = mode {
            sessionKey = SubtitleTranslationSessionKey(
                sourceIdentifier: activeSourceIdentifier,
                targetIdentifier: targetLanguage.rawValue,
                revision: sessionRevision
            )
        }
        status = .preparing
        bumpWorkEpochAndWake()
    }

    func resetSession() {
        isEnabled = false
        mode = .none
        activeSourceIdentifier = nil
        focusTime = 0
        pendingLiveTexts.removeAll()
        sessionKey = nil
        status = .idle
        bumpWorkEpochAndWake()
    }

    func clearCache() {
        cache.removeAll()
        skippedByTarget.removeAll()
    }

    // MARK: - Worker Coordination API

    func noteSessionPreparing(for expectedKey: SubtitleTranslationSessionKey) {
        guard sessionKey == expectedKey, isEnabled else { return }
        if case .cues(_, let cues, let total) = mode {
            let completed = countTranslatedUnique(in: cues, targetID: expectedKey.targetIdentifier)
            if total > 0 && completed >= total {
                status = .ready(translatedCount: completed, totalCount: total)
                return
            }
        }
        status = .preparing
    }

    func nextWork(for expectedKey: SubtitleTranslationSessionKey) -> NextTranslationWork {
        guard isEnabled, sessionKey == expectedKey else {
            return .stop
        }
        let targetID = expectedKey.targetIdentifier
        let skipped = skippedByTarget[targetID] ?? []

        switch mode {
        case .none:
            return .wait(epoch: workEpoch)
        case .liveSpeech:
            // Prioritize the newest live speech text first so real-time captions never fall behind.
            while let nextText = pendingLiveTexts.popLast() {
                if cache.peek(for: nextText, targetLanguageID: targetID) != nil || skipped.contains(nextText) {
                    continue
                }
                return .liveText(targetID: targetID, text: nextText)
            }
            if status != .liveActive {
                status = .liveActive
            }
            return .wait(epoch: workEpoch)
        case .cues(_, let cues, let uniqueTotal):
            let batch = SubtitleTranslationBatchPlanner.nextBatch(
                cues: cues,
                focusTime: focusTime,
                alreadyHandled: { text in
                    self.cache.peek(for: text, targetLanguageID: targetID) != nil || skipped.contains(text)
                }
            )
            if !batch.isEmpty {
                let completed = countTranslatedUnique(in: cues, targetID: targetID)
                status = .translating(completed: completed, total: max(uniqueTotal, completed))
                return .cueBatch(targetID: targetID, texts: batch)
            }
            updateCueProgressStatus(cues: cues, uniqueTotal: uniqueTotal)
            return .wait(epoch: workEpoch)
        }
    }

    func waitForWorkSignal(after epoch: UInt64) async {
        guard workEpoch == epoch, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || self.workEpoch != epoch {
                    continuation.resume()
                    return
                }
                self.workWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeWaiter(id: waiterID)
            }
        }
    }

    func recordTranslation(
        sourceText: String,
        targetText: String,
        targetID: String,
        expectedKey: SubtitleTranslationSessionKey
    ) {
        cache.set(targetText, for: sourceText, targetLanguageID: targetID)
        guard sessionKey == expectedKey, isEnabled else { return }
        switch mode {
        case .cues(_, let cues, let uniqueTotal):
            updateCueProgressStatus(cues: cues, uniqueTotal: uniqueTotal)
        case .liveSpeech:
            status = .liveActive
        case .none:
            break
        }
        onTranslationsUpdated?()
    }

    func recordSkipped(
        sourceText: String,
        targetID: String,
        expectedKey: SubtitleTranslationSessionKey
    ) {
        let normalized = SubtitleTranslationCache.normalize(sourceText)
        if !normalized.isEmpty {
            skippedByTarget[targetID, default: []].insert(normalized)
        }
        guard sessionKey == expectedKey, isEnabled else { return }
        if case .cues(_, let cues, let uniqueTotal) = mode {
            updateCueProgressStatus(cues: cues, uniqueTotal: uniqueTotal)
        }
    }

    func recordSessionError(
        _ errorStatus: SubtitleTranslationStatus,
        expectedKey: SubtitleTranslationSessionKey
    ) {
        guard sessionKey == expectedKey, isEnabled else { return }
        status = errorStatus
    }

    private func updateCueProgressStatus(cues: [PlayerViewModel.SubtitleCue], uniqueTotal: Int) {
        let targetID = targetLanguage.rawValue
        let skipped = skippedByTarget[targetID] ?? []
        let translatedCount = countTranslatedUnique(in: cues, targetID: targetID)
        if uniqueTotal == 0 {
            status = .ready(translatedCount: 0, totalCount: 0)
            return
        }
        let handledCount = countHandledUnique(in: cues, targetID: targetID, skipped: skipped)
        if handledCount >= uniqueTotal {
            status = .ready(translatedCount: translatedCount, totalCount: uniqueTotal)
        } else {
            status = .translating(completed: translatedCount, total: uniqueTotal)
        }
    }

    private func countTranslatedUnique(in cues: [PlayerViewModel.SubtitleCue], targetID: String) -> Int {
        var seen = Set<String>()
        var count = 0
        for cue in cues {
            let normalized = SubtitleTranslationCache.normalize(cue.content)
            guard SubtitleTranslationBatchPlanner.isTranslatable(normalized),
                  seen.insert(normalized).inserted else { continue }
            if cache.peek(for: normalized, targetLanguageID: targetID) != nil {
                count += 1
            }
        }
        return count
    }

    private func countHandledUnique(
        in cues: [PlayerViewModel.SubtitleCue],
        targetID: String,
        skipped: Set<String>
    ) -> Int {
        var seen = Set<String>()
        var count = 0
        for cue in cues {
            let normalized = SubtitleTranslationCache.normalize(cue.content)
            guard SubtitleTranslationBatchPlanner.isTranslatable(normalized),
                  seen.insert(normalized).inserted else { continue }
            if cache.peek(for: normalized, targetLanguageID: targetID) != nil || skipped.contains(normalized) {
                count += 1
            }
        }
        return count
    }

    private func resumeWaiter(id: UUID) {
        if let continuation = workWaiters.removeValue(forKey: id) {
            continuation.resume()
        }
    }

    private func bumpWorkEpochAndWake() {
        workEpoch &+= 1
        let waiters = Array(workWaiters.values)
        workWaiters.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }

    // MARK: - Non-Isolated Apple TranslationSession Runner (Swift 6 Safe)

    #if canImport(Translation)
    nonisolated static func runTranslationSession(
        _ session: TranslationSession,
        service: SystemSubtitleTranslationService,
        sessionKey: SubtitleTranslationSessionKey
    ) async {
        await service.noteSessionPreparing(for: sessionKey)

        do {
            try await session.prepareTranslation()
        } catch {
            if Task.isCancelled { return }
            if isUnsupportedPairError(error) {
                await service.recordSessionError(.unsupportedPair, expectedKey: sessionKey)
                return
            }
            // When source is auto-detected (nil), prepareTranslation() may throw before text arrives;
            // continue into the work loop so translate(...) detects from real cues.
            if sessionKey.sourceIdentifier != nil, !isPerItemSkippableError(error) {
                await service.recordSessionError(classifyError(error), expectedKey: sessionKey)
                return
            }
        }

        while !Task.isCancelled {
            let work = await service.nextWork(for: sessionKey)
            switch work {
            case .stop:
                return
            case .wait(let epoch):
                await service.waitForWorkSignal(after: epoch)
            case .liveText(let targetID, let text):
                guard !Task.isCancelled else { return }
                do {
                    let response = try await session.translate(text)
                    guard !Task.isCancelled else { return }
                    await service.recordTranslation(
                        sourceText: text,
                        targetText: response.targetText,
                        targetID: targetID,
                        expectedKey: sessionKey
                    )
                } catch {
                    if Task.isCancelled { return }
                    if isPerItemSkippableError(error) {
                        await service.recordSkipped(
                            sourceText: text,
                            targetID: targetID,
                            expectedKey: sessionKey
                        )
                    } else {
                        await service.recordSessionError(classifyError(error), expectedKey: sessionKey)
                        return
                    }
                }
            case .cueBatch(let targetID, let texts):
                guard !Task.isCancelled else { return }
                let requests = texts.enumerated().map { index, text in
                    TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
                }
                var completedIndices = Set<Int>()
                do {
                    for try await response in session.translate(batch: requests) {
                        if Task.isCancelled { return }
                        if let idStr = response.clientIdentifier,
                           let index = Int(idStr),
                           texts.indices.contains(index) {
                            completedIndices.insert(index)
                            await service.recordTranslation(
                                sourceText: texts[index],
                                targetText: response.targetText,
                                targetID: targetID,
                                expectedKey: sessionKey
                            )
                        } else {
                            await service.recordTranslation(
                                sourceText: response.sourceText,
                                targetText: response.targetText,
                                targetID: targetID,
                                expectedKey: sessionKey
                            )
                        }
                    }
                    for (index, text) in texts.enumerated() where !completedIndices.contains(index) {
                        let cached = await service.cachedTranslation(for: text)
                        if cached == nil {
                            await service.recordSkipped(
                                sourceText: text,
                                targetID: targetID,
                                expectedKey: sessionKey
                            )
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    if isPerItemSkippableError(error) {
                        for (index, text) in texts.enumerated() where !completedIndices.contains(index) {
                            if Task.isCancelled { return }
                            do {
                                let response = try await session.translate(text)
                                if Task.isCancelled { return }
                                await service.recordTranslation(
                                    sourceText: text,
                                    targetText: response.targetText,
                                    targetID: targetID,
                                    expectedKey: sessionKey
                                )
                            } catch {
                                if Task.isCancelled { return }
                                if isPerItemSkippableError(error) {
                                    await service.recordSkipped(
                                        sourceText: text,
                                        targetID: targetID,
                                        expectedKey: sessionKey
                                    )
                                } else {
                                    await service.recordSessionError(classifyError(error), expectedKey: sessionKey)
                                    return
                                }
                            }
                        }
                    } else {
                        await service.recordSessionError(classifyError(error), expectedKey: sessionKey)
                        return
                    }
                }
            }
        }
    }

    private nonisolated static func isUnsupportedPairError(_ error: any Error) -> Bool {
        TranslationError.unsupportedLanguagePairing ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error
    }

    private nonisolated static func isPerItemSkippableError(_ error: any Error) -> Bool {
        TranslationError.unableToIdentifyLanguage ~= error
            || TranslationError.nothingToTranslate ~= error
    }

    private nonisolated static func classifyError(_ error: any Error) -> SubtitleTranslationStatus {
        if isUnsupportedPairError(error) {
            return .unsupportedPair
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return .failed(String(localized: "On-device translation is unavailable on this device."))
        }
        return .failed(message)
    }
    #endif
}
