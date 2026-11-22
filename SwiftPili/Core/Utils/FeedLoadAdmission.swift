import Foundation
import os

/// The feed surfaces covered by the loading/scroll performance contract.
enum FeedPerformanceScreen: String, Sendable {
    case home
    case search
    case dynamics
    case liveList
}

enum FeedLoadKind: String, Sendable {
    case initial
    case pagination
    case refresh
}

enum FeedLoadOutcome: String, Sendable {
    case success
    case failed
    case cancelled
    case superseded
}

/// Opaque identity for one admitted request. `cursor` is deliberately kept
/// out of diagnostics: Dynamics uses a server-provided continuation token,
/// and the performance stream must never expose it.
struct FeedLoadToken: Hashable, Sendable {
    let generation: UInt64
    let kind: FeedLoadKind
    let cursor: String
}

/// Pure request admission for lazy list triggers.
///
/// A page cursor is admitted once at a time and, after a successful response,
/// is not admitted again in the same generation. A failed/cancelled request is
/// retryable. Refresh/new-search callers explicitly supersede the old
/// generation, so late responses can finish without mutating current state.
struct FeedLoadAdmission: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var duplicateSuppressionCount = 0

    private var inFlight: Set<FeedLoadToken> = []
    private var completedPaginationCursors: Set<String> = []

    var hasInFlight: Bool { !inFlight.isEmpty }

    mutating func admit(kind: FeedLoadKind, cursor: String) -> FeedLoadToken? {
        let token = FeedLoadToken(generation: generation, kind: kind, cursor: cursor)
        let isCompletedPagination = kind == .pagination
            && completedPaginationCursors.contains(cursor)
        guard !inFlight.contains(token), !isCompletedPagination else {
            duplicateSuppressionCount += 1
            return nil
        }
        inFlight.insert(token)
        return token
    }

    /// Invalidates all older work and admits one request in a fresh
    /// generation. Used by refreshes, new searches, and filter changes.
    mutating func supersedeAndAdmit(
        kind: FeedLoadKind,
        cursor: String
    ) -> FeedLoadToken {
        generation &+= 1
        inFlight.removeAll(keepingCapacity: true)
        completedPaginationCursors.removeAll(keepingCapacity: true)
        let token = FeedLoadToken(generation: generation, kind: kind, cursor: cursor)
        inFlight.insert(token)
        return token
    }

    /// Invalidates work without starting a replacement request.
    mutating func supersede() {
        generation &+= 1
        inFlight.removeAll(keepingCapacity: true)
        completedPaginationCursors.removeAll(keepingCapacity: true)
    }

    func isCurrent(_ token: FeedLoadToken) -> Bool {
        token.generation == generation
    }

    mutating func finish(_ token: FeedLoadToken, succeeded: Bool) {
        inFlight.remove(token)
        guard succeeded, isCurrent(token), token.kind == .pagination else { return }
        completedPaginationCursors.insert(token.cursor)
    }
}

/// Reference wrapper for SwiftUI views that need to keep a gate across body
/// evaluations while an async `onAppear` request is suspended.
final class FeedLoadAdmissionGate {
    private var admission = FeedLoadAdmission()

    var generation: UInt64 { admission.generation }
    var duplicateSuppressionCount: Int { admission.duplicateSuppressionCount }
    var hasInFlight: Bool { admission.hasInFlight }

    func admit(kind: FeedLoadKind, cursor: String) -> FeedLoadToken? {
        admission.admit(kind: kind, cursor: cursor)
    }

    func supersedeAndAdmit(kind: FeedLoadKind, cursor: String) -> FeedLoadToken {
        admission.supersedeAndAdmit(kind: kind, cursor: cursor)
    }

    func supersede() {
        admission.supersede()
    }

    func isCurrent(_ token: FeedLoadToken) -> Bool {
        admission.isCurrent(token)
    }

    func finish(_ token: FeedLoadToken, succeeded: Bool) {
        admission.finish(token, succeeded: succeeded)
    }
}

/// Stable first-seen ordering for append/replace operations. The caller owns
/// the model's real identifier; this helper never invents an index or UUID.
enum FeedCollectionPolicy {
    struct PreparedRetainedAppend<Element: Sendable>: Sendable {
        let rows: [Element]
        /// Rebase only these candidates if a local deletion changed the base.
        let accepted: [Element]
    }

    /// Exclude only identities already retained before this page. New duplicates
    /// within the incoming page preserve their original DTOs and ordering.
    @concurrent
    static func appendingAgainstRetainedIDs<Element: Sendable, ID: Hashable & Sendable>(
        existing: [Element],
        incoming: [Element],
        id: @Sendable (Element) -> ID
    ) async throws -> PreparedRetainedAppend<Element> {
        try Task.checkCancellation()
        guard !incoming.isEmpty else { return .init(rows: existing, accepted: []) }
        var retainedIDs: Set<ID> = []
        for item in existing {
            try Task.checkCancellation()
            retainedIDs.insert(id(item))
        }
        var accepted: [Element] = []
        for item in incoming {
            try Task.checkCancellation()
            if !retainedIDs.contains(id(item)) { accepted.append(item) }
        }
        var prepared = existing
        prepared.append(contentsOf: accepted)
        try Task.checkCancellation()
        return .init(rows: prepared, accepted: accepted)
    }

    /// Replay only deletions accepted after this response started preparation.
    /// A missing server count keeps the caller's current total instead.
    static func totalAfterLocalRemovals(_ serverTotal: Int, removals: UInt64) -> Int {
        guard removals > 0 else { return serverTotal }
        guard serverTotal > 0 else { return 0 }
        return serverTotal - Int(min(UInt64(serverTotal), removals))
    }

    static func appendDeduplicated<Element, ID: Hashable>(
        existing: [Element],
        incoming: [Element],
        id: (Element) -> ID
    ) -> [Element] {
        var result = existing
        appendDeduplicated(to: &result, incoming: incoming, id: id)
        return result
    }

    static func appendDeduplicated<Element, ID: Hashable>(
        to existing: inout [Element],
        incoming: [Element],
        id: (Element) -> ID
    ) {
        var seen = Set(existing.map(id))
        existing.reserveCapacity(existing.count + incoming.count)
        for item in incoming where seen.insert(id(item)).inserted {
            existing.append(item)
        }
    }

    static func replaceDeduplicated<Element, ID: Hashable>(
        _ incoming: [Element],
        id: (Element) -> ID
    ) -> [Element] {
        appendDeduplicated(existing: [], incoming: incoming, id: id)
    }
}

/// Feed-only signposts. Fields are limited to fixed screen/kind labels,
/// generation, page numbers, counts, and outcomes. No query, cursor token,
/// URL, user text, or authentication value is ever attached.
enum FeedPerformanceSignposts {
    private static let log = OSLog(
        subsystem: PlayerLog.subsystem,
        category: "FeedPerformance"
    )
    private static let sequence = OSAllocatedUnfairLock(initialState: UInt64(0))

    static func screenAdmission(_ screen: FeedPerformanceScreen) {
        guard log.signpostsEnabled else { return }
        emitEvent(screen: screen, kind: "screenAdmission", generation: 0, page: 0, count: 0, outcome: "accepted")
    }

    static func begin(
        screen: FeedPerformanceScreen,
        kind: FeedLoadKind,
        generation: UInt64,
        page: Int?
    ) -> UInt64 {
        guard log.signpostsEnabled else { return 0 }
        let id = nextID()
        os_signpost(
            .begin,
            log: log,
            name: "FeedLoad",
            signpostID: OSSignpostID(id),
            "screen=%{public}s kind=%{public}s generation=%{public}llu page=%{public}d",
            screen.rawValue,
            kind.rawValue,
            generation,
            page ?? 0
        )
        return id
    }

    static func end(
        _ id: UInt64,
        screen: FeedPerformanceScreen,
        kind: FeedLoadKind,
        generation: UInt64,
        page: Int?,
        outcome: FeedLoadOutcome,
        count: Int
    ) {
        guard id != 0, log.signpostsEnabled else { return }
        os_signpost(
            .end,
            log: log,
            name: "FeedLoad",
            signpostID: OSSignpostID(id),
            "screen=%{public}s kind=%{public}s generation=%{public}llu page=%{public}d outcome=%{public}s count=%{public}d",
            screen.rawValue,
            kind.rawValue,
            generation,
            page ?? 0,
            outcome.rawValue,
            count
        )
    }

    static func firstContent(
        _ screen: FeedPerformanceScreen,
        generation: UInt64,
        count: Int
    ) {
        guard log.signpostsEnabled else { return }
        emitEvent(screen: screen, kind: "firstContent", generation: generation, page: 0, count: count, outcome: "accepted")
    }

    static func duplicateSuppressed(
        _ screen: FeedPerformanceScreen,
        kind: FeedLoadKind,
        generation: UInt64,
        count: Int
    ) {
        guard log.signpostsEnabled else { return }
        emitEvent(screen: screen, kind: "duplicateSuppressed", generation: generation, page: 0, count: count, outcome: kind.rawValue)
    }

    private static func emitEvent(
        screen: FeedPerformanceScreen,
        kind: String,
        generation: UInt64,
        page: Int,
        count: Int,
        outcome: String
    ) {
        os_signpost(
            .event,
            log: log,
            name: "FeedPerformance",
            signpostID: OSSignpostID(nextID()),
            "screen=%{public}s kind=%{public}s generation=%{public}llu page=%{public}d count=%{public}d outcome=%{public}s",
            screen.rawValue,
            kind,
            generation,
            page,
            count,
            outcome
        )
    }

    private static func nextID() -> UInt64 {
        sequence.withLock { value in
            value &+= 1
            return value
        }
    }
}
