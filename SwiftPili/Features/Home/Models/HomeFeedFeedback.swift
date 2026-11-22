import Foundation

enum HomeFeedKey: Hashable, Sendable {
    case recommended
    case popular
    case ranking
    case pgc(Int)
    case followed(Int)
}

struct HomeFeedFailure: Equatable, Sendable {
    let receipt = UUID()
    let key: HomeFeedKey
    let token: FeedLoadToken
    let message: String
}

struct HomeFeedFeedback: Equatable {
    var isLoading = false
    var hasSucceeded = false
    var failure: HomeFeedFailure?

    func showsPlaceholder(hasContent: Bool) -> Bool {
        !hasContent && failure == nil && (isLoading || !hasSucceeded)
    }
}
