import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class PlayerPortraitFullscreenContext {
    let ownerLease: PlayerOwnerLease
    var title: String = ""
    var upMid: Int = 0
    var upName: String = ""
    var upAvatarURL: String = ""
    var isFollowing: Bool? = nil
    var isLiked: Bool = false
    var likeCount: Int = 0
    var isCoined: Bool = false
    var coinCount: Int = 0
    var canGiveTwoCoins: Bool = true
    var isFavorited: Bool = false
    var favoriteCount: Int = 0
    var replyCount: Int = 0
    var shareCount: Int = 0
    var commentsClosed: Bool = false
    var bvid: String = ""
    var aid: Int = 0
    var isInRouteImmersiveStage: Bool = false
    var summaryBadgeText: String? = nil
    var descriptionPreview: String? = nil
    var statsSummary: String? = nil
    var hasExpandableDetails: Bool = false

    nonisolated static func normalizedDescriptionPreview(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed != "-" else { return nil }
        return collapsed
    }

    var onBackToFeed: (@MainActor () -> Void)?
    var onCollapseToDetail: (@MainActor () -> Void)?
    var onSwipeUpToDetailComments: (@MainActor () -> Void)?
    var onTapOwner: (@MainActor () -> Void)?
    var onToggleFollow: (@MainActor () async -> Void)?
    var onToggleLike: (@MainActor () async -> Void)?
    var onDoubleTapLike: (@MainActor () async -> Void)?
    var onTripleCombo: (@MainActor () async -> Bool)?
    var onGiveCoin: (@MainActor (Int) async -> Void)?
    var onRequestFavoriteSheet: (@MainActor () async -> [FavoriteFolderResult.FavoriteFolder])?
    var onCommitFavoriteFolders: (@MainActor (Set<Int>) async -> Void)?
    var onRecordShare: (@MainActor () async -> Void)?
    var makeShareSheetView: (@MainActor () -> AnyView)?
    var onRequestLogin: (@MainActor () -> Void)?
    var makeCommentsSheetView: (@MainActor () -> AnyView)?
    var onOpenDetailsSheet: (@MainActor () -> Void)?
    var makeDetailsSheetView: (@MainActor () -> AnyView)?

    init(ownerLease: PlayerOwnerLease) {
        self.ownerLease = ownerLease
    }
}

/// UI chrome, layout framing, and ambient presentation state isolated from playback clock ticks.
@MainActor
@Observable
final class PlayerChromeState {
    var showControls = true
    var isFullscreen = false
    var isPortraitContent = false
    var videoAspectRatio: CGFloat? = nil
    var portraitPureViewEnabled: Bool = false
    var portraitFullscreenContext: PlayerPortraitFullscreenContext? = nil
    var isInlinePortraitImmersiveActive: Bool = false
    @ObservationIgnored
    var onRequestInlinePortraitImmersive: (@MainActor (Bool) -> Bool)? = nil
    var inlineCondensed = false
    var portraitCondenseLocked = false
    var showStats = false

    var ambientModeEnabled = PlayerPlaybackPreferences.ambientModeEnabled
    var ambientCoverURL: String?
    @ObservationIgnored
    var ambientOwnerLease: PlayerOwnerLease?
    var ambientStoryboard: [PlayerAmbientStoryboardFrame] = []
    @ObservationIgnored
    var ambientStoryboardOwnerLease: PlayerOwnerLease?
    @ObservationIgnored
    var ambientStoryboardLoadGeneration: Int?
    @ObservationIgnored
    var ambientStoryboardContent: PlayerAmbientStoryboardLoader.Content?
    @ObservationIgnored
    var ambientSelectionMediaTime: TimeInterval?
    @ObservationIgnored
    var ambientSelectionContent: PlayerAmbientStoryboardLoader.Content?
    var ambientSelectionSource: PlayerAmbientSource?
    var ambientVideoLoadedOwner: PlayerOwnerLease?
    var ambientLiveImage: UIImage?
    var ambientLiveFrameSerial: UInt64 = 0
    @ObservationIgnored
    var lastAmbientLiveSampleWall: TimeInterval = 0
    @ObservationIgnored
    let ambientStoryboardLoader = PlayerAmbientStoryboardLoader()
    @ObservationIgnored
    var ambientStoryboardRequest: PlayerAmbientStoryboardLoader.Request?

    @ObservationIgnored
    var hideControlsTask: Task<Void, Never>?
    var danmakuSettingsHold = false
    var fullscreenDanmakuComposerPresented = false
}
