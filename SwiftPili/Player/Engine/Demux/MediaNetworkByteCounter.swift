import Foundation

final class MediaNetworkByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0

    init() {}

    var total: Int64 { lock.withLock { bytes } }

    func add(_ count: Int) {
        guard count > 0, let amount = Int64(exactly: count) else { return }
        lock.withLock {
            let (sum, overflow) = bytes.addingReportingOverflow(amount)
            bytes = overflow ? Int64.max : sum
        }
    }
}
