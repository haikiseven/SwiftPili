import Foundation

/// These are the existing Home request partitions, not a second admission policy.
enum HomeFeedKey: Hashable, Sendable {
    case recommended
    case popular
    case ranking
    case pgc(Int)
    case followed(Int)
}

/// Receipt identity distinguishes consecutive failures at the same cursor.
struct HomeFeedFailure: Equatable, Sendable {
    let receipt = UUID()
    let key: HomeFeedKey
    let token: FeedLoadToken
    let message: String
}

/// Content stays in HomeViewModel. Loading is projected from current admission.
struct HomeFeedFeedback: Equatable {
    var isLoading = false
    var hasSucceeded = false
    var failure: HomeFeedFailure?

    /// First content has not arrived and nothing failed: the list draws its
    /// layout-shaped placeholder (including the frame before the first load
    /// starts, so the screen is never blank). Not shown over existing content.
    func showsPlaceholder(hasContent: Bool) -> Bool {
        !hasContent && failure == nil && (isLoading || !hasSucceeded)
    }
}
