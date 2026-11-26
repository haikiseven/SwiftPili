import SwiftUI
import UIKit

enum UserSpaceSectionKey: Hashable, Sendable {
    case profileHeader, submissionFilter
    case shelfHeader(UserSpaceShelfKind)
    case shelfVideos, shelfMoments, shelfFavorites
    case videoGrid, posterGrid, list, footer
}

enum UserSpaceShelfKind: Hashable, Sendable { case submissions, moments, favorites }

enum UserSpaceCellKey: Hashable, Sendable {
    enum SkeletonKind: Hashable, Sendable { case video, poster, row, dynamic }
    case profileHeader, submissionFilter
    case shelfHeader(UserSpaceShelfKind)
    case video(String), dynamic(String)
    case bangumi(Int)
    case favoriteFolder(id: Int, showsDivider: Bool)
    case skeleton(SkeletonKind, Int)
    case paginationSpinner
    case feedback(UserSpaceFeedbackKind)
}

enum UserSpaceFeedbackKind: Hashable, Sendable {
    case homeFailed, homeEmpty, dynamicsFailed, dynamicsEmpty
    case videosFailed, videosEmpty, articlesFailed, articlesEmpty
    case coinsEmpty, likesEmpty, favoritesFailed, favoritesEmpty, bangumiEmpty
}

enum UserSpaceVideoAction { case video(VideoRouteTarget?), article(Int) }

@MainActor
struct UserSpaceFeedActions {
    let onRefresh: @MainActor () async -> Bool
    let onInlineTitleChange: (Bool) -> Void
    let onSelectVideo: (VideoRouteTarget) -> Void
    let onNavigate: (Route) -> Void
    let onOpenURL: (URL) -> Void
    let onPreviewImages: (ImagePreviewItem) -> Void
    let onCommentDynamic: (DynamicFeedResult.DynamicItem) -> Void
    let onRepostDynamic: (DynamicFeedResult.DynamicItem) -> Void
    let interactionStore: MomentInteractionStore
    let makeProfileHeader: (CGFloat) -> AnyView
    let makeSubmissionFilter: () -> AnyView
    let makeShelfHeader: (UserSpaceShelfKind) -> AnyView
    let makeFavoriteRow: (FavoriteFolderResult.FavoriteFolder, CGFloat, Bool) -> AnyView
    let makeFeedbackView: (UserSpaceFeedbackKind) -> AnyView
}

struct UserSpaceFeedTrigger: Equatable {
    let headerIdentityKey: String
    let selectedTab: UserSpaceTab
    let showsArticles: Bool
    let videoRevision, articleRevision, coinRevision, likeRevision: UInt64
    let bangumiRevision, favoriteRevision, dynamicRevision: UInt64
    let loadingMask: Int
    let coverPresentation: CoverPresentation

    @MainActor
    init(viewModel: UserSpaceViewModel, headerIdentityKey: String, coverPresentation: CoverPresentation) {
        self.headerIdentityKey = headerIdentityKey
        selectedTab = viewModel.selectedTab
        showsArticles = viewModel.showsArticles
        videoRevision = viewModel.videoRevision
        articleRevision = viewModel.articleRevision
        coinRevision = viewModel.coinRevision
        likeRevision = viewModel.likeRevision
        bangumiRevision = viewModel.bangumiRevision
        favoriteRevision = viewModel.favoriteRevision
        dynamicRevision = viewModel.dynamicRevision
        let flags = [
            viewModel.isLoadingVideos, viewModel.attemptedVideos, viewModel.videosLoadFailed, viewModel.videosHaveMore,
            viewModel.isLoadingArticles, viewModel.attemptedArticles, viewModel.articlesLoadFailed,
            viewModel.articlesHaveMore, viewModel.isLoadingDynamics, viewModel.attemptedDynamics,
            viewModel.dynamicsLoadFailed, viewModel.dynamicsHasMore, viewModel.isLoadingFavorites,
            viewModel.attemptedFavorites, viewModel.favoritesLoadFailed, viewModel.loadedCoins,
            viewModel.loadedLikes, viewModel.loadedBangumi
        ]
        var mask = viewModel.totalVideoCount ?? -1
        for (idx, flag) in flags.enumerated() where flag { mask ^= (1 << idx) }
        loadingMask = mask
        self.coverPresentation = coverPresentation
    }

    func hasVideoEntriesDifference(from previous: Self?) -> Bool {
        guard let previous else { return true }
        return videoRevision != previous.videoRevision
            || articleRevision != previous.articleRevision
            || coinRevision != previous.coinRevision
            || likeRevision != previous.likeRevision
            || coverPresentation != previous.coverPresentation
    }

    @MainActor
    func buildSections(
        viewModel: UserSpaceViewModel, videoCols: Int, posterCols: Int
    ) -> [(UserSpaceSectionKey, [UserSpaceCellKey])] {
        if viewModel.selectedTab == .home { return buildHomeSections(viewModel: viewModel, videoCols: videoCols) }
        var result: [(UserSpaceSectionKey, [UserSpaceCellKey])] =
            viewModel.selectedTab == .video ? [(.submissionFilter, [.submissionFilter])] : []
        let spec = currentTabSpec(viewModel: viewModel, videoCols: videoCols, posterCols: posterCols)
        if !spec.keys.isEmpty {
            result.append((spec.section, spec.keys))
            if spec.allowsSpinner && spec.isLoading { result.append((.footer, [.paginationSpinner])) }
        } else if !spec.attempted || spec.isLoading {
            result.append((spec.section, spec.skeletonKeys))
        } else {
            result.append((.footer, [.feedback(spec.failed ? spec.failedKind : spec.emptyKind)]))
        }
        return result
    }

    @MainActor
    private func buildHomeSections(
        viewModel: UserSpaceViewModel, videoCols: Int
    ) -> [(UserSpaceSectionKey, [UserSpaceCellKey])] {
        var list: [(UserSpaceSectionKey, [UserSpaceCellKey])] = []
        if !viewModel.userVideos.isEmpty {
            list.append((.shelfHeader(.submissions), [.shelfHeader(.submissions)]))
            let items = viewModel.userVideos.prefix(max(4, videoCols * 2)).map { UserSpaceCellKey.video("v:\($0.aid)") }
            list.append((.shelfVideos, items))
        }
        if !viewModel.userDynamics.isEmpty {
            list.append((.shelfHeader(.moments), [.shelfHeader(.moments)]))
            let items = viewModel.userDynamics.prefix(2)
                .map { UserSpaceCellKey.dynamic(DynamicsViewModel.stableItemID($0)) }
            list.append((.shelfMoments, items))
        }
        if !viewModel.userFavorites.isEmpty {
            list.append((.shelfHeader(.favorites), [.shelfHeader(.favorites)]))
            let items = viewModel.userFavorites.prefix(2)
                .map { UserSpaceCellKey.favoriteFolder(id: $0.id, showsDivider: false) }
            list.append((.shelfFavorites, items))
        }
        guard list.isEmpty else { return list }
        let loading = !viewModel.attemptedVideos || !viewModel.attemptedDynamics || !viewModel.attemptedFavorites
            || viewModel.isLoadingVideos || viewModel.isLoadingDynamics || viewModel.isLoadingFavorites
        if loading { return [(.videoGrid, (0..<max(4, videoCols * 2)).map { .skeleton(.video, $0) })] }
        let kind: UserSpaceFeedbackKind =
            (viewModel.videosLoadFailed || viewModel.dynamicsLoadFailed) ? .homeFailed : .homeEmpty
        return [(.footer, [.feedback(kind)])]
    }

    private struct TabSpec {
        let section: UserSpaceSectionKey
        let keys, skeletonKeys: [UserSpaceCellKey]
        let isLoading, attempted: Bool
        var failed = false
        var allowsSpinner = false
        let failedKind, emptyKind: UserSpaceFeedbackKind
    }
    @MainActor
    private func currentTabSpec(viewModel: UserSpaceViewModel, videoCols: Int, posterCols: Int) -> TabSpec {
        let videoSk = (0..<max(6, videoCols * 2)).map { UserSpaceCellKey.skeleton(.video, $0) }
        switch viewModel.selectedTab {
        case .dynamic:
            return TabSpec(
                section: .list, keys: viewModel.userDynamics.map { .dynamic(DynamicsViewModel.stableItemID($0)) },
                skeletonKeys: (0..<3).map { .skeleton(.dynamic, $0) }, isLoading: viewModel.isLoadingDynamics,
                attempted: viewModel.attemptedDynamics, failed: viewModel.dynamicsLoadFailed, allowsSpinner: true,
                failedKind: .dynamicsFailed, emptyKind: .dynamicsEmpty
            )
        case .video where viewModel.showsArticles:
            return TabSpec(
                section: .videoGrid, keys: viewModel.userArticles.map { .video("a:\($0.id)") },
                skeletonKeys: videoSk, isLoading: viewModel.isLoadingArticles, attempted: viewModel.attemptedArticles,
                failed: viewModel.articlesLoadFailed, allowsSpinner: true,
                failedKind: .articlesFailed, emptyKind: .articlesEmpty
            )
        case .video, .home:
            return TabSpec(
                section: .videoGrid, keys: viewModel.userVideos.map { .video("v:\($0.aid)") }, skeletonKeys: videoSk,
                isLoading: viewModel.isLoadingVideos, attempted: viewModel.attemptedVideos,
                failed: viewModel.videosLoadFailed, allowsSpinner: true,
                failedKind: .videosFailed, emptyKind: .videosEmpty
            )
        case .favorite:
            return TabSpec(
                section: .list, keys: viewModel.userFavorites.map { .favoriteFolder(id: $0.id, showsDivider: true) },
                skeletonKeys: (0..<3).map { .skeleton(.row, $0) }, isLoading: viewModel.isLoadingFavorites,
                attempted: viewModel.attemptedFavorites, failed: viewModel.favoritesLoadFailed,
                failedKind: .favoritesFailed, emptyKind: .favoritesEmpty
            )
        case .coins, .likes:
            let isCoins = viewModel.selectedTab == .coins
            let keys = (isCoins ? viewModel.userCoins : viewModel.userLikes)
                .map { UserSpaceCellKey.video("\(isCoins ? "c" : "l"):\($0.aid)") }
            let loaded = isCoins ? viewModel.loadedCoins : viewModel.loadedLikes
            let emptyKind: UserSpaceFeedbackKind = isCoins ? .coinsEmpty : .likesEmpty
            return TabSpec(
                section: .videoGrid, keys: keys, skeletonKeys: videoSk,
                isLoading: !loaded, attempted: loaded, failedKind: emptyKind, emptyKind: emptyKind
            )
        case .bangumi:
            return TabSpec(
                section: .posterGrid, keys: viewModel.userBangumi.map { .bangumi($0.seasonId) },
                skeletonKeys: (0..<max(6, posterCols * 2)).map { .skeleton(.poster, $0) },
                isLoading: !viewModel.loadedBangumi, attempted: viewModel.loadedBangumi,
                failedKind: .bangumiEmpty, emptyKind: .bangumiEmpty
            )
        }
    }

    @MainActor
    func buildVideoEntries(
        viewModel: UserSpaceViewModel, colWidth: CGFloat
    ) -> [String: (UIKitGridVideoCell.Model, UserSpaceVideoAction)] {
        var entries: [String: (UIKitGridVideoCell.Model, UserSpaceVideoAction)] = [:]
        func add(
            _ key: String, title: String, sources: VideoCoverSources, duration: Int = 0, durationText: String? = nil,
            owner: String = "", views: Int, publishedAt: Int? = nil, action: UserSpaceVideoAction
        ) {
            entries[key] = (
                UIKitGridVideoCell.Model(
                    title: title, sources: sources, duration: duration, durationText: durationText,
                    ownerName: owner, viewCount: views, publishedAt: publishedAt,
                    columnWidth: colWidth, coverPresentation: coverPresentation
                ),
                action
            )
        }
        for item in viewModel.userVideos {
            let pic = item.pic ?? ""
            let secs = FormatUtils.parseDurationSeconds(item.length)
            let target = VideoRouteTarget.make(
                bvid: item.bvid, aid: item.aid, title: item.title, coverURL: pic, durationSeconds: secs
            )
            add("v:\(item.aid)", title: item.title, sources: VideoCoverSources(widescreen: pic),
                durationText: item.length, views: item.play ?? 0, publishedAt: item.created, action: .video(target))
        }
        for item in viewModel.userArticles {
            let pic = item.bannerUrl ?? item.imageUrls?.first ?? ""
            add("a:\(item.id)", title: item.title ?? "", sources: .singleUnclassified(pic),
                views: item.stats?.view ?? 0, publishedAt: item.publishTime, action: .article(item.id))
        }
        for (prefix, list) in [("c", viewModel.userCoins), ("l", viewModel.userLikes)] {
            for item in list {
                let pic = item.pic ?? "", owner = item.owner?.name ?? ""
                let title = item.title ?? "", secs = item.duration ?? 0
                let target = VideoRouteTarget.make(
                    bvid: item.bvid, aid: item.aid, title: title, coverURL: pic, ownerName: owner, durationSeconds: secs
                )
                add("\(prefix):\(item.aid)", title: title, sources: VideoCoverSources(widescreen: pic),
                    duration: secs, owner: owner, views: item.stat?.view ?? 0, action: .video(target))
            }
        }
        return entries
    }
}

struct UserSpaceView: View {
    private struct TabLoadKey: Hashable {
        let mid: Int
        let identityRevision: UInt64
        let tab: UserSpaceTab
        let showsArticles: Bool
    }

    let mid: Int
    @State private var viewModel = UserSpaceViewModel()
    @State private var relation = UserSpaceRelationModel()
    @State private var showBlockConfirm = false
    @State private var showsInlineTitle = false
    @State private var previewImages: ImagePreviewItem?
    @State private var interactions = MomentInteractionStore(logTag: "UserSpace")
    @State private var commentTarget: DynamicFeedResult.DynamicItem?
    @State private var repostTarget: DynamicFeedResult.DynamicItem?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.contentLinkContext) private var contentLinkContext
    @Environment(\.openURL) private var openURL

    private var isOwnProfile: Bool { AuthManager.shared.dedeUserID.flatMap(Int.init) == mid }
    private var showsRelationControls: Bool { AuthManager.shared.isLoggedIn && !relation.isLoading && !isOwnProfile }
    private var isLocallyBlocked: Bool { LocalContentFilterStore.shared.isUPBlockedLocally(mid) }

    var body: some View {
        Group {
            if viewModel.headerLoadFailed {
                ScrollView {
                    MessageLoadFailureView(message: nil) { Task { await viewModel.retryHeader(mid: mid) } }
                        .frame(minHeight: 320)
                }
            } else {
                UserSpaceFeedCollectionView(
                    mid: mid, viewModel: viewModel, headerIdentityKey: headerIdentityKey, actions: makeFeedActions()
                )
            }
        }
        .appAmbientBrowseBackground()
        .navigationTitle(showsInlineTitle ? (viewModel.userInfo?.name ?? "") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !viewModel.headerLoadFailed { ToolbarItem(placement: .topBarTrailing) { moreMenu } } }
        .confirmationDialog("Add this user to your Bilibili blacklist?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Add to Bilibili Blacklist", role: .destructive) { relation.setBlocked(true, mid: mid) }
                .disabled(BlocklistManager.shared.isMutating(mid: mid))
        } message: {
            Text("Adding to your Bilibili account blacklist unfollows them on Bilibili and filters their content across the app.")
        }
        .task(id: UserSpaceViewModel.LoadIdentity.capture(mid: mid)) {
            await viewModel.loadIfNeeded(identity: .capture(mid: mid))
        }
        .task(id: UserSpaceRelationModel.LoadIdentity.capture(mid: mid)) { await relation.load(mid: mid) }
        .task(id: TabLoadKey(
            mid: mid, identityRevision: AccountManager.shared.identityRevision,
            tab: viewModel.selectedTab, showsArticles: viewModel.showsArticles
        )) { await loadActiveTabIfNeeded() }
        .imagePreview(item: $previewImages)
        .sheet(item: $commentTarget) { item in
            DynamicCommentSheet(item: item)
                .appAdaptiveSheet(padSizing: .page)
        }
        .sheet(item: $repostTarget) { item in
            RepostSheet(item: item) { text in await interactions.repost(item: item, content: text) }
        }
    }
    private var headerIdentityKey: String {
        "\(mid):\(viewModel.userInfo != nil):\(showsRelationControls):\(relation.isBlocked):\(relation.isFollowing):\(isLocallyBlocked)"
    }
    private var moreMenu: some View {
        Menu {
            Section {
                if let shareURL = URL(string: "https://space.bilibili.com/\(mid)") {
                    ShareLink(item: shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                Button { UIPasteboard.general.string = String(mid) } label: {
                    Label("Copy UID", systemImage: "doc.on.doc")
                }
            }
            if !isOwnProfile {
                Section("Local Filter") {
                    if isLocallyBlocked {
                        Button {
                            toggleLocalBlock(blocked: false)
                        } label: {
                            Label("Unblock Locally", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    } else {
                        Button(role: .destructive) {
                            toggleLocalBlock(blocked: true)
                        } label: {
                            Label("Locally Block This UP", systemImage: "person.slash")
                        }
                    }
                }
            }
            if AuthManager.shared.isLoggedIn, !isOwnProfile {
                Section("Bilibili Account") {
                    if relation.isBlocked {
                        Button { relation.setBlocked(false, mid: mid) } label: {
                            Label("Remove from Bilibili Blacklist", systemImage: "hand.raised.slash")
                        }.disabled(BlocklistManager.shared.isMutating(mid: mid))
                    } else {
                        Button(role: .destructive) { showBlockConfirm = true } label: {
                            Label("Add to Bilibili Blacklist", systemImage: "hand.raised")
                        }.disabled(BlocklistManager.shared.isMutating(mid: mid))
                    }
                }
            }
        } label: { Image(systemName: "ellipsis") }
            .tint(Color.primary)
            .accessibilityLabel(Text("More"))
    }

    private func toggleLocalBlock(blocked: Bool) {
        let store = LocalContentFilterStore.shared
        let rawName = viewModel.userInfo?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = rawName.isEmpty ? "UID \(mid)" : rawName
        let face = viewModel.userInfo?.face
        let targetMid = mid
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if blocked {
            store.blockUP(mid: targetMid, name: displayName, face: face)
            ContentFilterUndoToastCenter.shared.show(
                message: String(format: String(localized: "Locally blocked UP \"%@\""), displayName),
                systemImage: "person.slash"
            ) {
                store.unblockUP(mid: targetMid)
            }
        } else {
            store.unblockUP(mid: targetMid)
            ContentFilterUndoToastCenter.shared.show(
                message: String(format: String(localized: "Unblocked UP \"%@\" locally"), displayName),
                systemImage: "person.crop.circle.badge.checkmark"
            ) {
                store.blockUP(mid: targetMid, name: displayName, face: face)
            }
        }
    }
}

private extension UserSpaceView {
    func loadActiveTabIfNeeded() async {
        switch viewModel.selectedTab {
        case .dynamic: await viewModel.loadDynamicsIfNeeded(mid: mid)
        case .video where viewModel.showsArticles: await viewModel.loadArticlesIfNeeded(mid: mid)
        case .video: await viewModel.loadVideosIfNeeded(mid: mid)
        case .favorite: await viewModel.loadFavoritesIfNeeded(mid: mid)
        case .home, .coins, .likes, .bangumi: break
        }
    }

    func makeFeedActions() -> UserSpaceFeedActions {
        UserSpaceFeedActions(
            onRefresh: { await refreshSpace() },
            onInlineTitleChange: { showsInlineTitle = $0 },
            onSelectVideo: { _ = coordinator.navigateToVideo($0) },
            onNavigate: { coordinator.navigate(to: $0) },
            onOpenURL: { openContentLink($0) },
            onPreviewImages: { previewImages = $0 },
            onCommentDynamic: { openComment(for: $0) },
            onRepostDynamic: { repostTarget = $0 },
            interactionStore: interactions,
            makeProfileHeader: { inset in hostedSwiftUI { profileHeaderView(horizontalInset: inset) } },
            makeSubmissionFilter: {
                hostedSwiftUI { UserSpaceSubmissionFilter(showsArticles: Bindable(viewModel).showsArticles) }
            },
            makeShelfHeader: { kind in hostedSwiftUI { shelfHeader(for: kind) } },
            makeFavoriteRow: { folder, width, div in
                hostedSwiftUI { favoriteRowView(folder, seedWidth: width, showsDivider: div) }
            },
            makeFeedbackView: { kind in
                hostedSwiftUI { UserSpaceFeedbackView(kind: kind, mid: mid, viewModel: viewModel) }
            }
        )
    }

    func profileHeaderView(horizontalInset: CGFloat) -> some View {
        UserSpaceHostedHeaderView(
            mid: mid, viewModel: viewModel, relation: relation,
            showsRelationControls: showsRelationControls,
            isLocallyBlocked: !isOwnProfile && isLocallyBlocked,
            horizontalInset: horizontalInset,
            onUnblockLocally: { toggleLocalBlock(blocked: false) },
            openFollowing: { coordinator.navigate(to: .following(mid: mid)) },
            openFollowers: { coordinator.navigate(to: .followers(mid: mid)) }
        )
    }

    func favoriteRowView(
        _ folder: FavoriteFolderResult.FavoriteFolder, seedWidth: CGFloat, showsDivider: Bool
    ) -> some View {
        let inset = FeedColumnPolicy.horizontalMargin(for: seedWidth)
        return VStack(spacing: 0) {
            FavoriteFolderPreviewRow(
                folder: folder, seedWidth: seedWidth,
                cachedPreviews: viewModel.favoriteFolderPreviews[folder.id],
                onPreviewsLoaded: { viewModel.cacheFavoritePreviews($0, for: folder.id) }
            )
            if showsDivider { Divider().padding(.leading, inset) }
        }
    }

    func refreshSpace() async -> Bool {
        async let space: () = viewModel.refresh(mid: mid)
        async let rel: () = relation.load(mid: mid)
        _ = await (space, rel)
        return false
    }

    func openContentLink(_ url: URL) {
        guard BiliURLParser.handlesContent(url) else { openURL(url); return }
        _ = coordinator.openContentURL(url, context: contentLinkContext)
    }

    func openComment(for item: DynamicFeedResult.DynamicItem) {
        guard let postID = item.idStr, !postID.isEmpty else { commentTarget = item; return }
        coordinator.navigate(to: .momentDetail(postID))
    }

    @ViewBuilder
    func shelfHeader(for kind: UserSpaceShelfKind) -> some View {
        switch kind {
        case .submissions:
            let count = viewModel.totalVideoCount ?? viewModel.userVideos.count
            UserSpaceSectionHeader(title: "Submissions", count: count) { viewModel.selectedTab = .video }
        case .moments: UserSpaceSectionHeader(title: "Moments") { viewModel.selectedTab = .dynamic }
        case .favorites:
            let count = viewModel.userFavorites.count
            UserSpaceSectionHeader(title: "Favorites", count: count) { viewModel.selectedTab = .favorite }
        }
    }

    func hostedSwiftUI<Content: View>(@ViewBuilder _ content: () -> Content) -> AnyView {
        AnyView(
            content()
                .environment(coordinator)
                .environment(\.contentLinkContext, contentLinkContext)
                .environment(\.openURL, openURL)
                .contentLinks(presentsFeedback: false)
        )
    }
}

private struct UserSpaceHostedHeaderView: View {
    let mid: Int
    @Bindable var viewModel: UserSpaceViewModel
    let relation: UserSpaceRelationModel
    let showsRelationControls: Bool
    let isLocallyBlocked: Bool
    let horizontalInset: CGFloat
    let onUnblockLocally: () -> Void
    let openFollowing, openFollowers: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            UserSpaceProfileHeader(
                mid: mid, userInfo: viewModel.userInfo, showsRelationControls: showsRelationControls,
                isBlockedUser: relation.isBlocked, isLocallyBlocked: isLocallyBlocked,
                isFollowing: relation.isFollowing,
                followInFlight: relation.isFollowingInFlight || BlocklistManager.shared.isMutating(mid: mid),
                blockInFlight: BlocklistManager.shared.isMutating(mid: mid), accentColor: .biliAccent,
                following: viewModel.relationStat?.following ?? viewModel.userInfo?.cardFollowing,
                followers: viewModel.relationStat?.follower ?? viewModel.userInfo?.cardFollowers,
                likes: viewModel.upStat?.likes ?? viewModel.userInfo?.cardLikes,
                views: viewModel.upStat?.archive?.view, isLoadingStats: viewModel.isLoadingStats,
                horizontalPadding: horizontalInset,
                onToggleFollow: { relation.toggleFollow(mid: mid) },
                onUnblock: { relation.setBlocked(false, mid: mid) },
                onUnblockLocally: onUnblockLocally,
                openFollowing: openFollowing, openFollowers: openFollowers
            )
            UserSpaceTabSelector(
                tabs: viewModel.visibleTabs,
                selection: $viewModel.selectedTab,
                horizontalPadding: horizontalInset
            )
        }
    }
}

private struct UserSpaceFeedbackView: View {
    let kind: UserSpaceFeedbackKind
    let mid: Int
    let viewModel: UserSpaceViewModel
    var body: some View {
        switch kind {
        case .homeFailed: failure { await viewModel.retryHomeSections(mid: mid) }
        case .dynamicsFailed: failure { await viewModel.loadMoreDynamics(mid: mid) }
        case .videosFailed: failure { await viewModel.loadMoreVideos(mid: mid) }
        case .articlesFailed: failure { await viewModel.loadMoreArticles(mid: mid) }
        case .favoritesFailed: failure { await viewModel.retryFavorites(mid: mid) }
        default: ContentUnavailableView(emptySpec.0, systemImage: emptySpec.1).padding(.top, AppSpacing.xl)
        }
    }
    private var emptySpec: (LocalizedStringKey, String) {
        switch kind {
        case .homeEmpty: ("No Videos", "sparkles.rectangle.stack")
        case .dynamicsEmpty: ("No Moments", "text.bubble")
        case .coinsEmpty: ("No coined videos yet", "play.rectangle")
        case .likesEmpty: ("No liked videos yet", "play.rectangle")
        case .articlesEmpty: ("No Articles", "doc.richtext")
        case .favoritesEmpty: ("No Favorites", "star.slash")
        case .bangumiEmpty: ("No Anime Updates", "sparkles.tv")
        default: ("No Videos", "play.rectangle")
        }
    }
    private func failure(_ retry: @escaping @Sendable () async -> Void) -> some View {
        MessageLoadFailureView(message: nil) { Task { await retry() } }.padding(.top, AppSpacing.xl)
    }
}
