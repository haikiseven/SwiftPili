import Foundation
import Observation

/// Like/repost state behind DynamicCardView's action bar.
///
/// The like status and count a feed returns (module_stat) are only true
/// at fetch time, so a tap is applied locally first and rolled back if
/// the server refuses. Every screen that shows moment cards needs that
/// same optimistic layer — the Moments feed and the Moments tab of a
/// user's profile each carried their own copy of it before this.
///
/// `logTag` is the PlayerLog prefix of the owning screen, so a failure
/// still reads as coming from where the user tapped.
@MainActor
@Observable
final class MomentInteractionStore {
    /// Optimistic like state keyed by dynamic id, layered over module_stat.
    private(set) var likeOverrides: [String: (liked: Bool, count: Int)] = [:]

    private let logTag: String

    init(logTag: String) {
        self.logTag = logTag
    }

    /// Drops every optimistic edit — the owner replaced its list, so the
    /// server's fresh module_stat is authoritative again.
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
