import Foundation

struct TitleLookupLedger: Sendable {
    enum Action: Equatable, Sendable {
        case serve(String)
        case fetch
        case join
        case giveUp
    }

    private var titles: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

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

actor BiliVideoTitleCache {
    static let shared = BiliVideoTitleCache()

    private var ledger = TitleLookupLedger()
    private var tasks: [String: Task<String?, Never>] = [:]

    func title(for id: VideoID) async -> String? {
        let key = id.queryParam
        switch ledger.request(key) {
        case .serve(let title):
            return title
        case .giveUp:
            return nil
        case .join:
            guard let existing = tasks[key] else {
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
