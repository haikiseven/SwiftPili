import Foundation

/// Bookkeeping for a cache that must not issue the same request twice.
///
/// Split out from the actor so the two rules that matter — cache by identity,
/// and coalesce concurrent lookups of one identity — are testable without a
/// network. A comment list is exactly the workload that breaks a naive cache:
/// twenty rows can reference the same video, and they all render in the same
/// frame, so a plain "check then fetch" issues twenty identical requests.
struct TitleLookupLedger: Sendable {
    /// What a caller should do about an identity right now.
    enum Action: Equatable, Sendable {
        /// Answer immediately from cache.
        case serve(String)
        /// This caller owns the fetch.
        case fetch
        /// Another caller is already fetching; await its result.
        case join
        /// Already tried and failed; do not retry in this session.
        case giveUp
    }

    private var titles: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

    /// `key` is the video's stable identity (`VideoID.queryParam`), so `av2` and
    /// `bvid=BV…` for the same video are still two keys — the API is the only
    /// thing that can relate them, and guessing would be worse than one extra
    /// lookup.
    mutating func request(_ key: String) -> Action {
        if let title = titles[key] { return .serve(title) }
        if inFlight.contains(key) { return .join }
        if failed.contains(key) { return .giveUp }
        inFlight.insert(key)
        return .fetch
    }

    mutating func store(_ title: String, for key: String) {
        inFlight.remove(key)
        guard !title.isEmpty else {
            // An empty title is not a title. Record the failure so the row does
            // not re-request forever, but never cache "" as an answer.
            failed.insert(key)
            return
        }
        titles[key] = title
    }

    mutating func noteFailure(for key: String) {
        inFlight.remove(key)
        failed.insert(key)
    }

    func cachedTitle(_ key: String) -> String? { titles[key] }
}

/// Resolves and caches video titles for links found in comments.
///
/// An actor because the ledger is shared across every comment row on screen and
/// the whole point is that concurrent requests for one identity collapse into a
/// single fetch.
actor BiliVideoTitleCache {
    static let shared = BiliVideoTitleCache()

    private var ledger = TitleLookupLedger()
    /// The one live fetch per identity, so joiners await the same value instead
    /// of starting their own.
    private var tasks: [String: Task<String?, Never>] = [:]

    /// Resolves the title, coalescing concurrent callers for the same video.
    ///
    /// Callers await this from a `.task`, never from `body`: the comment row
    /// renders its link immediately and the title arrives later, so the list
    /// never blocks on a lookup.
    func title(for id: VideoID) async -> String? {
        let key = id.queryParam
        switch ledger.request(key) {
        case .serve(let title):
            return title
        case .giveUp:
            return nil
        case .join:
            // Await the owner's task rather than starting a second fetch.
            guard let existing = tasks[key] else {
                // The owner finished between the ledger check and here; its
                // result is already stored.
                return ledger.cachedTitle(key)
            }
            return await existing.value
        case .fetch:
            let task = Task<String?, Never> { [weak self] in
                let fetched = try? await VideoAPI.getVideoInfo(id: id)
                await self?.finish(key: key, title: fetched?.title)
                return fetched?.title
            }
            tasks[key] = task
            let result = await task.value
            tasks[key] = nil
            return result
        }
    }

    private func finish(key: String, title: String?) {
        if let title, !title.isEmpty {
            ledger.store(title, for: key)
        } else {
            ledger.noteFailure(for: key)
        }
    }
}
