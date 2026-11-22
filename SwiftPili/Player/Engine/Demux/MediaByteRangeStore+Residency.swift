import Foundation

private struct WeakResidentReceipt {
    weak var value: MediaByteRangeStore.ResidentValidity?
}

extension MediaByteRangeStore {
    /// A live receipt for one immutable byte range. It owns no payload, and its
    /// incarnation never changes, even if the same bytes are later readmitted.
    final class ResidentValidity: @unchecked Sendable {
        let range: Range<Int64>
        fileprivate let incarnation: ResidentIncarnation
        // Read and written only with the incarnation's lock held.
        fileprivate var valid = true

        fileprivate init(range: Range<Int64>, incarnation: ResidentIncarnation) {
            self.range = range
            self.incarnation = incarnation
        }

        var isValid: Bool { incarnation.isValid(self) }

        /// The independently registered subset survives removal outside it.
        /// An invalid parent cannot grant a subset, and no grant can widen it.
        func narrowed(to range: Range<Int64>) -> ResidentValidity? {
            incarnation.narrow(self, to: range)
        }

        func sharesIncarnation(with other: ResidentValidity) -> Bool {
            incarnation === other.incarnation
        }
    }

    /// One immutable resource incarnation. Only live receipt owners retain
    /// history; the registry stores weak references and prunes on each grant or
    /// removal. The lock protects only receipt state, never bytes or callbacks.
    final class ResidentIncarnation: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private var receipts: [WeakResidentReceipt] = []

        /// Called by the store in the same actor turn that proves coverage.
        func issue(for range: Range<Int64>) -> ResidentValidity? {
            lock.lock()
            defer { lock.unlock() }
            guard active, range.lowerBound >= 0, !range.isEmpty else { return nil }
            return register(range)
        }

        fileprivate func isValid(_ receipt: ResidentValidity) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return active && receipt.valid
        }

        fileprivate func narrow(_ receipt: ResidentValidity, to range: Range<Int64>) -> ResidentValidity? {
            lock.lock()
            defer { lock.unlock() }
            guard active, receipt.valid, !range.isEmpty,
                  range.lowerBound >= receipt.range.lowerBound,
                  range.upperBound <= receipt.range.upperBound else { return nil }
            return register(range)
        }

        /// Revoke before the corresponding held bytes or counters are changed.
        func revoke(overlapping range: Range<Int64>) {
            lock.lock()
            defer { lock.unlock() }
            receipts.removeAll { registration in
                guard let receipt = registration.value else { return true }
                if receipt.range.overlaps(range) { receipt.valid = false }
                return !receipt.valid
            }
        }

        /// Resource replacement and complete retirement are irreversible.
        func revokeAll() {
            lock.lock()
            defer { lock.unlock() }
            active = false
            for registration in receipts { registration.value?.valid = false }
            receipts.removeAll()
        }

        /// Caller holds the lock and has checked active/current parent state.
        private func register(_ range: Range<Int64>) -> ResidentValidity {
            receipts.removeAll { $0.value?.valid != true }
            let receipt = ResidentValidity(range: range, incarnation: self)
            receipts.append(WeakResidentReceipt(value: receipt))
            return receipt
        }
    }
}

/// Coalesced residency notifications and cache-only display reads.
extension MediaByteRangeStore {
    /// One coalesced wake, not a byte/time snapshot or an ownership receipt.
    /// Finishing the observation releases its exact store registration.
    final class ResidentChanges: Sendable {
        let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init(stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation) {
            self.stream = stream
            self.continuation = continuation
        }

        func requestRefresh() { continuation.yield(()) }
        func finish() { continuation.finish() }
        deinit { continuation.finish() }
    }

    struct ResidentObserver {
        let paths: Set<String>
        let continuation: AsyncStream<Void>.Continuation
    }

    /// Registration and initial replay share one store turn, so cached bytes
    /// present before observation cannot wait forever for a later admission.
    func observeResidentChanges(for keys: Set<Key>) -> ResidentChanges {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        residentObservers[id] = ResidentObserver(paths: Set(keys.map(\.path)), continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeResidentObserver(id) }
        }
        let observation = ResidentChanges(stream: stream, continuation: continuation)
        observation.requestRefresh()
        return observation
    }

    private func removeResidentObserver(_ id: UUID) {
        residentObservers[id] = nil
    }

    func notifyResidentChange(at path: String) {
        for observer in residentObservers.values where observer.paths.contains(path) {
            observer.continuation.yield(())
        }
    }

    /// Inspection and ownership receipts share the exact current incarnation.
    /// No source read, claim, network request or reader/index mutation occurs.
    func displayPrefix(_ key: Key, offset: Int64, count: Int) -> (Data, ResidentValidity)? {
        guard count > 0, let entry = entry(for: key),
              let data = entry.copyPrefix(offset: offset, count: count),
              let end = MediaByteRange.checkedEndExclusive(offset: offset, length: Int64(data.count)),
              let receipt = entry.residentIncarnation.issue(for: offset..<end) else { return nil }
        return (data, receipt)
    }

    func displayResidentSpans(_ key: Key, ranges: [Range<Int64>]) -> [ResidentValidity] {
        guard let entry = entry(for: key) else { return [] }
        let held = entry.coalescedRanges
        return ranges.flatMap { wanted in
            held.compactMap { available in
                let start = max(wanted.lowerBound, available.lowerBound)
                let end = min(wanted.upperBound, available.upperBound)
                return start < end ? entry.residentIncarnation.issue(for: start..<end) : nil
            }
        }
    }

}
