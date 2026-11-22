import SwiftUI
import UIKit

enum HomeFeedItemIdentifier: Hashable, Sendable {
    case int(Int)
    case string(String)
    case uuid(UUID)
    case custom(String)

    init<ID: Hashable>(_ id: ID) {
        if let value = id as? Int {
            self = .int(value)
        } else if let value = id as? String {
            self = .string(value)
        } else if let value = id as? UUID {
            self = .uuid(value)
        } else {
            self = .custom(String(reflecting: id))
        }
    }
}

struct HomeFeedItemData: Identifiable, Equatable, Sendable {
    let id: HomeFeedItemIdentifier
    let title: String
    let sources: VideoCoverSources
    let duration: Int
    let ownerName: String
    let viewCount: Int
    var rank: Int?
    let routeTarget: VideoRouteTarget?
}

typealias HomeFeedSectionData = VideoFeedSection<HomeFeedItemData>

@MainActor
struct HomeFeedConfiguration {
    let sections: [HomeFeedSectionData]
    let layoutMode: HomeLayoutMode
    let coverPresentation: CoverPresentation
    let placeholderCount: Int
    let placeholderLabel: String
    let heroBadge: String
    let isActive: Bool
    let isHomeTabSelected: Bool
    let scrollToTopTick: Int
    let onRefresh: @MainActor () async -> Bool
    let onLastAppear: () -> Void
    let onSelectVideo: (VideoRouteTarget) -> Void
}

enum HomeFeedSectionKey: Hashable, Sendable {
    case hero
    case feed(UInt64)
    case skeletonHero
    case skeletonCards
}

enum HomeFeedCellKey: Hashable, Sendable {
    case hero(HomeFeedItemIdentifier)
    case gridCard(HomeFeedItemIdentifier)
    case rowCard(HomeFeedItemIdentifier)
    case skeletonHero
    case skeletonGrid(Int)
    case skeletonRow(Int)
}

enum HomeHeroLayoutMetrics {
    static let heroToFeedSpacing: CGFloat = 14
    static let heroWideCoverFraction: CGFloat = 0.62
    static let heroWideTextFraction: CGFloat = 0.42
}
