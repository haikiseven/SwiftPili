import Foundation

/// Owns only source reservations. Synchronous release keeps the existing slot
/// mutation turn intact, including actor deinitialization and stale cleanup.
final class PathAByteSourceClaims: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [MediaByteRangeStore.ClaimToken: MediaByteRangeStore] = [:]

    func insert(_ token: MediaByteRangeStore.ClaimToken?, store: MediaByteRangeStore) {
        guard let token else { return }
        lock.lock()
        tokens[token] = store
        lock.unlock()
    }

    func release(_ token: MediaByteRangeStore.ClaimToken?) {
        guard let token else { return }
        lock.lock()
        let store = tokens.removeValue(forKey: token)
        lock.unlock()
        store?.release(token)
    }

    func releaseAll() {
        lock.lock()
        let held = tokens
        tokens.removeAll()
        lock.unlock()
        for (token, store) in held { store.release(token) }
    }

    deinit { releaseAll() }
}
