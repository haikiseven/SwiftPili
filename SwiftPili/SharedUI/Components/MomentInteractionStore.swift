import Foundation
import Observation

@MainActor
@Observable
final class MomentInteractionStore {
    private(set) var likeOverrides: [String: (liked: Bool, count: Int)] = [:]

    private let logTag: String

    init(logTag: String) {
        self.logTag = logTag
    }

    func reset() {
        likeOverrides = [:]
    }

    func likeState(for item: DynamicFeedResult.DynamicItem) -> (liked: Bool, count: Int) {
        if let override = likeOverrides[item.id] { return override }
        let stat = item.modules?.moduleStat?.like
        return (stat?.status ?? false, stat?.count ?? 0)
    }

    func toggleLike(for item: DynamicFeedResult.DynamicItem) async {
        guard let dynamicId = item.idStr else { return }
        let current = likeState(for: item)
        let next = (liked: !current.liked, count: max(0, current.count + (current.liked ? -1 : 1)))
        likeOverrides[item.id] = next
        do {
            _ = try await DynamicAPI.likeDynamic(dynamicId: dynamicId, up: next.liked ? 1 : 2)
        } catch {
            PlayerLog.log("[\(logTag)] like failed: \(error)")
            likeOverrides[item.id] = current
            if !Task.isCancelled, !BiliAPIRetryPolicy.isCancellation(error), !error.isCancellation {
                AppNoticeCenter.shared.showError(String(localized: "Like failed"))
            }
        }
    }

    func repost(item: DynamicFeedResult.DynamicItem, content: String) async -> Bool {
        guard let dynamicId = item.idStr else { return false }
        do {
            _ = try await DynamicAPI.repostDynamic(dynamicId: dynamicId, content: content)
            return true
        } catch {
            PlayerLog.log("[\(logTag)] repost failed: \(error)")
            return false
        }
    }
}
