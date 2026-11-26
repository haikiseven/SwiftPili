import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Persisted Rule Models

struct BlockedUPEntry: Codable, Sendable, Identifiable, Hashable {
    let mid: Int
    var name: String
    var face: String?
    let addedAt: Date

    var id: Int { mid }

    init(mid: Int, name: String, face: String? = nil, addedAt: Date = Date()) {
        self.mid = mid
        self.name = name
        self.face = face
        self.addedAt = addedAt
    }
}

struct BlockedVideoEntry: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let aid: Int?
    let bvid: String?
    var title: String
    var ownerName: String?
    let addedAt: Date

    init(
        aid: Int?,
        bvid: String?,
        title: String,
        ownerName: String? = nil,
        addedAt: Date = Date()
    ) {
        let normalizedBVID = LocalContentFilterStore.normalizedBVID(bvid)
        let normalizedAID = aid.flatMap { $0 > 0 ? $0 : nil }
        self.aid = normalizedAID
        self.bvid = normalizedBVID
        self.title = title
        self.ownerName = ownerName
        self.addedAt = addedAt
        if let normalizedBVID {
            self.id = "bv:\(normalizedBVID)"
        } else if let normalizedAID {
            self.id = "av:\(normalizedAID)"
        } else {
            self.id = "local:\(UUID().uuidString)"
        }
    }
}

struct KeywordFilterRule: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var pattern: String
    var isRegex: Bool
    var isEnabled: Bool
    let addedAt: Date

    init(
        id: UUID = UUID(),
        pattern: String,
        isRegex: Bool = false,
        isEnabled: Bool = true,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.pattern = pattern
        self.isRegex = isRegex
        self.isEnabled = isEnabled
        self.addedAt = addedAt
    }
}

enum CommentFilterReason: Equatable, Sendable {
    case blockedUP(mid: Int, name: String)
    case cloudBlocked(mid: Int)
    case commentKeyword(pattern: String)
}

enum CloudFilterImportTarget: String, CaseIterable, Identifiable, Sendable {
    case comment
    case title
    case both

    var id: String { rawValue }
}

struct LocalContentFilterBackup: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let isEnabled: Bool
    let collapseFilteredComments: Bool
    let blockedUPs: [BlockedUPEntry]
    let blockedVideos: [BlockedVideoEntry]
    let titleKeywords: [KeywordFilterRule]
    let commentKeywords: [KeywordFilterRule]

    init(
        version: Int = Self.currentVersion,
        exportedAt: Date = Date(),
        isEnabled: Bool,
        collapseFilteredComments: Bool,
        blockedUPs: [BlockedUPEntry],
        blockedVideos: [BlockedVideoEntry],
        titleKeywords: [KeywordFilterRule],
        commentKeywords: [KeywordFilterRule]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.isEnabled = isEnabled
        self.collapseFilteredComments = collapseFilteredComments
        self.blockedUPs = blockedUPs
        self.blockedVideos = blockedVideos
        self.titleKeywords = titleKeywords
        self.commentKeywords = commentKeywords
    }
}

struct LocalContentFilterImportSummary: Equatable, Sendable {
    let addedUPs: Int
    let addedVideos: Int
    let addedTitleKeywords: Int
    let addedCommentKeywords: Int

    var totalAdded: Int {
        addedUPs + addedVideos + addedTitleKeywords + addedCommentKeywords
    }
}

struct LocalContentFilterDocument: FileDocument, Sendable {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Video Card Metadata Registry

struct VideoCardFilterMetadata: Sendable, Equatable {
    let aid: Int?
    let bvid: String?
    let title: String
    let ownerMid: Int?
    let ownerName: String
    let ownerFace: String?
}

@MainActor
final class VideoCardFilterMetadataStore {
    static let shared = VideoCardFilterMetadataStore()

    private static let maxEntries = 1500
    private var byAID: [Int: VideoCardFilterMetadata] = [:]
    private var byBVID: [String: VideoCardFilterMetadata] = [:]
    private var insertionOrder: [(aid: Int?, bvid: String?)] = []

    private init() {}

    func record(_ metadata: VideoCardFilterMetadata) {
        let normalizedBVID = LocalContentFilterStore.normalizedBVID(metadata.bvid)
        let normalizedAID = metadata.aid.flatMap { $0 > 0 ? $0 : nil }
        guard normalizedAID != nil || normalizedBVID != nil else { return }

        let existed = (normalizedAID.flatMap { byAID[$0] } != nil)
            || (normalizedBVID.flatMap { byBVID[$0] } != nil)

        if let normalizedAID { byAID[normalizedAID] = metadata }
        if let normalizedBVID { byBVID[normalizedBVID] = metadata }

        if !existed {
            insertionOrder.append((aid: normalizedAID, bvid: normalizedBVID))
            while insertionOrder.count > Self.maxEntries {
                let evicted = insertionOrder.removeFirst()
                if let aid = evicted.aid { byAID.removeValue(forKey: aid) }
                if let bvid = evicted.bvid { byBVID.removeValue(forKey: bvid) }
            }
        }
    }

    func lookup(aid: Int?, bvid: String?) -> VideoCardFilterMetadata? {
        if let aid, aid > 0, let found = byAID[aid] { return found }
        if let normalizedBVID = LocalContentFilterStore.normalizedBVID(bvid),
           let found = byBVID[normalizedBVID] {
            return found
        }
        return nil
    }
}

// MARK: - LocalContentFilterStore

@MainActor
@Observable
final class LocalContentFilterStore {
    struct CompiledSubstring: Sendable {
        let id: UUID
        let originalPattern: String
        let lowercased: String
    }

    struct CompiledRegex: @unchecked Sendable {
        let id: UUID
        let pattern: String
        let regex: NSRegularExpression
    }

    struct CompiledSnapshot: Sendable {
        let revision: UInt64
        let isEnabled: Bool
        let collapseFilteredComments: Bool
        let blockedUPMIDs: Set<Int>
        let blockedUPNamesByMID: [Int: String]
        let blockedVideoAIDs: Set<Int>
        let blockedVideoBVIDs: Set<String>
        let sessionDislikedAIDs: Set<Int>
        let sessionDislikedBVIDs: Set<String>
        let titleSubstrings: [CompiledSubstring]
        let titleRegexes: [CompiledRegex]
        let commentSubstrings: [CompiledSubstring]
        let commentRegexes: [CompiledRegex]

        static let empty = CompiledSnapshot(
            revision: 0,
            isEnabled: true,
            collapseFilteredComments: false,
            blockedUPMIDs: [],
            blockedUPNamesByMID: [:],
            blockedVideoAIDs: [],
            blockedVideoBVIDs: [],
            sessionDislikedAIDs: [],
            sessionDislikedBVIDs: [],
            titleSubstrings: [],
            titleRegexes: [],
            commentSubstrings: [],
            commentRegexes: []
        )

        func matchesSessionDisliked(aid: Int?, bvid: String?) -> Bool {
            if let aid, aid > 0, sessionDislikedAIDs.contains(aid) { return true }
            if let normalized = LocalContentFilterStore.normalizedBVID(bvid),
               sessionDislikedBVIDs.contains(normalized) {
                return true
            }
            return false
        }

        func matchesLocalVideo(aid: Int?, bvid: String?, mid: Int?, title: String?) -> Bool {
            guard isEnabled else { return false }
            if let mid, mid > 0, blockedUPMIDs.contains(mid) { return true }
            if let aid, aid > 0, blockedVideoAIDs.contains(aid) { return true }
            if let normalized = LocalContentFilterStore.normalizedBVID(bvid),
               blockedVideoBVIDs.contains(normalized) {
                return true
            }
            if let title, !title.isEmpty, matchesTitle(title) { return true }
            return false
        }

        func matchesTitle(_ title: String) -> Bool {
            guard isEnabled, !title.isEmpty else { return false }
            if !titleSubstrings.isEmpty {
                let lowered = title.lowercased()
                for sub in titleSubstrings where lowered.contains(sub.lowercased) { return true }
            }
            if !titleRegexes.isEmpty {
                let range = NSRange(location: 0, length: (title as NSString).length)
                for compiled in titleRegexes where compiled.regex.firstMatch(in: title, range: range) != nil {
                    return true
                }
            }
            return false
        }

        func matchLocalComment(mid: Int, content: String) -> CommentFilterReason? {
            guard isEnabled else { return nil }
            if mid > 0, let name = blockedUPNamesByMID[mid] {
                return .blockedUP(mid: mid, name: name)
            }
            guard !content.isEmpty else { return nil }
            if !commentSubstrings.isEmpty {
                let lowered = content.lowercased()
                for sub in commentSubstrings where lowered.contains(sub.lowercased) {
                    return .commentKeyword(pattern: sub.originalPattern)
                }
            }
            if !commentRegexes.isEmpty {
                let range = NSRange(location: 0, length: (content as NSString).length)
                for compiled in commentRegexes where compiled.regex.firstMatch(in: content, range: range) != nil {
                    return .commentKeyword(pattern: compiled.pattern)
                }
            }
            return nil
        }
    }

    private struct WeakObserver {
        let notify: @MainActor () -> Bool
    }

    static let shared = LocalContentFilterStore()

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue, !isSuppressingPropertySideEffects else { return }
            userDefaults.set(isEnabled, forKey: enabledKey)
            commitChange(persistRules: true)
        }
    }

    var collapseFilteredComments: Bool {
        didSet {
            guard collapseFilteredComments != oldValue, !isSuppressingPropertySideEffects else { return }
            userDefaults.set(collapseFilteredComments, forKey: collapseCommentsKey)
            commitChange(persistRules: true)
        }
    }

    private(set) var blockedUPs: [BlockedUPEntry] = []
    private(set) var blockedVideos: [BlockedVideoEntry] = []
    private(set) var titleKeywords: [KeywordFilterRule] = []
    private(set) var commentKeywords: [KeywordFilterRule] = []
    private(set) var sessionDislikedAIDs: Set<Int> = []
    private(set) var sessionDislikedBVIDs: Set<String> = []
    private(set) var revision: UInt64 = 0
    private(set) var snapshot: CompiledSnapshot = .empty

    var totalRuleCount: Int {
        blockedUPs.count + blockedVideos.count + titleKeywords.count + commentKeywords.count
    }

    var activeRuleCount: Int {
        blockedUPs.count
            + blockedVideos.count
            + titleKeywords.filter(\.isEnabled).count
            + commentKeywords.filter(\.isEnabled).count
    }

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let enabledKey: String
    @ObservationIgnored private let collapseCommentsKey: String
    @ObservationIgnored private let observesCloudBlocklist: Bool
    @ObservationIgnored private var isSuppressingPropertySideEffects = false
    @ObservationIgnored private var observers: [WeakObserver] = []

    init(
        storageURL: URL? = nil,
        userDefaults: UserDefaults = .standard,
        keyPrefix: String = "local_content_filter",
        observesCloudBlocklist: Bool = true
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.userDefaults = userDefaults
        self.enabledKey = "\(keyPrefix)_enabled"
        self.collapseCommentsKey = "\(keyPrefix)_collapse_comments"
        self.observesCloudBlocklist = observesCloudBlocklist
        self.isEnabled = userDefaults.object(forKey: self.enabledKey) as? Bool ?? true
        self.collapseFilteredComments = userDefaults.object(forKey: self.collapseCommentsKey) as? Bool ?? false

        loadFromDisk()
        rebuildSnapshot()
        if observesCloudBlocklist {
            startObservingCloudBlocklist()
        }
    }

    func addObserver<Owner: AnyObject>(
        _ owner: Owner,
        handler: @escaping @MainActor (Owner) -> Void
    ) {
        observers.append(WeakObserver { [weak owner] in
            guard let owner else { return false }
            handler(owner)
            return true
        })
    }
}

// MARK: - Filtering Queries

extension LocalContentFilterStore {
    func shouldHideVideo(
        aid: Int?,
        bvid: String?,
        mid: Int?,
        title: String?,
        includeCloudBlocklist: Bool = true
    ) -> Bool {
        let current = snapshot
        if current.matchesSessionDisliked(aid: aid, bvid: bvid) { return true }
        if includeCloudBlocklist, let mid, mid > 0, BlocklistManager.shared.isBlocked(mid) {
            return true
        }
        return current.matchesLocalVideo(aid: aid, bvid: bvid, mid: mid, title: title)
    }

    func matchComment(
        mid: Int,
        content: String,
        includeCloudBlocklist: Bool = true
    ) -> CommentFilterReason? {
        if includeCloudBlocklist, mid > 0, BlocklistManager.shared.isBlocked(mid) {
            return .cloudBlocked(mid: mid)
        }
        return snapshot.matchLocalComment(mid: mid, content: content)
    }

    func shouldHideCommentCompletely(
        mid: Int,
        content: String,
        includeCloudBlocklist: Bool = true
    ) -> Bool {
        guard !collapseFilteredComments else { return false }
        return matchComment(mid: mid, content: content, includeCloudBlocklist: includeCloudBlocklist) != nil
    }

    func isUPBlockedLocally(_ mid: Int) -> Bool {
        mid > 0 && snapshot.blockedUPMIDs.contains(mid)
    }

    func isVideoBlockedLocally(aid: Int?, bvid: String?) -> Bool {
        if let aid, aid > 0, snapshot.blockedVideoAIDs.contains(aid) { return true }
        if let normalized = Self.normalizedBVID(bvid), snapshot.blockedVideoBVIDs.contains(normalized) {
            return true
        }
        return false
    }

    func isSessionDisliked(aid: Int?, bvid: String?) -> Bool {
        snapshot.matchesSessionDisliked(aid: aid, bvid: bvid)
    }

    func hasKeywordRule(pattern: String, isRegex: Bool, in target: CloudFilterImportTarget) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let inComment = Self.containsRule(trimmed, isRegex: isRegex, in: commentKeywords)
        let inTitle = Self.containsRule(trimmed, isRegex: isRegex, in: titleKeywords)
        switch target {
        case .comment: return inComment
        case .title: return inTitle
        case .both: return inComment && inTitle
        }
    }
}

// MARK: - Rule Mutations & Cloud Import

extension LocalContentFilterStore {
    func markSessionDisliked(aid: Int?, bvid: String?) {
        var changed = false
        if let aid, aid > 0, sessionDislikedAIDs.insert(aid).inserted { changed = true }
        if let normalized = Self.normalizedBVID(bvid), sessionDislikedBVIDs.insert(normalized).inserted {
            changed = true
        }
        guard changed else { return }
        commitChange(persistRules: false)
    }

    func unmarkSessionDisliked(aid: Int?, bvid: String?) {
        var changed = false
        if let aid, aid > 0, sessionDislikedAIDs.remove(aid) != nil { changed = true }
        if let normalized = Self.normalizedBVID(bvid), sessionDislikedBVIDs.remove(normalized) != nil {
            changed = true
        }
        guard changed else { return }
        commitChange(persistRules: false)
    }

    @discardableResult
    func blockUP(mid: Int, name: String, face: String? = nil) -> Bool {
        guard mid > 0 else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "UID \(mid)" : trimmedName
        if let idx = blockedUPs.firstIndex(where: { $0.mid == mid }) {
            var existing = blockedUPs[idx]
            var updated = false
            if existing.name != resolvedName, !trimmedName.isEmpty {
                existing.name = resolvedName
                updated = true
            }
            if let face, !face.isEmpty, existing.face != face {
                existing.face = face
                updated = true
            }
            if updated {
                blockedUPs[idx] = existing
                commitChange(persistRules: true)
            }
            return false
        }
        blockedUPs.insert(BlockedUPEntry(mid: mid, name: resolvedName, face: face), at: 0)
        commitChange(persistRules: true)
        return true
    }

    func unblockUP(mid: Int) {
        guard let idx = blockedUPs.firstIndex(where: { $0.mid == mid }) else { return }
        blockedUPs.remove(at: idx)
        commitChange(persistRules: true)
    }

    @discardableResult
    func blockVideo(
        aid: Int?,
        bvid: String?,
        title: String,
        ownerName: String? = nil
    ) -> BlockedVideoEntry? {
        let normalizedAID = aid.flatMap { $0 > 0 ? $0 : nil }
        let normalizedBVID = Self.normalizedBVID(bvid)
        guard normalizedAID != nil || normalizedBVID != nil else { return nil }
        guard !isVideoBlockedLocally(aid: normalizedAID, bvid: normalizedBVID) else { return nil }
        let entry = BlockedVideoEntry(
            aid: normalizedAID,
            bvid: normalizedBVID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            ownerName: ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        blockedVideos.insert(entry, at: 0)
        commitChange(persistRules: true)
        return entry
    }

    func unblockVideo(id: String) {
        guard let idx = blockedVideos.firstIndex(where: { $0.id == id }) else { return }
        blockedVideos.remove(at: idx)
        commitChange(persistRules: true)
    }

    func unblockVideo(aid: Int?, bvid: String?) {
        let normalizedAID = aid.flatMap { $0 > 0 ? $0 : nil }
        let normalizedBVID = Self.normalizedBVID(bvid)
        let before = blockedVideos.count
        blockedVideos.removeAll { entry in
            (normalizedAID != nil && entry.aid == normalizedAID)
                || (normalizedBVID != nil && entry.bvid == normalizedBVID)
        }
        guard blockedVideos.count != before else { return }
        commitChange(persistRules: true)
    }

    @discardableResult
    func addTitleKeyword(_ pattern: String, isRegex: Bool = false) -> KeywordFilterRule? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.containsRule(trimmed, isRegex: isRegex, in: titleKeywords) else {
            return nil
        }
        let rule = KeywordFilterRule(pattern: trimmed, isRegex: isRegex, isEnabled: true)
        titleKeywords.insert(rule, at: 0)
        commitChange(persistRules: true)
        return rule
    }

    func removeTitleKeyword(id: UUID) {
        guard let idx = titleKeywords.firstIndex(where: { $0.id == id }) else { return }
        titleKeywords.remove(at: idx)
        commitChange(persistRules: true)
    }

    func toggleTitleKeyword(id: UUID, isEnabled: Bool) {
        guard let idx = titleKeywords.firstIndex(where: { $0.id == id }),
              titleKeywords[idx].isEnabled != isEnabled else { return }
        titleKeywords[idx].isEnabled = isEnabled
        commitChange(persistRules: true)
    }

    @discardableResult
    func addCommentKeyword(_ pattern: String, isRegex: Bool = false) -> KeywordFilterRule? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.containsRule(trimmed, isRegex: isRegex, in: commentKeywords) else {
            return nil
        }
        let rule = KeywordFilterRule(pattern: trimmed, isRegex: isRegex, isEnabled: true)
        commentKeywords.insert(rule, at: 0)
        commitChange(persistRules: true)
        return rule
    }

    func removeCommentKeyword(id: UUID) {
        guard let idx = commentKeywords.firstIndex(where: { $0.id == id }) else { return }
        commentKeywords.remove(at: idx)
        commitChange(persistRules: true)
    }

    func toggleCommentKeyword(id: UUID, isEnabled: Bool) {
        guard let idx = commentKeywords.firstIndex(where: { $0.id == id }),
              commentKeywords[idx].isEnabled != isEnabled else { return }
        commentKeywords[idx].isEnabled = isEnabled
        commitChange(persistRules: true)
    }

    @discardableResult
    func importCloudDanmakuFilters(
        _ rules: [CloudDanmakuFilterRule],
        target: CloudFilterImportTarget = .both
    ) -> Int {
        var addedCount = 0
        for cloudRule in rules where cloudRule.isImportableAsKeywordRule {
            let trimmed = cloudRule.filter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let isRegex = cloudRule.isRegex
            let includeComments = target == .comment || target == .both
            if includeComments, !Self.containsRule(trimmed, isRegex: isRegex, in: commentKeywords) {
                commentKeywords.insert(
                    KeywordFilterRule(pattern: trimmed, isRegex: isRegex, isEnabled: true),
                    at: 0
                )
                addedCount += 1
            }
            let includeTitles = target == .title || target == .both
            if includeTitles, !Self.containsRule(trimmed, isRegex: isRegex, in: titleKeywords) {
                titleKeywords.insert(
                    KeywordFilterRule(pattern: trimmed, isRegex: isRegex, isEnabled: true),
                    at: 0
                )
                addedCount += 1
            }
        }
        if addedCount > 0 { commitChange(persistRules: true) }
        return addedCount
    }

    func clearAllRules() {
        guard totalRuleCount > 0 else { return }
        blockedUPs = []
        blockedVideos = []
        titleKeywords = []
        commentKeywords = []
        commitChange(persistRules: true)
    }
}

// MARK: - Backup Export / Import & Validation

extension LocalContentFilterStore {
    func makeBackup() -> LocalContentFilterBackup {
        LocalContentFilterBackup(
            isEnabled: isEnabled,
            collapseFilteredComments: collapseFilteredComments,
            blockedUPs: blockedUPs,
            blockedVideos: blockedVideos,
            titleKeywords: titleKeywords,
            commentKeywords: commentKeywords
        )
    }

    func exportJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(makeBackup())
    }

    @discardableResult
    func importJSONData(_ data: Data, merge: Bool = true) throws -> LocalContentFilterImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LocalContentFilterBackup.self, from: data)
        return merge ? mergeBackup(backup) : replaceWithBackup(backup)
    }

    nonisolated static func validateRegex(_ pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated static func normalizedBVID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("bv") ? "BV" + trimmed.dropFirst(2) : trimmed
    }
}

// MARK: - Private Implementation

private extension LocalContentFilterStore {
    func replaceWithBackup(_ backup: LocalContentFilterBackup) -> LocalContentFilterImportSummary {
        isSuppressingPropertySideEffects = true
        blockedUPs = backup.blockedUPs
        blockedVideos = backup.blockedVideos
        titleKeywords = backup.titleKeywords
        commentKeywords = backup.commentKeywords
        isEnabled = backup.isEnabled
        collapseFilteredComments = backup.collapseFilteredComments
        isSuppressingPropertySideEffects = false
        userDefaults.set(isEnabled, forKey: enabledKey)
        userDefaults.set(collapseFilteredComments, forKey: collapseCommentsKey)
        commitChange(persistRules: true)
        return LocalContentFilterImportSummary(
            addedUPs: blockedUPs.count,
            addedVideos: blockedVideos.count,
            addedTitleKeywords: titleKeywords.count,
            addedCommentKeywords: commentKeywords.count
        )
    }

    func mergeBackup(_ backup: LocalContentFilterBackup) -> LocalContentFilterImportSummary {
        let addedUPs = mergeUPs(backup.blockedUPs)
        let addedVideos = mergeVideos(backup.blockedVideos)
        let addedTitles = mergeKeywords(backup.titleKeywords, into: &titleKeywords)
        let addedComments = mergeKeywords(backup.commentKeywords, into: &commentKeywords)
        let summary = LocalContentFilterImportSummary(
            addedUPs: addedUPs,
            addedVideos: addedVideos,
            addedTitleKeywords: addedTitles,
            addedCommentKeywords: addedComments
        )
        if summary.totalAdded > 0 { commitChange(persistRules: true) }
        return summary
    }

    func mergeUPs(_ incoming: [BlockedUPEntry]) -> Int {
        var added = 0
        var existingMIDs = Set(blockedUPs.map(\.mid))
        for entry in incoming where entry.mid > 0 && existingMIDs.insert(entry.mid).inserted {
            blockedUPs.append(entry)
            added += 1
        }
        return added
    }

    func mergeVideos(_ incoming: [BlockedVideoEntry]) -> Int {
        var added = 0
        var existingIDs = Set(blockedVideos.map(\.id))
        var existingAIDs = Set(blockedVideos.compactMap(\.aid))
        var existingBVIDs = Set(blockedVideos.compactMap(\.bvid))
        for entry in incoming {
            let duplicate = existingIDs.contains(entry.id)
                || (entry.aid.map { existingAIDs.contains($0) } ?? false)
                || (entry.bvid.map { existingBVIDs.contains($0) } ?? false)
            guard !duplicate else { continue }
            blockedVideos.append(entry)
            existingIDs.insert(entry.id)
            if let aid = entry.aid { existingAIDs.insert(aid) }
            if let bvid = entry.bvid { existingBVIDs.insert(bvid) }
            added += 1
        }
        return added
    }

    func mergeKeywords(_ incoming: [KeywordFilterRule], into target: inout [KeywordFilterRule]) -> Int {
        var added = 0
        for rule in incoming {
            let trimmed = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !Self.containsRule(trimmed, isRegex: rule.isRegex, in: target) else {
                continue
            }
            target.append(
                KeywordFilterRule(
                    id: rule.id,
                    pattern: trimmed,
                    isRegex: rule.isRegex,
                    isEnabled: rule.isEnabled,
                    addedAt: rule.addedAt
                )
            )
            added += 1
        }
        return added
    }

    func commitChange(persistRules: Bool) {
        revision &+= 1
        rebuildSnapshot()
        if persistRules { saveToDisk() }
        notifyObservers()
    }

    func rebuildSnapshot() {
        var upMIDs: Set<Int> = []
        var upNames: [Int: String] = [:]
        for entry in blockedUPs where entry.mid > 0 {
            upMIDs.insert(entry.mid)
            upNames[entry.mid] = entry.name
        }
        var videoAIDs: Set<Int> = []
        var videoBVIDs: Set<String> = []
        for entry in blockedVideos {
            if let aid = entry.aid, aid > 0 { videoAIDs.insert(aid) }
            if let bvid = Self.normalizedBVID(entry.bvid) { videoBVIDs.insert(bvid) }
        }
        let compiledTitles = Self.compileKeywordRules(titleKeywords)
        let compiledComments = Self.compileKeywordRules(commentKeywords)
        snapshot = CompiledSnapshot(
            revision: revision,
            isEnabled: isEnabled,
            collapseFilteredComments: collapseFilteredComments,
            blockedUPMIDs: upMIDs,
            blockedUPNamesByMID: upNames,
            blockedVideoAIDs: videoAIDs,
            blockedVideoBVIDs: videoBVIDs,
            sessionDislikedAIDs: sessionDislikedAIDs,
            sessionDislikedBVIDs: sessionDislikedBVIDs,
            titleSubstrings: compiledTitles.substrings,
            titleRegexes: compiledTitles.regexes,
            commentSubstrings: compiledComments.substrings,
            commentRegexes: compiledComments.regexes
        )
    }

    func notifyObservers() {
        observers = observers.filter { $0.notify() }
    }

    func startObservingCloudBlocklist() {
        withObservationTracking {
            _ = BlocklistManager.shared.isEnabled
            _ = BlocklistManager.shared.blockedMids
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.revision &+= 1
                self.rebuildSnapshot()
                self.notifyObservers()
                self.startObservingCloudBlocklist()
            }
        }
    }

    func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(LocalContentFilterBackup.self, from: data)
            blockedUPs = backup.blockedUPs
            blockedVideos = backup.blockedVideos
            titleKeywords = backup.titleKeywords
            commentKeywords = backup.commentKeywords
            isSuppressingPropertySideEffects = true
            if userDefaults.object(forKey: enabledKey) == nil { isEnabled = backup.isEnabled }
            if userDefaults.object(forKey: collapseCommentsKey) == nil {
                collapseFilteredComments = backup.collapseFilteredComments
            }
            isSuppressingPropertySideEffects = false
        } catch {
            PlayerLog.log("[LocalContentFilter] failed to load persisted rules: \(error)")
        }
    }

    func saveToDisk() {
        do {
            let parent = storageURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try exportJSONData().write(to: storageURL, options: [.atomic])
        } catch {
            PlayerLog.log("[LocalContentFilter] failed to save rules: \(error)")
        }
    }

    static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SwiftPili", isDirectory: true)
            .appendingPathComponent("local_content_filter_v1.json", isDirectory: false)
    }

    static func containsRule(_ trimmedPattern: String, isRegex: Bool, in rules: [KeywordFilterRule]) -> Bool {
        rules.contains {
            $0.isRegex == isRegex && $0.pattern.caseInsensitiveCompare(trimmedPattern) == .orderedSame
        }
    }

    static func compileKeywordRules(
        _ rules: [KeywordFilterRule]
    ) -> (substrings: [CompiledSubstring], regexes: [CompiledRegex]) {
        var substrings: [CompiledSubstring] = []
        var regexes: [CompiledRegex] = []
        for rule in rules where rule.isEnabled {
            let trimmed = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if rule.isRegex {
                if let compiled = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) {
                    regexes.append(CompiledRegex(id: rule.id, pattern: trimmed, regex: compiled))
                }
            } else {
                substrings.append(
                    CompiledSubstring(
                        id: rule.id,
                        originalPattern: trimmed,
                        lowercased: trimmed.lowercased()
                    )
                )
            }
        }
        return (substrings, regexes)
    }
}
