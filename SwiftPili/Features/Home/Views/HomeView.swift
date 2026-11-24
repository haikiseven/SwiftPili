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
    let contentRevision: UInt64
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
        let sections: [HomeFeedSectionData]
        let hasContent: Bool
        let revision: UInt64
        let feedback: HomeFeedFeedback
    }

    private var hasSynced = false
    var snapshot = Snapshot(
        sections: [], hasContent: false, revision: 0, feedback: HomeFeedFeedback()
    )

    func sync(from viewModel: HomeViewModel) -> Snapshot {
        let feed = viewModel.recommendationFeed
        let feedback = viewModel.feedback(for: .recommended)
        let rev = viewModel.recommendedRevision
        if hasSynced, rev == snapshot.revision {
            snapshot = Snapshot(
                sections: snapshot.sections,
                hasContent: snapshot.hasContent,
                revision: rev,
                feedback: feedback
            )
            return snapshot
        }
        hasSynced = true
        let sections: [HomeFeedSectionData] = feed.generations.compactMap { gen in
            guard !gen.items.isEmpty else { return nil }
            let mapped = gen.items.map { item in
                HomeFeedItemData(
                    id: HomeFeedItemIdentifier(item.id),
                    title: item.title,
                    sources: VideoCoverSources(widescreen: item.pic, fourByThree: item.mobileCoverURL),
                    duration: item.duration ?? 0,
                    ownerName: item.owner?.name ?? "",
                    viewCount: item.stat?.view ?? 0,
                    routeTarget: .make(
                        bvid: item.bvid,
                        aid: nil,
                        title: item.title,
                        coverURL: item.pic,
                        mobileCoverURL: item.mobileCoverURL,
                        ownerName: item.owner?.name ?? "",
                        durationSeconds: item.duration ?? 0
                    )
                )
            }
            return HomeFeedSectionData(id: gen.id, items: mapped)
        }
        snapshot = Snapshot(
            sections: sections,
            hasContent: !feed.items.isEmpty,
            revision: rev,
            feedback: feedback
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
        let hasContent = snap.hasContent
        let title = String(localized: "Recommend")
        let placeholderCount = snap.feedback.showsPlaceholder(hasContent: hasContent)
            ? HomeFeedPlaceholder.count : 0
        let renderKey = HomeFeedRenderKey(
            contentRevision: snap.revision,
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
            isSelected: isSelected,
            title: title,
            onRetry: { failure in Task { await viewModel.retry(failure) } },
            content: {
                EquatableHomeFeedHost(key: renderKey) {
                    HomeFeedCollectionView(
                        preconvertedSections: snap.sections,
                        contentRevision: snap.revision,
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
}

@MainActor
private final class PopularTabCache {
    struct Snapshot {
        let sections: [HomeFeedSectionData]
        let hasContent: Bool
        let revision: UInt64
        let feedback: HomeFeedFeedback
    }

    private var hasSynced = false
    var snapshot = Snapshot(sections: [], hasContent: false, revision: 0, feedback: HomeFeedFeedback())

    func sync(from viewModel: HomeViewModel) -> Snapshot {
        let items = viewModel.popularItems
        let feedback = viewModel.feedback(for: .popular)
        let rev = viewModel.popularRevision
        if hasSynced, rev == snapshot.revision {
            snapshot = Snapshot(
                sections: snapshot.sections,
                hasContent: snapshot.hasContent,
                revision: rev,
                feedback: feedback
            )
            return snapshot
        }
        hasSynced = true
        let sections: [HomeFeedSectionData]
        if items.isEmpty {
            sections = []
        } else {
            let mapped = items.map { item in
                HomeFeedItemData(
                    id: HomeFeedItemIdentifier(item.id),
                    title: item.title,
                    sources: VideoCoverSources(widescreen: item.pic, fourByThree: item.mobileCoverURL),
                    duration: item.duration,
                    ownerName: item.owner.name,
                    viewCount: item.stat.view,
                    routeTarget: .make(
                        bvid: item.bvid,
                        aid: nil,
                        title: item.title,
                        coverURL: item.pic,
                        mobileCoverURL: item.mobileCoverURL,
                        ownerName: item.owner.name,
                        durationSeconds: item.duration
                    )
                )
            }
            sections = [HomeFeedSectionData(id: 0, items: mapped)]
        }
        snapshot = Snapshot(sections: sections, hasContent: !items.isEmpty, revision: rev, feedback: feedback)
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
        let hasContent = snap.hasContent
        let title = String(localized: "Popular")
        let placeholderCount = snap.feedback.showsPlaceholder(hasContent: hasContent)
            ? HomeFeedPlaceholder.count : 0
        let renderKey = HomeFeedRenderKey(
            contentRevision: snap.revision,
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
            isSelected: isSelected,
            title: title,
            onRetry: { failure in Task { await viewModel.retry(failure) } },
            content: {
                EquatableHomeFeedHost(key: renderKey) {
                    HomeFeedCollectionView(
                        preconvertedSections: snap.sections,
                        contentRevision: snap.revision,
                        placeholderCount: placeholderCount,
                        placeholderLabel: String(format: String(localized: "Loading %@"), title),
                        heroBadge: title,
                        isActive: renderKey.isActive,
                        isHomeTabSelected: renderKey.isHomeTabSelected,
                        scrollToTopTick: renderKey.scrollToTopTick,
                        onRefresh: {
                            await viewModel.refreshPopular()
                            return !viewModel.popularItems.isEmpty
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
}

private struct HomeFeedSurfaceContainer<Content: View>: View {
    let feedback: HomeFeedFeedback
    let hasContent: Bool
    let isSelected: Bool
    let title: String
    var secondaryFailure: (title: String, failure: HomeFeedFailure)? = nil
    let onRetry: (HomeFeedFailure) -> Void
    @ViewBuilder var content: () -> Content

    @State private var dismissedReceipts: Set<UUID> = []

    var body: some View {
        let showsEmptyFeedback = !hasContent && (feedback.failure != nil || feedback.hasSucceeded)
        let activeAlertFailure: (title: String, failure: HomeFeedFailure)? = {
            guard isSelected, !showsEmptyFeedback else { return nil }
            if hasContent, let failure = feedback.failure, !dismissedReceipts.contains(failure.receipt) {
                return (title, failure)
            }
            if let secondary = secondaryFailure, !dismissedReceipts.contains(secondary.failure.receipt) {
                return secondary
            }
            return nil
        }()

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
        .alert(
            "Load Failed",
            isPresented: Binding(
                get: { activeAlertFailure != nil },
                set: { isPresented in
                    if !isPresented, let alert = activeAlertFailure {
                        dismissedReceipts.insert(alert.failure.receipt)
                    }
                }
            ),
            presenting: activeAlertFailure
        ) { alert in
            Button("Retry") {
                dismissedReceipts.insert(alert.failure.receipt)
                onRetry(alert.failure)
            }
            Button("Dismiss", role: .cancel) {
                dismissedReceipts.insert(alert.failure.receipt)
            }
        } message: { alert in
            Text(verbatim: "\(alert.title)\n\(alert.failure.message)")
        }
    }
}

@MainActor
private final class RankingTabCache {
    struct Snapshot {
        let sections: [HomeFeedSectionData]
        let hasContent: Bool
        let revision: UInt64
        let feedback: HomeFeedFeedback
    }

    private var hasSynced = false
    var snapshot = Snapshot(sections: [], hasContent: false, revision: 0, feedback: HomeFeedFeedback())

    func sync(from viewModel: HomeViewModel) -> Snapshot {
        let rawItems = viewModel.rankingItems
        let feedback = viewModel.feedback(for: .ranking)
        let rev = viewModel.rankingRevision
        if hasSynced, rev == snapshot.revision {
            snapshot = Snapshot(
                sections: snapshot.sections,
                hasContent: snapshot.hasContent,
                revision: rev,
                feedback: feedback
            )
            return snapshot
        }
        hasSynced = true
        let sections: [HomeFeedSectionData]
        if rawItems.isEmpty {
            sections = []
        } else {
            let mapped = rawItems.enumerated().map { offset, item in
                HomeFeedItemData(
                    id: HomeFeedItemIdentifier(item.id),
                    title: item.title,
                    sources: VideoCoverSources(widescreen: item.pic, fourByThree: item.mobileCoverURL),
                    duration: item.duration ?? 0,
                    ownerName: item.owner?.name ?? "",
                    viewCount: item.stat?.view ?? 0,
                    rank: offset + 1,
                    routeTarget: .make(
                        bvid: item.bvid,
                        aid: item.aid,
                        title: item.title,
                        coverURL: item.pic,
                        mobileCoverURL: item.mobileCoverURL,
                        ownerName: item.owner?.name ?? "",
                        durationSeconds: item.duration ?? 0
                    )
                )
            }
            sections = [HomeFeedSectionData(id: 0, items: mapped)]
        }
        snapshot = Snapshot(sections: sections, hasContent: !rawItems.isEmpty, revision: rev, feedback: feedback)
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
        let hasContent = snap.hasContent
        let title = String(localized: "Ranking")
        let placeholderCount = snap.feedback.showsPlaceholder(hasContent: hasContent) ? 7 : 0
        let renderKey = HomeFeedRenderKey(
            contentRevision: snap.revision,
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
            isSelected: isSelected,
            title: title,
            onRetry: { failure in Task { await viewModel.retry(failure) } },
            content: {
                EquatableHomeFeedHost(key: renderKey) {
                    HomeFeedCollectionView(
                        preconvertedSections: snap.sections,
                        contentRevision: snap.revision,
                        fixedLayoutMode: .list,
                        placeholderCount: placeholderCount,
                        placeholderLabel: String(format: String(localized: "Loading %@"), title),
                        heroBadge: title,
                        isActive: renderKey.isActive,
                        isHomeTabSelected: renderKey.isHomeTabSelected,
                        scrollToTopTick: renderKey.scrollToTopTick,
                        onRefresh: {
                            await viewModel.loadRanking()
                            return !viewModel.rankingItems.isEmpty
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
}

private struct PGCFeedRenderKey: Equatable {
    let followedRevision: UInt64
    let itemsRevision: UInt64
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
        let followedRevision: UInt64
        let items: [PGCPosterItemData]
        let itemsRevision: UInt64
        let followedFeedback: HomeFeedFeedback
        let pgcFeedback: HomeFeedFeedback
        let canLoadFollowed: Bool
    }

    private var hasSynced = false
    var snapshot = Snapshot(
        followedItems: [],
        followedRevision: 0,
        items: [],
        itemsRevision: 0,
        followedFeedback: HomeFeedFeedback(),
        pgcFeedback: HomeFeedFeedback(),
        canLoadFollowed: false
    )

    func sync(
        rawFollowed: [BangumiFollowResult.FollowedBangumi],
        followedRevision: UInt64,
        rawItems: [PGCIndexResult.PGCItem],
        itemsRevision: UInt64,
        followedFeedback: HomeFeedFeedback,
        pgcFeedback: HomeFeedFeedback,
        canLoadFollowed: Bool
    ) -> Snapshot {
        let mappedFollowed: [PGCFollowedPosterData]
        if hasSynced, followedRevision == snapshot.followedRevision {
            mappedFollowed = snapshot.followedItems
        } else {
            mappedFollowed = rawFollowed.map {
                PGCFollowedPosterData(
                    id: $0.seasonId,
                    title: $0.title ?? "",
                    cover: $0.cover ?? "",
                    meta: $0.progressText ?? $0.newEpShow ?? " "
                )
            }
        }
        let mappedItems: [PGCPosterItemData]
        if hasSynced, itemsRevision == snapshot.itemsRevision {
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
        hasSynced = true
        snapshot = Snapshot(
            followedItems: mappedFollowed,
            followedRevision: followedRevision,
            items: mappedItems,
            itemsRevision: itemsRevision,
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

    private var itemsRevision: UInt64 {
        indexType == 1 ? viewModel.animeRevision : viewModel.movieRevision
    }

    private var followedRevision: UInt64 {
        indexType == 1 ? viewModel.followedAnimeRevision : viewModel.followedShowsRevision
    }

    private var canLoadFollowed: Bool {
        guard let midString = AuthManager.shared.dedeUserID else { return false }
        return Int(midString) != nil
    }

    var body: some View {
        let followedTitle = indexType == 1 ? String(localized: "My Anime") : String(localized: "My Shows")
        let pgcTitle = indexType == 1 ? String(localized: "Anime") : String(localized: "Movies")
        let snap = isSelected
            ? cache.sync(
                rawFollowed: followed,
                followedRevision: followedRevision,
                rawItems: items,
                itemsRevision: itemsRevision,
                followedFeedback: viewModel.feedback(for: .followed(indexType)),
                pgcFeedback: viewModel.feedback(for: .pgc(indexType)),
                canLoadFollowed: canLoadFollowed
            )
            : cache.snapshot
        let hasItems = !snap.items.isEmpty
        let placeholderCount = snap.pgcFeedback.showsPlaceholder(hasContent: hasItems) ? 6 : 0
        let renderKey = PGCFeedRenderKey(
            followedRevision: snap.followedRevision,
            itemsRevision: snap.itemsRevision,
            placeholderCount: placeholderCount,
            isActive: isSelected,
            isHomeTabSelected: coordinator.selectedTab == .home,
            scrollToTopTick: coordinator.scrollToTopTick
        )

        HomeFeedSurfaceContainer(
            feedback: snap.pgcFeedback,
            hasContent: hasItems,
            isSelected: isSelected,
            title: pgcTitle,
            secondaryFailure: snap.canLoadFollowed
                ? snap.followedFeedback.failure.map { (title: followedTitle, failure: $0) }
                : nil,
            onRetry: { failure in Task { await viewModel.retry(failure) } },
            content: {
                EquatablePGCFeedHost(key: renderKey) {
                    PGCFeedCollectionView(
                        followedTitle: followedTitle,
                        followedItems: snap.followedItems,
                        followedRevision: snap.followedRevision,
                        items: snap.items,
                        itemsRevision: snap.itemsRevision,
                        placeholderCount: placeholderCount,
                        placeholderLabel: String(format: String(localized: "Loading %@"), pgcTitle),
                        isActive: renderKey.isActive,
                        isHomeTabSelected: renderKey.isHomeTabSelected,
                        scrollToTopTick: renderKey.scrollToTopTick,
                        onRefresh: {
                            async let rail: Void = viewModel.loadFollowedBangumi(indexType: indexType)
                            await viewModel.refreshPGC(indexType: indexType)
                            await rail
                            return true
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
            ContentUnavailableView {
                Label("Load Failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(title)
                Text(failure.message)
            } actions: {
                retryButton(failure)
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
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(Text(verbatim: "\(String(localized: "Retry")): \(title)"))
    }
}
