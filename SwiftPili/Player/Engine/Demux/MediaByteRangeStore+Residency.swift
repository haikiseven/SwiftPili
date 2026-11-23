import Foundation

private struct WeakResidentReceipt {
    weak var value: MediaByteRangeStore.ResidentValidity?
}

extension MediaByteRangeStore {
    final class ResidentValidity: @unchecked Sendable {
        let range: Range<Int64>
        fileprivate let incarnation: ResidentIncarnation
        fileprivate var valid = true

        fileprivate init(range: Range<Int64>, incarnation: ResidentIncarnation) {
            self.range = range
            self.incarnation = incarnation
        }

        var isValid: Bool { incarnation.isValid(self) }

        func narrowed(to range: Range<Int64>) -> ResidentValidity? {
            incarnation.narrow(self, to: range)
        }

        func sharesIncarnation(with other: ResidentValidity) -> Bool {
            incarnation === other.incarnation
        }
    }

    final class ResidentIncarnation: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private var receipts: [WeakResidentReceipt] = []

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

        func revoke(overlapping range: Range<Int64>) {
            lock.lock()
            defer { lock.unlock() }
            receipts.removeAll { registration in
                guard let receipt = registration.value else { return true }
                if receipt.range.overlaps(range) { receipt.valid = false }
                return !receipt.valid
            }
        }

        func revokeAll() {
            lock.lock()
            defer { lock.unlock() }
            active = false
            for registration in receipts { registration.value?.valid = false }
            receipts.removeAll()
        }

        private func register(_ range: Range<Int64>) -> ResidentValidity {
            receipts.removeAll { $0.value?.valid != true }
            let receipt = ResidentValidity(range: range, incarnation: self)
            receipts.append(WeakResidentReceipt(value: receipt))
            return receipt
        }
    }
}

extension MediaByteRangeStore {
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
}
