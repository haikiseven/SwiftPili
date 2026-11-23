import SwiftUI

enum HomeSection: String, CaseIterable {
    case recommend = "Recommend"
    case popular = "Popular"
    case ranking = "Ranking"
    case anime = "Anime"
    case movies = "Movies"

    var title: String {
        switch self {
        case .recommend: String(localized: "Recommend")
        case .popular: String(localized: "Popular")
        case .ranking: String(localized: "Ranking")
        case .anime: String(localized: "Anime")
        case .movies: String(localized: "Movies")
        }
    }

    var icon: String {
        switch self {
        case .recommend: "sparkles"
        case .popular: "flame"
        case .ranking: "chart.bar"
        case .anime: "sparkles.tv"
        case .movies: "film"
        }
    }
}

struct HomeView: View {
    @State private var selectedSection: HomeSection = .recommend
    @State private var visitedSections: [HomeSection] = [.recommend]
    @State private var recentSections: [HomeSection] = [.recommend]
    @State private var viewModel = HomeViewModel()
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let maxVisitedSections = 3
    private var usesRegularChrome: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            homeHeaderBar
            sectionContent
        }
        .appAmbientBrowseBackground()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(usesRegularChrome ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if usesRegularChrome, AuthManager.shared.isLoggedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        coordinator.navigate(to: .messages)
                    } label: {
                        Image(systemName: "bell")
                    }
                    .tint(Color.primary)
                    .accessibilityLabel(Text("Messages"))
                }
            }
        }
        .background {
            HomePopularPreloader(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var homeHeaderBar: some View {
        if usesRegularChrome {
            HomeSectionPillBar(
                selection: selectedSection,
                onSelect: selectSection
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.l)
            .padding(.vertical, AppSpacing.xs)
        } else {
            HStack(spacing: 10) {
                HomeSectionPillBar(
                    selection: selectedSection,
                    onSelect: selectSection
                )
                Spacer(minLength: 0)
                if AuthManager.shared.isLoggedIn {
                    AppTopBarCircleButton(systemImage: "bell", accessibilityLabel: "Messages") {
                        coordinator.navigate(to: .messages)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func selectSection(_ newSection: HomeSection) {
        recentSections.removeAll { $0 == newSection }
        recentSections.append(newSection)
        if !visitedSections.contains(newSection) {
            visitedSections.append(newSection)
            if visitedSections.count > Self.maxVisitedSections,
               let evictTarget = recentSections.first(where: { $0 != newSection && $0 != .recommend }) {
                visitedSections.removeAll { $0 == evictTarget }
                recentSections.removeAll { $0 == evictTarget }
            }
        }
        selectedSection = newSection
    }

    private var sectionContent: some View {
        ZStack {
            ForEach(HomeSection.allCases, id: \.self) { section in
                if visitedSections.contains(section) {
                    let isSelected = selectedSection == section
                    HomeSectionTabContainer(
                        section: section,
                        isSelected: isSelected,
                        viewModel: viewModel,
                        coordinator: coordinator
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
                }
            }
        }
        .transaction { $0.animation = nil }
    }
}

private struct HomePopularPreloader: View {
    let viewModel: HomeViewModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: viewModel.feedback(for: .recommended).hasSucceeded) {
                await preloadPopularIfIdle()
            }
    }

    private func preloadPopularIfIdle() async {
        guard viewModel.feedback(for: .recommended).hasSucceeded,
              viewModel.popularItems.isEmpty else { return }
        let popularFeedback = viewModel.feedback(for: .popular)
        guard !popularFeedback.hasSucceeded, !popularFeedback.isLoading, popularFeedback.failure == nil else {
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, viewModel.popularItems.isEmpty else { return }
        await viewModel.loadPopular()
    }
}

private struct HomeSectionTabContainer: View, Equatable {
    let section: HomeSection
    let isSelected: Bool
    let viewModel: HomeViewModel
    let coordinator: AppCoordinator

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section == rhs.section
            && lhs.isSelected == rhs.isSelected
            && lhs.viewModel === rhs.viewModel
            && lhs.coordinator === rhs.coordinator
    }

    @ViewBuilder
    var body: some View {
        switch section {
        case .recommend:
            RecommendedListView(viewModel: viewModel, coordinator: coordinator, isSelected: isSelected)
                .imageDiagnosticsScreen("Home.Recommended")
                .imageDiagnosticsScrollTracking()
        case .popular:
            PopularListView(viewModel: viewModel, coordinator: coordinator, isSelected: isSelected)
                .imageDiagnosticsScreen("Home.Popular")
                .imageDiagnosticsScrollTracking()
        case .ranking:
            RankingListView(viewModel: viewModel, coordinator: coordinator, isSelected: isSelected)
                .imageDiagnosticsScreen("Home.Ranking")
                .imageDiagnosticsScrollTracking()
        case .anime:
            PGCListView(viewModel: viewModel, coordinator: coordinator, indexType: 1, isSelected: isSelected)
                .imageDiagnosticsScreen("Home.Anime")
                .imageDiagnosticsScrollTracking()
        case .movies:
            PGCListView(viewModel: viewModel, coordinator: coordinator, indexType: 2, isSelected: isSelected)
                .imageDiagnosticsScreen("Home.Movies")
                .imageDiagnosticsScrollTracking()
        }
    }
}

private struct HomeFeedRenderKey: Equatable {
    let itemIDs: [Int]
    let generationIDs: [UInt64]
    let generationCounts: [Int]
    let placeholderCount: Int
    let isActive: Bool
    let isHomeTabSelected: Bool
    let scrollToTopTick: Int
    let layoutRaw: String
    let coverPresentation: CoverPresentation
}

private struct EquatableHomeFeedHost<Content: View>: View, Equatable {
    let key: HomeFeedRenderKey
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View {
        content()
    }
}

enum HomeFeedPlaceholder {
    static let count = 12
}

@MainActor
private final class RecommendedTabCache {
    struct Snapshot {
        let items: [RecommendResult.RecommendItem]
        let generations: [RecommendationFeed.Generation]
        let itemIDs: [Int]
        let generationIDs: [UInt64]
        let generationCounts: [Int]
        let feedback: HomeFeedFeedback
    }

    var snapshot = Snapshot(
        items: [], generations: [], itemIDs: [], generationIDs: [],
        generationCounts: [], feedback: HomeFeedFeedback()
    )

    func sync(from viewModel: HomeViewModel) -> Snapshot {
        let items = viewModel.recommendedItems
        let generations = viewModel.recommendationFeed.generations
        let feedback = viewModel.feedback(for: .recommended)
        let genIDs = generations.map(\.id)
        let genCounts = generations.map(\.items.count)
        let itemsUnchanged = items.count == snapshot.items.count
            && genIDs == snapshot.generationIDs
            && genCounts == snapshot.generationCounts
            && items.first?.id == snapshot.items.first?.id
            && items.last?.id == snapshot.items.last?.id
        let itemIDs = itemsUnchanged ? snapshot.itemIDs : items.map(\.id)
        snapshot = Snapshot(
            items: items, generations: generations, itemIDs: itemIDs,
            generationIDs: genIDs, generationCounts: genCounts, feedback: feedback
        )
        return snapshot
    }
}

private struct RecommendedListView: View {
    let viewModel: HomeViewModel
    let coordinator: AppCoordinator
    let isSelected: Bool

    @State private var cache = RecommendedTabCache()
    @AppStorage(HomeLayoutMode.storageKey) private var layoutRaw = HomeLayoutMode.grid.rawValue

    var body: some View {
        let snap = isSelected ? cache.sync(from: viewModel) : cache.snapshot
        let hasContent = !snap.items.isEmpty
        let title = String(localized: "Recommend")
        let placeholderCount = snap.feedback.showsPlaceholder(hasContent: hasContent)
            ? HomeFeedPlaceholder.count : 0
        let renderKey = HomeFeedRenderKey(
            itemIDs: snap.itemIDs,
            generationIDs: snap.generationIDs,
            generationCounts: snap.generationCounts,
            placeholderCount: placeholderCount,
            isActive: isSelected,
            isHomeTabSelected: coordinator.selectedTab == .home,
            scrollToTopTick: coordinator.scrollToTopTick,
            layoutRaw: layoutRaw,
            coverPresentation: CoverPresentationStore.shared.presentation
        )

        HomeFeedSurfaceContainer(
            feedback: snap.feedback,
            hasContent: hasContent,
            title: title,
            onRetry: { failure in Task { await viewModel.retry(failure) } },
            content: {
                EquatableHomeFeedHost(key: renderKey) {
                    HomeFeedCollectionView(
                        items: snap.items,
                        sections: snap.generations,
                        title: \.title,
                        sources: { VideoCoverSources(widescreen: $0.pic, fourByThree: $0.mobileCoverURL) },
                        duration: { $0.duration ?? 0 },
                        ownerName: { $0.owner?.name ?? "" },
                        viewCount: { $0.stat?.view ?? 0 },
                        routeTarget: Self.routeTarget,
                        placeholderCount: placeholderCount,
                        placeholderLabel: String(format: String(localized: "Loading %@"), title),
                        heroBadge: title,
                        isActive: renderKey.isActive,
                        isHomeTabSelected: renderKey.isHomeTabSelected,
                        scrollToTopTick: renderKey.scrollToTopTick,
                        onRefresh: {
                            let result = await viewModel.refresh()
                            guard case .published = result else { return false }
                            return true
                        },
                        onLastAppear: {
                            Task { await viewModel.loadRecommended() }
                        },
                        onSelectVideo: { target in
                            coordinator.navigateToVideo(target)
                        }
                    )
                }
            }
        )
        .task {
            FeedPerformanceSignposts.screenAdmission(.home)
            if viewModel.recommendedItems.isEmpty {
                await viewModel.loadRecommended()
            }
        }
    }

    private static func routeTarget(_ item: RecommendResult.RecommendItem) -> VideoRouteTarget? {
        .make(
            bvid: item.bvid,
            aid: nil,
            title: item.title,
            coverURL: item.pic,
            mobileCoverURL: item.mobileCoverURL,
            ownerName: item.owner?.name ?? "",
            durationSeconds: item.duration ?? 0
        )
    }
}

@MainActor
private final class PopularTabCache {
    struct Snapshot {
        let items: [VideoCard]
        let itemIDs: [Int]
        let feedback: HomeFeedFeedback
    }

    var snapshot = Snapshot(items: [], itemIDs: [], feedback: HomeFeedFeedback())

    func sync(from viewModel: HomeViewModel) -> Snapshot {
        let items = viewModel.popularItems
        let feedback = viewModel.feedback(for: .popular)
        let unchanged = items.count == snapshot.items.count
            && items.first?.id == snapshot.items.first?.id
            && items.last?.id == snapshot.items.last?.id
        let itemIDs = unchanged ? snapshot.itemIDs : items.map(\.id)
        snapshot = Snapshot(items: items, itemIDs: itemIDs, feedback: feedback)
        return snapshot
    }
}

private struct PopularListView: View {
    let viewModel: HomeViewModel
    let coordinator: AppCoordinator
    let isSelected: Bool

    @State private var cache = PopularTabCache()
    @AppStorage(HomeLayoutMode.storageKey) private var layoutRaw = HomeLayoutMode.grid.rawValue

    var body: some View {
        let snap = isSelected ? cache.sync(from: viewModel) : cache.snapshot
        let hasContent = !snap.items.isEmpty
        let title = String(localized: "Popular")
        let placeholderCount = snap.feedback.showsPlaceholder(hasContent: hasContent)
            ? HomeFeedPlaceholder.count : 0
        let renderKey = HomeFeedRenderKey(
            itemIDs: snap.itemIDs,
            generationIDs: [],
            generationCounts: [],
            placeholderCount: placeholderCount,
            isActive: isSelected,
            isHomeTabSelected: coordinator.selectedTab == .home,
            scrollToTopTick: coordinator.scrollToTopTick,
            layoutRaw: layoutRaw,
            coverPresentation: CoverPresentationStore.shared.presentation
        )

        HomeFeedSurfaceContainer(
            feedback: snap.feedback,
            hasContent: hasContent,
            title: title,
            onRetry: { failure in Task { await viewModel.retry(failure) } },
            content: {
                EquatableHomeFeedHost(key: renderKey) {
                    HomeFeedCollectionView(
                        items: snap.items,
                        title: \.title,
                        sources: { VideoCoverSources(widescreen: $0.pic, fourByThree: $0.mobileCoverURL) },
                        duration: \.duration,
                        ownerName: { $0.owner.name },
                        viewCount: { $0.stat.view },
                        routeTarget: Self.routeTarget,
                        placeholderCount: placeholderCount,
                        placeholderLabel: String(format: String(localized: "Loading %@"), title),
                        heroBadge: title,
                        isActive: renderKey.isActive,
                        isHomeTabSelected: renderKey.isHomeTabSelected,
                        scrollToTopTick: renderKey.scrollToTopTick,
                        onRefresh: {
                            await viewModel.refreshPopular()
                            return false
                        },
                        onLastAppear: {
                            Task { await viewModel.loadPopular() }
                        },
                        onSelectVideo: { target in
                            coordinator.navigateToVideo(target)
                        }
                    )
                }
            }
        )
        .task {
            FeedPerformanceSignposts.screenAdmission(.home)
            if viewModel.popularItems.isEmpty {
                await viewModel.loadPopular()
            }
        }
    }

    private static func routeTarget(_ item: VideoCard) -> VideoRouteTarget? {
        .make(
            bvid: item.bvid,
            aid: nil,
            title: item.title,
            coverURL: item.pic,
            mobileCoverURL: item.mobileCoverURL,
            ownerName: item.owner.name,
            durationSeconds: item.duration
        )
    }
}

private struct HomeFeedSurfaceContainer<Content: View>: View {
    let feedback: HomeFeedFeedback
    let hasContent: Bool
    let title: String
    let onRetry: (HomeFeedFailure) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        let showsEmptyFeedback = !hasContent && (feedback.failure != nil || feedback.hasSucceeded)
        VStack(spacing: 0) {
            if hasContent, feedback.failure != nil {
                HomeFeedFeedbackView(
                    feedback: feedback,
                    hasContent: true,
                    title: title,
                    emptyTitle: String(localized: "No Videos"),
                    showsLoadingIndicator: false,
                    retry: onRetry
                )
            }
            ZStack {
                content()
                    .opacity(showsEmptyFeedback ? 0 : 1)
                    .allowsHitTesting(!showsEmptyFeedback)
                    .accessibilityHidden(showsEmptyFeedback)
                if showsEmptyFeedback {
                    HomeFeedFeedbackView(
                        feedback: feedback,
                        hasContent: false,
                        title: title,
                        emptyTitle: String(localized: "No Videos"),
                        showsLoadingIndicator: false,
                        retry: onRetry
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

private struct RankedFeedItem: Identifiable {
    let rank: Int
    let item: RankingResult.RankItem
    var id: Int { item.id }
}

@MainActor
private final class RankingTabCache {
    struct Snapshot {
        let rankedItems: [RankedFeedItem]
        let itemIDs: [Int]
        let feedback: HomeFeedFeedback
    }

    var snapshot = Snapshot(rankedItems: [], itemIDs: [], feedback: HomeFeedFeedback())

    func sync(from viewModel: HomeViewModel) -> Snapshot {
        let rawItems = viewModel.rankingItems
        let feedback = viewModel.feedback(for: .ranking)
        let newIDs = rawItems.map(\.id)
        if newIDs == snapshot.itemIDs {
            snapshot = Snapshot(rankedItems: snapshot.rankedItems, itemIDs: snapshot.itemIDs, feedback: feedback)
        } else {
            let mapped = rawItems.enumerated().map { RankedFeedItem(rank: $0.offset + 1, item: $0.element) }
            snapshot = Snapshot(rankedItems: mapped, itemIDs: newIDs, feedback: feedback)
        }
        return snapshot
    }
}

private struct RankingListView: View {
    let viewModel: HomeViewModel
    let coordinator: AppCoordinator
    let isSelected: Bool

    @State private var cache = RankingTabCache()

    var body: some View {
        let snap = isSelected ? cache.sync(from: viewModel) : cache.snapshot
        let hasContent = !snap.rankedItems.isEmpty
        let title = String(localized: "Ranking")
        let placeholderCount = snap.feedback.showsPlaceholder(hasContent: hasContent) ? 7 : 0
        let renderKey = HomeFeedRenderKey(
            itemIDs: snap.itemIDs,
            generationIDs: [],
            generationCounts: [],
            placeholderCount: placeholderCount,
            isActive: isSelected,
            isHomeTabSelected: coordinator.selectedTab == .home,
            scrollToTopTick: coordinator.scrollToTopTick,
            layoutRaw: HomeLayoutMode.list.rawValue,
            coverPresentation: CoverPresentationStore.shared.presentation
        )

        HomeFeedSurfaceContainer(
            feedback: snap.feedback,
            hasContent: hasContent,
            title: title,
            onRetry: { failure in Task { await viewModel.retry(failure) } },
            content: {
                EquatableHomeFeedHost(key: renderKey) {
                    HomeFeedCollectionView(
                        items: snap.rankedItems,
                        title: \.item.title,
                        sources: {
                            VideoCoverSources(widescreen: $0.item.pic, fourByThree: $0.item.mobileCoverURL)
                        },
                        duration: { $0.item.duration ?? 0 },
                        ownerName: { $0.item.owner?.name ?? "" },
                        viewCount: { $0.item.stat?.view ?? 0 },
                        rank: \.rank,
                        routeTarget: { Self.routeTarget($0.item) },
                        fixedLayoutMode: .list,
                        placeholderCount: placeholderCount,
                        placeholderLabel: String(format: String(localized: "Loading %@"), title),
                        heroBadge: title,
                        isActive: renderKey.isActive,
                        isHomeTabSelected: renderKey.isHomeTabSelected,
                        scrollToTopTick: renderKey.scrollToTopTick,
                        onRefresh: {
                            await viewModel.loadRanking()
                            return false
                        },
                        onLastAppear: {},
                        onSelectVideo: { target in
                            coordinator.navigateToVideo(target)
                        }
                    )
                }
            }
        )
        .task {
            FeedPerformanceSignposts.screenAdmission(.home)
            if viewModel.rankingItems.isEmpty {
                await viewModel.loadRanking()
            }
        }
    }

    private static func routeTarget(_ item: RankingResult.RankItem) -> VideoRouteTarget? {
        .make(
            bvid: item.bvid,
            aid: item.aid,
            title: item.title,
            coverURL: item.pic,
            mobileCoverURL: item.mobileCoverURL,
            ownerName: item.owner?.name ?? "",
            durationSeconds: item.duration ?? 0
        )
    }
}

private struct PGCFeedRenderKey: Equatable {
    let followedItems: [PGCFollowedPosterData]
    let itemIDs: [Int]
    let placeholderCount: Int
    let isActive: Bool
    let isHomeTabSelected: Bool
    let scrollToTopTick: Int
}

private struct EquatablePGCFeedHost<Content: View>: View, Equatable {
    let key: PGCFeedRenderKey
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View {
        content()
    }
}

@MainActor
private final class PGCTabCache {
    struct Snapshot {
        let followedItems: [PGCFollowedPosterData]
        let items: [PGCPosterItemData]
        let itemIDs: [Int]
        let followedFeedback: HomeFeedFeedback
        let pgcFeedback: HomeFeedFeedback
        let canLoadFollowed: Bool
    }

    var snapshot = Snapshot(
        followedItems: [],
        items: [],
        itemIDs: [],
        followedFeedback: HomeFeedFeedback(),
        pgcFeedback: HomeFeedFeedback(),
        canLoadFollowed: false
    )

    func sync(
        rawFollowed: [BangumiFollowResult.FollowedBangumi],
        rawItems: [PGCIndexResult.PGCItem],
        followedFeedback: HomeFeedFeedback,
        pgcFeedback: HomeFeedFeedback,
        canLoadFollowed: Bool
    ) -> Snapshot {
        let mappedFollowed = rawFollowed.map {
            PGCFollowedPosterData(
                id: $0.seasonId,
                title: $0.title ?? "",
                cover: $0.cover ?? "",
                meta: $0.progressText ?? $0.newEpShow ?? " "
            )
        }
        let newIDs = rawItems.map(\.id)
        let mappedItems: [PGCPosterItemData]
        if newIDs == snapshot.itemIDs {
            mappedItems = snapshot.items
        } else {
            mappedItems = rawItems.map {
                PGCPosterItemData(
                    id: $0.seasonId,
                    title: $0.title,
                    cover: $0.cover,
                    badge: $0.badge,
                    meta: $0.indexShow ?? $0.order
                )
            }
        }
        snapshot = Snapshot(
            followedItems: mappedFollowed,
            items: mappedItems,
            itemIDs: newIDs,
            followedFeedback: followedFeedback,
            pgcFeedback: pgcFeedback,
            canLoadFollowed: canLoadFollowed
        )
        return snapshot
    }
}

private struct PGCListView: View {
    let viewModel: HomeViewModel
    let coordinator: AppCoordinator
    let indexType: Int
    let isSelected: Bool

    @State private var cache = PGCTabCache()

    private var items: [PGCIndexResult.PGCItem] {
        indexType == 1 ? viewModel.animeItems : viewModel.movieItems
    }

    private var followed: [BangumiFollowResult.FollowedBangumi] {
        indexType == 1 ? viewModel.followedAnime : viewModel.followedShows
    }

    private var canLoadFollowed: Bool {
        _ = AccountManager.shared.activeMid
        guard let midString = AuthManager.shared.dedeUserID else { return false }
        return Int(midString) != nil
    }

    var body: some View {
        let followedTitle = indexType == 1 ? String(localized: "My Anime") : String(localized: "My Shows")
        let pgcTitle = indexType == 1 ? String(localized: "Anime") : String(localized: "Movies")
        let snap = isSelected
            ? cache.sync(
                rawFollowed: followed,
                rawItems: items,
                followedFeedback: viewModel.feedback(for: .followed(indexType)),
                pgcFeedback: viewModel.feedback(for: .pgc(indexType)),
                canLoadFollowed: canLoadFollowed
            )
            : cache.snapshot
        let hasItems = !snap.items.isEmpty
        let placeholderCount = snap.pgcFeedback.showsPlaceholder(hasContent: hasItems) ? 6 : 0
        let renderKey = PGCFeedRenderKey(
            followedItems: snap.followedItems,
            itemIDs: snap.itemIDs,
            placeholderCount: placeholderCount,
            isActive: isSelected,
            isHomeTabSelected: coordinator.selectedTab == .home,
            scrollToTopTick: coordinator.scrollToTopTick
        )

        VStack(spacing: 0) {
            if snap.canLoadFollowed, snap.followedFeedback.failure != nil {
                HomeFeedFeedbackView(
                    feedback: snap.followedFeedback,
                    hasContent: !snap.followedItems.isEmpty,
                    title: followedTitle,
                    emptyTitle: nil,
                    showsLoadingIndicator: false,
                    retry: { failure in Task { await viewModel.retry(failure) } }
                )
            }

            HomeFeedSurfaceContainer(
                feedback: snap.pgcFeedback,
                hasContent: hasItems,
                title: pgcTitle,
                onRetry: { failure in Task { await viewModel.retry(failure) } },
                content: {
                    EquatablePGCFeedHost(key: renderKey) {
                        PGCFeedCollectionView(
                            followedTitle: followedTitle,
                            followedItems: snap.followedItems,
                            items: snap.items,
                            placeholderCount: placeholderCount,
                            placeholderLabel: String(format: String(localized: "Loading %@"), pgcTitle),
                            isActive: renderKey.isActive,
                            isHomeTabSelected: renderKey.isHomeTabSelected,
                            scrollToTopTick: renderKey.scrollToTopTick,
                            onRefresh: {
                                async let rail: Void = viewModel.loadFollowedBangumi(indexType: indexType)
                                await viewModel.refreshPGC(indexType: indexType)
                                await rail
                                return false
                            },
                            onLastAppear: {
                                Task { await viewModel.loadPGC(indexType: indexType) }
                            },
                            onSelectBangumi: { seasonID in
                                coordinator.navigate(to: .bangumiDetail(seasonID, zoom: .none))
                            }
                        )
                    }
                }
            )
        }
        .task {
            FeedPerformanceSignposts.screenAdmission(.home)
            if canLoadFollowed, followed.isEmpty, !viewModel.feedback(for: .followed(indexType)).hasSucceeded {
                await viewModel.loadFollowedBangumi(indexType: indexType)
            }
            if items.isEmpty, !viewModel.feedback(for: .pgc(indexType)).hasSucceeded {
                await viewModel.loadPGC(indexType: indexType)
            }
        }
    }
}

private struct HomeFeedFeedbackView: View {
    let feedback: HomeFeedFeedback
    let hasContent: Bool
    let title: String
    let emptyTitle: String?
    var showsLoadingIndicator = true
    let retry: (HomeFeedFailure) -> Void

    var body: some View {
        if let failure = feedback.failure {
            if hasContent || emptyTitle == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: "wifi.exclamationmark")
                        .font(.headline)
                    Text("Load Failed")
                        .font(.subheadline)
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    retryButton(failure)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            } else {
                ContentUnavailableView {
                    Label("Load Failed", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(title)
                    Text(failure.message)
                } actions: {
                    retryButton(failure)
                }
            }
        } else if !hasContent, feedback.isLoading, showsLoadingIndicator {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .accessibilityLabel(Text(String(format: String(localized: "Loading %@"), title)))
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else if !hasContent, feedback.hasSucceeded, let emptyTitle {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "rectangle.stack")
            } description: {
                Text(title)
            }
        }
    }

    private func retryButton(_ failure: HomeFeedFailure) -> some View {
        Button("Retry") { retry(failure) }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text(verbatim: "\(String(localized: "Retry")): \(title)"))
    }
}
