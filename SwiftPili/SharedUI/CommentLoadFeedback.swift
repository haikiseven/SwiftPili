import Foundation

/// Presentation facts written only by a host's current comment request owner.
/// This value does not admit requests or identify a source.
struct CommentLoadFeedback: Equatable, Sendable {
    enum Failure: Equatable, Sendable {
        case initial, refresh, pagination
    }

    private(set) var hasLoaded = false
    private(set) var failure: Failure?

    mutating func started() {
        failure = nil
    }

    mutating func succeeded() {
        hasLoaded = true
        failure = nil
    }

    mutating func failed(page: Int) {
        failure = page > 1 ? .pagination : (hasLoaded ? .refresh : .initial)
    }
}
