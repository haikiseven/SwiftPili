import Foundation
import os

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

struct FeedLoadToken: Hashable, Sendable {
    let generation: UInt64
    let kind: FeedLoadKind
    let cursor: String
}

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

enum FeedCollectionPolicy {
    struct PreparedRetainedAppend<Element: Sendable>: Sendable {
        let rows: [Element]
        let accepted: [Element]
    }

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
