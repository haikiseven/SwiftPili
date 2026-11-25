import SwiftUI

struct LiveListView: View {
    @State private var viewModel = LiveListViewModel()
    @State private var visitedSections: [LiveSection] = [.recommended]
    @State private var recentSections: [LiveSection] = [.recommended]
    @State private var pageGate = FeedLoadAdmissionGate()
    @State private var areasGate = FeedLoadAdmissionGate()
    @State private var showAllTags = false
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesRegularChrome: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            LiveTopHeaderBar(
                section: viewModel.section,
                areas: viewModel.areas,
                isLoggedIn: AuthManager.shared.isLoggedIn,
                onSelectSection: chooseSection,
                onShowAllTags: { showAllTags = true }
            )

            ZStack {
                ForEach(visitedSections, id: \.self) { tabSection in
                    let isSelected = viewModel.section == tabSection
                    LiveSectionFeedView(
                        tabSection: tabSection,
                        sectionState: viewModel.state(for: tabSection),
                        isSelected: isSelected,
                        coordinator: coordinator,
                        onLoadNextPage: { await loadNextPage() },
                        onRefresh: { await refreshList() },
                        onRetry: { failure in
                            guard viewModel.canRetry(failure) else { return }
                            if failure.retriesRefresh {
                                _ = await refreshList()
                            } else {
                                await loadNextPage()
                            }
                        },
                        onOpenRoom: { roomID in
                            coordinator.navigate(to: .liveRoom(roomID, zoom: .none))
                        }
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
                }
            }
            .transaction { $0.animation = nil }
        }
        .appAmbientBrowseBackground()
        .navigationTitle("Live")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(usesRegularChrome ? .visible : .hidden, for: .navigationBar)
        .sheet(isPresented: $showAllTags) {
            LiveAreaSheet(
                areas: viewModel.areas,
                initialParentID: activeParentID,
                selectedSection: viewModel.section
            ) { section in
                showAllTags = false
                chooseSection(section)
            }
            .presentationSizing(.page)
        }
        .task {
            FeedPerformanceSignposts.screenAdmission(.liveList)
            async let areas: Void = loadAreasIfNeeded()
            if viewModel.liveCards.isEmpty {
                await loadInitialPage()
            }
            await areas
            guard !Task.isCancelled else { return }
            viewModel.warmAdjacentSections(isLoggedIn: AuthManager.shared.isLoggedIn)
        }
    }

    private func loadInitialPage() async {
        await loadPage(kind: .initial, cursor: "page:1")
    }

    private func loadNextPage() async {
        let cursor = viewModel.paginationAdmissionCursor
        await loadPage(kind: .pagination, cursor: cursor)
    }

    private func loadPage(kind: FeedLoadKind, cursor: String) async {
        let token: FeedLoadToken
        if kind == .refresh {
            guard !pageGate.hasInFlight else {
                recordPageDuplicate(kind: kind)
                return
            }
            token = pageGate.supersedeAndAdmit(kind: kind, cursor: cursor)
        } else {
            guard let admitted = pageGate.admit(kind: kind, cursor: cursor) else {
                recordPageDuplicate(kind: kind)
                return
            }
            token = admitted
        }

        let signpostID = FeedPerformanceSignposts.begin(
            screen: .liveList, kind: kind, generation: token.generation, page: nil
        )
        var outcome: FeedLoadOutcome = .failed
        let loaded = await viewModel.load()
        guard pageGate.isCurrent(token) else {
            pageGate.finish(token, succeeded: false)
            recordPageEnd(signpostID, kind: kind, generation: token.generation, page: nil, outcome: .superseded)
            return
        }

        normalizeLiveCards()
        pageGate.finish(token, succeeded: loaded)
        outcome = loaded ? .success : .failed
        recordPageEnd(signpostID, kind: kind, generation: token.generation, page: nil, outcome: outcome)
    }

    private func refreshList() async -> Bool {
        guard !pageGate.hasInFlight else {
            recordPageDuplicate(kind: .refresh)
            return false
        }
        let token = pageGate.supersedeAndAdmit(kind: .refresh, cursor: "page:1")
        let signpostID = FeedPerformanceSignposts.begin(
            screen: .liveList, kind: .refresh, generation: token.generation, page: 1
        )
        let loaded = await viewModel.refresh()
        guard pageGate.isCurrent(token) else {
            pageGate.finish(token, succeeded: false)
            recordPageEnd(signpostID, kind: .refresh, generation: token.generation, page: 1, outcome: .superseded)
            return false
        }
        normalizeLiveCards()
        pageGate.finish(token, succeeded: loaded)
        let outcome: FeedLoadOutcome = loaded ? .success : .failed
        recordPageEnd(signpostID, kind: .refresh, generation: token.generation, page: 1, outcome: outcome)
        return loaded
    }

    private func recordPageEnd(
        _ signpostID: UInt64, kind: FeedLoadKind, generation: UInt64, page: Int?, outcome: FeedLoadOutcome
    ) {
        FeedPerformanceSignposts.end(
            signpostID, screen: .liveList, kind: kind, generation: generation,
            page: page, outcome: outcome, count: viewModel.liveCards.count
        )
    }

    private func normalizeLiveCards() {
        let normalized = FeedCollectionPolicy.replaceDeduplicated(
            viewModel.liveCards,
            id: \.id
        )
        if normalized.count != viewModel.liveCards.count {
            viewModel.liveCards = normalized
        }
    }

    private func loadAreasIfNeeded() async {
        guard viewModel.areas.isEmpty else { return }
        guard let token = areasGate.admit(kind: .initial, cursor: "areas") else {
            FeedPerformanceSignposts.duplicateSuppressed(
                .liveList,
                kind: .initial,
                generation: areasGate.generation,
                count: areasGate.duplicateSuppressionCount
            )
            return
        }
        await viewModel.loadAreas()
        areasGate.finish(token, succeeded: !viewModel.areas.isEmpty)
    }

    private func recordPageDuplicate(kind: FeedLoadKind) {
        FeedPerformanceSignposts.duplicateSuppressed(
            .liveList,
            kind: kind,
            generation: pageGate.generation,
            count: pageGate.duplicateSuppressionCount
        )
    }

    private var activeParentID: Int? {
        if case let .area(parentID, _, _) = viewModel.section {
            return parentID
        }
        return nil
    }

    private func chooseSection(_ section: LiveSection) {
        guard section != viewModel.section else { return }
        pageGate.supersede()
        recentSections.removeAll { $0 == section }
        recentSections.append(section)
        if !visitedSections.contains(section) {
            visitedSections.append(section)
            if visitedSections.count > 3,
               let evictTarget = recentSections.first(where: { $0 != section && $0 != .recommended }) {
                visitedSections.removeAll { $0 == evictTarget }
                recentSections.removeAll { $0 == evictTarget }
            }
        }
        viewModel.selectSection(section)
    }
}

private struct LiveFeedRenderKey: Equatable {
    let items: [LiveFeedItemData]
    let showsSkeletons, canLoadMore, isActive, isLiveTabSelected: Bool
    let paginationCursor: String
    let scrollToTopTick: Int
    let coverPresentation: CoverPresentation
}

private struct EquatableLiveCollectionHost<Content: View>: View, Equatable {
    let key: LiveFeedRenderKey
    @ViewBuilder let content: () -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    var body: some View { content() }
}

@MainActor
private final class LiveTabCache {
    struct Snapshot {
        let cards: [LiveListResult.LiveCard]
        let items: [LiveFeedItemData]
        let showsSkeletons, showsEmptyFeedback, canLoadMore: Bool
        let paginationCursor: String
        let loadFailure: LiveListViewModel.LoadFailure?
    }

    var snapshot = Snapshot(
        cards: [], items: [], showsSkeletons: true, showsEmptyFeedback: false,
        canLoadMore: false, paginationCursor: "page:1", loadFailure: nil
    )

    func sync(from state: LiveListViewModel.SectionState) -> Snapshot {
        let cards = state.cards
        let hasContent = !cards.isEmpty
        let showsSkeletons = !hasContent
            && (state.isLoading || (!state.hasLoadedPage && state.loadFailure == nil))
        let showsEmpty = !hasContent && !showsSkeletons && (state.loadFailure != nil || state.hasLoadedPage)
        let unchanged = cards.count == snapshot.cards.count && zip(cards, snapshot.cards).allSatisfy {
            $0.id == $1.id && $0.liveStatus == $1.liveStatus && $0.displayOnline == $1.displayOnline
                && $0.title == $1.title && $0.areaName == $1.areaName && $0.displayCover == $1.displayCover
        }
        let items = unchanged ? snapshot.items : cards.map(LiveSectionFeedView.feedItemData)
        snapshot = Snapshot(
            cards: cards, items: items, showsSkeletons: showsSkeletons, showsEmptyFeedback: showsEmpty,
            canLoadMore: state.hasMore && !state.isLoading, paginationCursor: "page:\(state.page)",
            loadFailure: state.loadFailure
        )
        return snapshot
    }
}

private struct LiveSectionFeedView: View, Equatable {
    let tabSection: LiveSection
    let sectionState: LiveListViewModel.SectionState
    let isSelected: Bool
    let coordinator: AppCoordinator
    let onLoadNextPage: () async -> Void
    let onRefresh: @MainActor @Sendable () async -> Bool
    let onRetry: (LiveListViewModel.LoadFailure) async -> Void
    let onOpenRoom: (Int) -> Void

    @State private var cache = LiveTabCache()
    @State private var dismissedFailureID: UUID?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabSection == rhs.tabSection && lhs.isSelected == rhs.isSelected
            && lhs.sectionState === rhs.sectionState && lhs.coordinator === rhs.coordinator
    }

    var body: some View {
        let snap = isSelected ? cache.sync(from: sectionState) : cache.snapshot
        let renderKey = LiveFeedRenderKey(
            items: snap.items, showsSkeletons: snap.showsSkeletons, canLoadMore: snap.canLoadMore,
            isActive: isSelected, isLiveTabSelected: coordinator.selectedTab == .live,
            paginationCursor: snap.paginationCursor, scrollToTopTick: coordinator.scrollToTopTick,
            coverPresentation: CoverPresentationStore.shared.presentation
        )
        let inlineFailure: LiveListViewModel.LoadFailure? =
            if isSelected, !snap.items.isEmpty, let failure = snap.loadFailure, failure.id != dismissedFailureID {
                failure
            } else {
                nil
            }

        ZStack {
            EquatableLiveCollectionHost(key: renderKey) {
                LiveFeedCollectionView(
                    items: snap.items,
                    showsSkeletons: snap.showsSkeletons,
                    skeletonLabel: String(localized: "Loading live streams"),
                    canLoadMore: snap.canLoadMore,
                    paginationCursor: snap.paginationCursor,
                    isActive: renderKey.isActive,
                    isLiveTabSelected: renderKey.isLiveTabSelected,
                    scrollToTopTick: renderKey.scrollToTopTick,
                    onRefresh: onRefresh,
                    onLastAppear: { Task { await onLoadNextPage() } },
                    onSelectRoom: onOpenRoom
                )
            }
            .opacity(snap.showsEmptyFeedback ? 0 : 1)
            .allowsHitTesting(!snap.showsEmptyFeedback)
            .accessibilityHidden(snap.showsEmptyFeedback)

            if snap.showsEmptyFeedback {
                ScrollView {
                    emptyFeedbackView(failure: snap.loadFailure)
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical)
                }
                .refreshable { _ = await onRefresh() }
            }
        }
        .alert(
            "Couldn't Load",
            isPresented: Binding(
                get: { inlineFailure != nil },
                set: { isPresented in
                    if !isPresented, let failure = inlineFailure {
                        dismissedFailureID = failure.id
                    }
                }
            ),
            presenting: inlineFailure
        ) { failure in
            Button("Retry") {
                dismissedFailureID = failure.id
                Task { await onRetry(failure) }
            }
            Button("Dismiss", role: .cancel) {
                dismissedFailureID = failure.id
            }
        } message: { failure in
            Text(failure.message)
        }
    }

    @ViewBuilder
    private func emptyFeedbackView(failure: LiveListViewModel.LoadFailure?) -> some View {
        if let failure {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                Button("Retry") { Task { await onRetry(failure) } }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 44, minHeight: 44)
            }
        } else if tabSection == .follows {
            ContentUnavailableView(
                "No Followed Streamers", systemImage: "heart",
                description: Text("Streamers you follow show up here.")
            )
        } else {
            ContentUnavailableView("No Live Streams", systemImage: "video")
        }
    }

    fileprivate static func feedItemData(from card: LiveListResult.LiveCard) -> LiveFeedItemData {
        LiveFeedItemData(
            id: card.id, roomID: card.roomid, title: card.title, uname: card.uname,
            areaName: card.areaName, coverURL: card.displayCover,
            displayOnline: card.displayOnline, liveStatus: card.liveStatus
        )
    }
}

private struct LiveTopHeaderBar: View, Equatable {
    let section: LiveSection
    let areas: [LiveParentArea]
    let isLoggedIn: Bool
    let onSelectSection: (LiveSection) -> Void
    let onShowAllTags: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var subTagPicks = 0

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section == rhs.section
            && lhs.isLoggedIn == rhs.isLoggedIn
            && lhs.areas.count == rhs.areas.count
            && lhs.areas.first?.id == rhs.areas.first?.id
            && lhs.areas.last?.id == rhs.areas.last?.id
    }

    private var activeParent: LiveParentArea? {
        guard case let .area(parentID, _, _) = section else { return nil }
        return areas.first { $0.id == parentID }
    }

    private var activeSubAreaID: Int? {
        guard case let .area(_, areaID, _) = section else { return nil }
        return areaID
    }

    private var topTabItems: [SectionTabBar<String>.Item] {
        var items: [SectionTabBar<String>.Item] = [
            .init(id: "recommended", label: Text("Recommended"), isSelected: section == .recommended) {
                onSelectSection(.recommended)
            }
        ]
        if isLoggedIn {
            items.append(.init(id: "follows", label: Text("My Follows"), isSelected: section == .follows) {
                onSelectSection(.follows)
            })
        }
        items.append(contentsOf: areas.map { parent in
            .init(id: "parent-\(parent.id)", label: Text(parent.name), isSelected: activeParent?.id == parent.id) {
                onSelectSection(.area(parentID: parent.id, areaID: 0, name: parent.name))
            }
        })
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SectionTabBar(items: topTabItems, isScrollable: true, enablesSelectionHaptic: true, itemSpacing: 18)

                AppTopBarCircleButton(
                    systemImage: "square.grid.2x2",
                    accessibilityLabel: "All Tags",
                    action: onShowAllTags
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if let parent = activeParent, !parent.list.isEmpty {
                subAreaStrip(for: parent)
                    .transaction { $0.animation = nil }
            }
        }
    }

    private func subAreaStrip(for parent: LiveParentArea) -> some View {
        let isAccessibility = dynamicTypeSize.isAccessibilitySize
        return ScrollView(.horizontal, showsIndicators: false) {
            Group {
                if isAccessibility {
                    HStack(spacing: 6) { subAreaChips(for: parent) }
                } else {
                    LazyHStack(spacing: 6) { subAreaChips(for: parent) }
                }
            }
            .padding(.horizontal, AppSpacing.l)
            .padding(.bottom, 2)
        }
        .frame(minHeight: 46, maxHeight: isAccessibility ? nil : 46)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .appSelectionHaptic(userPicks: subTagPicks)
    }

    @ViewBuilder
    private func subAreaChips(for parent: LiveParentArea) -> some View {
        subAreaChip(
            isSelected: activeSubAreaID == 0,
            action: { onSelectSection(.area(parentID: parent.id, areaID: 0, name: parent.name)) },
            label: { Text("All") }
        )
        ForEach(parent.list) { sub in
            subAreaChip(
                isSelected: activeSubAreaID == sub.id,
                action: { onSelectSection(.area(parentID: parent.id, areaID: sub.id, name: sub.name)) },
                label: { Text(sub.name) }
            )
        }
    }

    private func subAreaChip<Label: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            guard !isSelected else { return }
            subTagPicks &+= 1
            action()
        } label: {
            label()
                .font(.footnote.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.biliAccent : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.biliAccent.opacity(0.14) : Color.clear)
                )
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
