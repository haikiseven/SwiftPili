import Foundation

enum MultiConnectionPlanner {
    struct Fragment: Sendable, Equatable, Hashable {
        let range: Range<Int64>
        let startSeconds: TimeInterval
        let durationSeconds: TimeInterval
    }

    struct Candidate: Sendable, Equatable, Hashable {
        let track: Int
        let fragment: Fragment
        let claimRange: Range<Int64>
        let deadline: TimeInterval

        init(
            track: Int,
            fragment: Fragment,
            claimRange: Range<Int64>? = nil,
            deadline: TimeInterval
        ) {
            self.track = track
            self.fragment = fragment
            self.claimRange = claimRange ?? fragment.range
            self.deadline = deadline
        }

        var claimBytes: Int64 { claimRange.upperBound - claimRange.lowerBound }
    }

    struct Window: Sendable {
        let position: TimeInterval
        let rate: Float
        let ahead: TimeInterval
        let byteBudget: Int64
        var heldRanges: [Range<Int64>] = []
        var currentTail: Range<Int64>?
    }

    static let minimumPieceBytes = 256 * 1024
    static let mediumLeadingPieceBytes = 512 * 1024
    static let largeLeadingPieceBytes = 1024 * 1024
    static let maximumPieceBytes = 4 * 1024 * 1024
    static let maximumConcurrentRequests = 8
    static let minimumSplitBytes: Int64 = 2 * 1024 * 1024
    static let minimumTrackShareBytes: Int64 = 2 << 20

    static func leadingPieceCeiling(claimBytes: Int64) -> Int {
        if claimBytes >= 8 << 20 { return largeLeadingPieceBytes }
        if claimBytes >= 2 << 20 { return mediumLeadingPieceBytes }
        return minimumPieceBytes
    }

    static func workLimit(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        ExperimentalSettingsPolicy.isAllowed(.multiConnection)
            && environment["PATHA_MULTI_CONNECTION_PIPELINE"] == "0" ? 1 : 2
    }

    static func requestLimit(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        ExperimentalSettingsPolicy.isAllowed(.multiConnection)
            && environment["PATHA_MULTI_CONNECTION_LIMIT"] == "4" ? 4 : maximumConcurrentRequests
    }

    static func pieceCap(fragmentBytes: Int64, hostCount: Int, concurrencyLimit: Int) -> Int {
        let target = min(Int64(max(1, min(maximumConcurrentRequests, concurrencyLimit))), Int64(max(1, hostCount)),
                         max(1, fragmentBytes / Int64(minimumPieceBytes)))
        let ceiling = fragmentBytes / target + (fragmentBytes % target == 0 ? 0 : 1)
        return Int(min(Int64(maximumPieceBytes), max(Int64(minimumPieceBytes), ceiling)))
    }

    static func pieceCap(fragmentBytes: Int64, targetPieces: Int) -> Int {
        let target = min(Int64(max(1, targetPieces)), max(1, fragmentBytes / Int64(minimumPieceBytes)))
        let ceiling = fragmentBytes / target + (fragmentBytes % target == 0 ? 0 : 1)
        return Int(min(Int64(maximumPieceBytes), max(Int64(minimumPieceBytes), ceiling)))
    }

    static func pieceBytes(speed: Double?) -> Int {
        guard let speed, speed.isFinite, speed > 0 else { return 1024 * 1024 }
        let measured = min(Double(maximumPieceBytes), max(Double(minimumPieceBytes), speed * 0.6))
        return Int(measured)
    }

    static func updatedSpeed(previous: Double?, sample: Double) -> Double? {
        guard sample.isFinite, sample > 0 else { return previous }
        guard let previous, previous.isFinite, previous > 0 else { return sample }
        return 0.7 * previous + 0.3 * sample
    }

    static func forwardCapCeiling(totalCap: Int64) -> Int64 {
        guard totalCap > 0 else { return 0 }
        return (totalCap / 4) * 3 + ((totalCap % 4) * 3) / 4
    }

    static func byteBudget(totalCap: Int64, bytesPerSecond: Double, ahead: TimeInterval) -> Int64 {
        guard totalCap > 0, bytesPerSecond.isFinite, bytesPerSecond > 0,
              ahead.isFinite, ahead > 0 else { return 0 }
        let ceiling = forwardCapCeiling(totalCap: totalCap)
        let estimated = bytesPerSecond * ahead
        guard estimated.isFinite else { return ceiling }
        return Int64(min(Double(ceiling), estimated))
    }

    static func byteBudget(totalCap: Int64, rates: [Double], ahead: TimeInterval) -> Int64 {
        guard totalCap > 0, ahead.isFinite, ahead > 0,
              rates.contains(where: { $0.isFinite && $0 > 0 }) else { return 0 }
        let ceiling = forwardCapCeiling(totalCap: totalCap)
        var estimated = 0.0
        for rate in rates {
            let demand = rate.isFinite && rate > 0 ? rate * ahead : 0
            guard demand.isFinite else { return ceiling }
            estimated += max(Double(minimumTrackShareBytes), demand)
            if !estimated.isFinite || estimated >= Double(ceiling) { return ceiling }
        }
        return Int64(min(Double(ceiling), estimated))
    }

    static func trackShares(budget: Int64, rates: [Double], ahead: TimeInterval) -> [Int64] {
        guard budget > 0, !rates.isEmpty else { return Array(repeating: 0, count: rates.count) }
        let equalCap = budget / Int64(rates.count)
        let demands: [Double] = rates.map { rate in
            guard rate.isFinite, rate > 0, ahead.isFinite, ahead > 0 else { return 0 }
            let bytes = rate * ahead
            return bytes.isFinite ? bytes : Double(budget)
        }
        var shares: [Int64] = demands.map { demand in
            let floored = max(Double(minimumTrackShareBytes), demand)
            return max(0, min(equalCap, Int64(min(Double(equalCap), floored))))
        }
        var remaining = budget - shares.reduce(0, +)
        guard remaining > 0 else { return shares }
        let deficits = zip(demands, shares).map { max(0.0, $0 - Double($1)) }
        let totalDeficit = deficits.reduce(0, +)
        let weights = totalDeficit > 0 ? deficits : rates.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let totalWeight = weights.reduce(0, +)
        if totalWeight > 0 {
            let pool = remaining
            for index in shares.indices where weights[index] > 0 && remaining > 0 {
                let extra = min(remaining, Int64(Double(pool) * weights[index] / totalWeight))
                shares[index] += extra
                remaining -= extra
            }
        }
        if remaining > 0, let primary = weights.indices.max(by: { weights[$0] < weights[$1] }) {
            shares[primary] += remaining
        }
        return shares
    }

    static func firstMissingSpan(in range: Range<Int64>, heldRanges: [Range<Int64>]) -> Range<Int64>? {
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound else { return nil }
        var cursor = range.lowerBound
        for held in heldRanges {
            if held.upperBound <= cursor { continue }
            if held.lowerBound > cursor {
                return cursor..<min(held.lowerBound, range.upperBound)
            }
            cursor = max(cursor, held.upperBound)
            if cursor >= range.upperBound { return nil }
        }
        return cursor < range.upperBound ? cursor..<range.upperBound : nil
    }

    static func heldOverlapBytes(in range: Range<Int64>, heldRanges: [Range<Int64>]) -> Int64 {
        guard range.lowerBound < range.upperBound else { return 0 }
        return heldRanges.reduce(0) { total, held in
            let lower = max(range.lowerBound, held.lowerBound)
            let upper = min(range.upperBound, held.upperBound)
            return upper > lower ? total + (upper - lower) : total
        }
    }

    static func candidates(
        fragments: [Fragment], track: Int, cursor: Int64, window: Window
    ) -> [Candidate] {
        let (position, rate, ahead, byteBudget) = (window.position, window.rate, window.ahead, window.byteBudget)
        guard position.isFinite, rate.isFinite, rate > 0, ahead.isFinite, ahead > 0,
              byteBudget > 0, let current = fragments.lastIndex(where: { $0.range.lowerBound <= cursor }) else {
            return []
        }
        var result: [Candidate] = []
        var remaining = byteBudget
        if let tail = validCurrentTail(window.currentTail, in: fragments[current], remaining: remaining) {
            result.append(Candidate(track: track, fragment: fragments[current], claimRange: tail, deadline: 0))
            remaining -= tail.upperBound - tail.lowerBound
        }
        let horizon = position + ahead
        guard horizon.isFinite else { return result }
        for fragment in fragments.dropFirst(current + 1) {
            guard fragment.startSeconds.isFinite, fragment.durationSeconds.isFinite,
                  fragment.durationSeconds > 0, fragment.range.lowerBound >= 0,
                  fragment.range.upperBound > fragment.range.lowerBound else { continue }
            if fragment.startSeconds > horizon { break }
            guard let missing = firstMissingSpan(in: fragment.range, heldRanges: window.heldRanges) else {
                continue
            }
            let size = missing.upperBound - missing.lowerBound
            guard size <= remaining else { break }
            result.append(Candidate(
                track: track, fragment: fragment, claimRange: missing,
                deadline: max(0, fragment.startSeconds - position) / Double(rate)
            ))
            remaining -= size
        }
        return result
    }

    private static func validCurrentTail(
        _ tail: Range<Int64>?, in fragment: Fragment, remaining: Int64
    ) -> Range<Int64>? {
        guard let tail,
              tail.lowerBound >= fragment.range.lowerBound,
              tail.upperBound <= fragment.range.upperBound else { return nil }
        let bytes = tail.upperBound - tail.lowerBound
        guard bytes > 0, bytes <= remaining else { return nil }
        return tail
    }

    static func helperURLs(_ urls: [URL], primary: URL, now: Date = Date()) -> [URL] {
        _ = primary
        var hosts: Set<String> = []
        return urls.filter { url in
            guard let rawHost = url.host, !rawHost.isEmpty else { return false }
            let host = canonicalHost(rawHost)
            guard host.hasPrefix("upos-"),
                  host.hasSuffix(".bilivideo.com"), !host.contains("mcdn.bilivideo"),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  isFresh(url, now: now), hosts.insert(host).inserted else { return false }
            return true
        }
    }

    static func tier1Hosts(
        for helpers: [URL], primary: URL, verifiedAPIHosts: Set<String>
    ) -> Set<String> {
        let primaryHost = comparisonHost(primary)
        let primaryPath = primary.path
        let primaryQuery = primary.query
        var tier1: Set<String> = []
        for url in helpers {
            let host = comparisonHost(url)
            guard !host.isEmpty else { continue }
            if host == primaryHost || verifiedAPIHosts.contains(host)
                || url.path != primaryPath || url.query != primaryQuery {
                tier1.insert(host)
            }
        }
        return tier1
    }

    static func canonicalHost(_ raw: String) -> String {
        var host = raw.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func comparisonHost(_ url: URL) -> String {
        canonicalHost(url.host ?? "")
    }

    static func isFresh(_ url: URL, now: Date) -> Bool {
        let deadlines = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "deadline" } ?? []
        return deadlines.allSatisfy { item in
            guard let raw = item.value, let deadline = Double(raw), deadline.isFinite else { return false }
            return now.timeIntervalSince1970 < deadline - 30
        }
    }
}
