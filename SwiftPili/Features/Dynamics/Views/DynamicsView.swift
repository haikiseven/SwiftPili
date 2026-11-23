import SwiftUI

private struct MomentComposeSession: Identifiable {
    let id = UUID()
    let sessionGeneration: UUID
    let identityRevision: UInt64
}

struct DynamicsView: View {
    @State private var viewModel = DynamicsViewModel()
    @State private var visitedSelections: [DynamicFeedSelection] = [.category(.all)]
    @State private var recentSelections: [DynamicFeedSelection] = [.category(.all)]
    @State private var peopleCatalog = DynamicsFollowingPeopleCatalog()
    @State private var composeSession: MomentComposeSession?
    @State private var showFollowingPeople = false
    @State private var previewImages: ImagePreviewItem?
    @State private var commentTarget: DynamicFeedResult.DynamicItem?
    @State private var repostTarget: DynamicFeedResult.DynamicItem?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let maxVisitedSelections = 3
    private var usesRegularChrome: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            DynamicsTopHeaderBar(
                selection: viewModel.selection,
                selectionKey: DynamicsSelectionKey(viewModel.selection),
                selectedAuthorMID: viewModel.selectedAuthorMID,
                showsComposeButton: !usesRegularChrome && AuthManager.shared.isLoggedIn,
                onSelect: { target in
                    chooseSelection(target)
                },
                onCompose: beginComposeMoment
            )

            ZStack {
                ForEach(visitedSelections, id: \.self) { tabSelection in
                    let isSelected = viewModel.selection == tabSelection
                    DynamicsFeedTabView(
                        tabSelection: tabSelection,
                        selectionKey: DynamicsSelectionKey(tabSelection),
                        isSelected: isSelected,
                        viewModel: viewModel,
                        peopleCatalog: peopleCatalog,
                        coordinator: coordinator,
                        onSelect: chooseSelection,
                        onMoreFollowing: { showFollowingPeople = true },
                        onPreviewImage: { previewImages = $0 },
                        onCommentFallback: { commentTarget = $0 },
                        onRepost: { repostTarget = $0 }
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
        .navigationTitle("Moments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(usesRegularChrome ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if usesRegularChrome, AuthManager.shared.isLoggedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginComposeMoment()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .tint(Color.primary)
                    .accessibilityLabel(Text("New Moment"))
                }
            }
        }
        .sheet(item: $composeSession) { session in
            ComposeMomentView { text in
                let outcome = await viewModel.postMoment(
                    text: text,
                    expectedSession: session.sessionGeneration,
                    expectedIdentityRevision: session.identityRevision
                )
                if case .posted = outcome,
                   AuthManager.shared.isLoggedIn,
                   AuthManager.shared.sessionGeneration == session.sessionGeneration,
                   AccountManager.shared.identityRevision == session.identityRevision {
                    Task { await viewModel.refresh() }
                }
                return outcome
            }
        }
        .sheet(item: $commentTarget) { item in
            DynamicCommentSheet(item: item)
                .appAdaptiveSheet(padSizing: .page)
        }
        .sheet(item: $repostTarget) { item in
            RepostSheet(item: item) { text in
                await viewModel.repost(item: item, content: text)
            }
        }
        .sheet(isPresented: $showFollowingPeople) {
            DynamicsFollowingPeoplePickerSheet(
                catalog: peopleCatalog,
                selectedMID: viewModel.selectedAuthorMID,
                onSelect: { authorMID in
                    chooseSelection(.people(authorMID: authorMID))
                }
            )
            .appAdaptiveSheet(padSizing: .form)
        }
        .imagePreview(item: $previewImages)
        .task {
            FeedPerformanceSignposts.screenAdmission(.dynamics)
            if viewModel.items.isEmpty {
                await viewModel.load()
            }
        }
        .task(id: viewModel.isPeopleMode) {
            if viewModel.isPeopleMode {
                await peopleCatalog.loadRecentPeopleIfNeeded()
            }
        }
    }

    private func beginComposeMoment() {
        guard AuthManager.shared.isLoggedIn else { return }
        composeSession = MomentComposeSession(
            sessionGeneration: AuthManager.shared.sessionGeneration,
            identityRevision: AccountManager.shared.identityRevision
        )
    }

    private func chooseSelection(_ target: DynamicFeedSelection) {
        recentSelections.removeAll { $0 == target }
        recentSelections.append(target)
        if !visitedSelections.contains(target) {
            visitedSelections.append(target)
            if visitedSelections.count > Self.maxVisitedSelections,
               let evictTarget = recentSelections.first(where: {
                   $0 != target && $0 != .category(.all)
               }) {
                visitedSelections.removeAll { $0 == evictTarget }
                recentSelections.removeAll { $0 == evictTarget }
            }
        }
        viewModel.select(target)
    }
}

private enum DynamicsSelectionKey: Equatable, Sendable {
    case category(DynamicsViewModel.FeedFilter), people(Int?)
    init(_ selection: DynamicFeedSelection) {
        switch selection {
        case .category(let filter): self = .category(filter)
        case .people(let mid): self = .people(mid)
        }
    }
}

private enum DynamicsFeedbackKey: Equatable, Sendable {
    case none, signIn, error(String), empty(DynamicsSelectionKey)
    init(_ state: DynamicsEmptyFeedbackState) {
        switch state {
        case .none: self = .none
        case .signIn: self = .signIn
        case .error(let msg): self = .error(msg)
        case .empty(let sel): self = .empty(DynamicsSelectionKey(sel))
        }
    }
}

private struct DynamicsRenderKey: Equatable {
    let fingerprints: [DynamicsItemFingerprint]
    let peopleHeader: DynamicsPeopleHeaderState?
    let inlineFeedback: DynamicsFeedbackKey
    let placeholderCount, scrollToTopTick: Int
    let showsPaginationSpinner, isActive, isDynamicsTabSelected: Bool
}

private struct EquatableDynamicsCollectionHost<Content: View>: View, Equatable {
    let key: DynamicsRenderKey
    @ViewBuilder let content: () -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    var body: some View { content() }
}

@MainActor
private final class DynamicsTabCache {
    struct Snapshot {
        let items: [DynamicFeedResult.DynamicItem]
        let fingerprints: [DynamicsItemFingerprint]
        let peopleHeader: DynamicsPeopleHeaderState?
        let feedbackState: DynamicsEmptyFeedbackState
        let usesInlinePeopleFeedback, showsPaginationSpinner: Bool
        let placeholderCount: Int
    }

    var snapshot = Snapshot(
        items: [], fingerprints: [], peopleHeader: nil, feedbackState: .none,
        usesInlinePeopleFeedback: false, showsPaginationSpinner: false, placeholderCount: 0
    )

    func sync(
        tabSelection: DynamicFeedSelection,
        viewModel: DynamicsViewModel,
        peopleCatalog: DynamicsFollowingPeopleCatalog,
        isAccessibilitySize: Bool
    ) -> Snapshot {
        let tabItems = viewModel.displayedItems(for: tabSelection)
        let isLoggedIn = AuthManager.shared.isLoggedIn
        let feedbackState: DynamicsEmptyFeedbackState = if !isLoggedIn {
            .signIn
        } else if tabItems.isEmpty, let tabError = viewModel.displayedError(for: tabSelection) {
            .error(tabError)
        } else if tabItems.isEmpty, viewModel.displayedHasLoaded(for: tabSelection) {
            .empty(tabSelection)
        } else {
            .none
        }
        let usesInline = isLoggedIn && tabSelection.isPeopleMode && feedbackState != .none
        let peopleHeader: DynamicsPeopleHeaderState? = (isLoggedIn && tabSelection.isPeopleMode)
            ? DynamicsPeopleHeaderState(
                people: peopleCatalog.recentPeople, selectedMID: tabSelection.authorMID,
                selectedPerson: peopleCatalog.person(for: tabSelection.authorMID),
                viewingPersonName: peopleCatalog.person(for: tabSelection.authorMID)?.displayName,
                isLoading: peopleCatalog.isLoadingRecent, hasLoaded: peopleCatalog.recentHasLoaded,
                hasMore: peopleCatalog.recentHasMore, failure: peopleCatalog.recentFailure,
                usesAccessibilityLayout: isAccessibilitySize
            )
            : nil
        snapshot = Snapshot(
            items: tabItems, fingerprints: tabItems.map(DynamicsItemFingerprint.init),
            peopleHeader: peopleHeader, feedbackState: feedbackState, usesInlinePeopleFeedback: usesInline,
            showsPaginationSpinner: viewModel.displayedIsLoading(for: tabSelection) && !tabItems.isEmpty,
            placeholderCount: (isLoggedIn && tabItems.isEmpty && feedbackState == .none) ? 3 : 0
        )
        return snapshot
    }
}

private struct DynamicsFeedTabView: View, Equatable {
    let tabSelection: DynamicFeedSelection
    let selectionKey: DynamicsSelectionKey
    let isSelected: Bool
    let viewModel: DynamicsViewModel
    let peopleCatalog: DynamicsFollowingPeopleCatalog
    let coordinator: AppCoordinator
    let onSelect: (DynamicFeedSelection) -> Void
    let onMoreFollowing: () -> Void
    let onPreviewImage: (ImagePreviewItem) -> Void
    let onCommentFallback: (DynamicFeedResult.DynamicItem) -> Void
    let onRepost: (DynamicFeedResult.DynamicItem) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var cache = DynamicsTabCache()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectionKey == rhs.selectionKey && lhs.isSelected == rhs.isSelected
            && lhs.viewModel === rhs.viewModel && lhs.peopleCatalog === rhs.peopleCatalog
            && lhs.coordinator === rhs.coordinator
    }

    var body: some View {
        let snap = isSelected
            ? cache.sync(
                tabSelection: tabSelection, viewModel: viewModel,
                peopleCatalog: peopleCatalog, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            : cache.snapshot
        let showsOverlay = !snap.usesInlinePeopleFeedback && snap.feedbackState != .none
        let inlineFeedback = snap.usesInlinePeopleFeedback ? snap.feedbackState : .none
        let renderKey = DynamicsRenderKey(
            fingerprints: snap.fingerprints, peopleHeader: snap.peopleHeader,
            inlineFeedback: DynamicsFeedbackKey(inlineFeedback), placeholderCount: snap.placeholderCount,
            scrollToTopTick: coordinator.scrollToTopTick, showsPaginationSpinner: snap.showsPaginationSpinner,
            isActive: isSelected, isDynamicsTabSelected: coordinator.selectedTab == .dynamics
        )

        ZStack {
            EquatableDynamicsCollectionHost(key: renderKey) {
                DynamicsFeedCollectionView(
                    items: snap.items,
                    interactionStore: viewModel.interactions,
                    peopleHeader: snap.peopleHeader,
                    inlineFeedback: inlineFeedback,
                    placeholderCount: snap.placeholderCount,
                    showsPaginationSpinner: snap.showsPaginationSpinner,
                    isActive: renderKey.isActive,
                    isDynamicsTabSelected: renderKey.isDynamicsTabSelected,
                    scrollToTopTick: renderKey.scrollToTopTick,
                    actions: makeCollectionActions()
                )
            }
            .contentLinks(presentsFeedback: false, isCurrent: { isSelected })
            .opacity(showsOverlay ? 0 : 1)
            .allowsHitTesting(!showsOverlay)
            .accessibilityHidden(showsOverlay)

            if showsOverlay {
                feedbackView(for: snap.feedbackState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func makeCollectionActions() -> DynamicsFeedCollectionActions {
        DynamicsFeedCollectionActions(
            onRefresh: {
                await viewModel.refresh()
                return false
            },
            onNearEndAppear: {
                guard tabSelection == viewModel.selection else { return }
                Task { await viewModel.load() }
            },
            onOpenPost: { postID in
                coordinator.navigate(to: .momentDetail(postID))
            },
            onOpenProfile: { mid in
                coordinator.navigate(to: .userSpace(mid))
            },
            onOpenVideo: { target in
                coordinator.navigateToVideo(target)
            },
            onOpenArticle: { cvid in
                coordinator.navigate(to: .articleReader(cvid))
            },
            onOpenLiveRoom: { roomID in
                coordinator.navigate(to: .liveRoom(roomID))
            },
            onImageTap: onPreviewImage,
            onRepost: onRepost,
            onComment: { item in
                if let postID = item.idStr, !postID.isEmpty {
                    coordinator.navigate(to: .momentDetail(postID))
                } else {
                    onCommentFallback(item)
                }
            },
            onLike: { item in
                Task { await viewModel.toggleLike(for: item) }
            },
            makePeopleHeader: { state in
                AnyView(peopleHeaderView(for: state))
            },
            makeFeedbackView: { state in
                AnyView(feedbackView(for: state))
            }
        )
    }

    private func peopleHeaderView(for state: DynamicsPeopleHeaderState) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            DynamicsFollowingPeopleRail(
                people: state.people,
                selectedMID: state.selectedMID,
                selectedPerson: state.selectedPerson,
                isLoading: state.isLoading,
                hasLoaded: state.hasLoaded,
                hasMore: state.hasMore,
                failure: state.failure,
                usesAccessibilityLayout: state.usesAccessibilityLayout,
                onSelectAll: { onSelect(.people(authorMID: nil)) },
                onSelect: { onSelect(.people(authorMID: $0.mid)) },
                onMore: onMoreFollowing,
                onLoadMore: { Task { await peopleCatalog.loadMoreRecentPeople() } },
                onRetry: { Task { await peopleCatalog.loadMoreRecentPeople() } }
            )

            if let viewingName = state.viewingPersonName {
                Text("Viewing \(viewingName)'s dynamics")
                    .appFont(.messageMeta)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.s)
            }
        }
    }

    @ViewBuilder
    private func feedbackView(for state: DynamicsEmptyFeedbackState) -> some View {
        switch state {
        case .none:
            EmptyView()
        case .signIn:
            signInState
        case .error(let message):
            errorState(message)
        case .empty(let selection):
            emptyState(for: selection)
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load Feed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(tabSelection == .category(.bangumi)
                ? message + "\n" + String(localized: "This usually means the account isn't following any anime yet.")
                : message)
        } actions: {
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func emptyState(for selection: DynamicFeedSelection) -> some View {
        switch selection {
        case .category(.all), .people(authorMID: nil):
            ContentUnavailableView(
                "No Moments",
                systemImage: "bolt.horizontal",
                description: Text("Posts from people you follow will appear here.")
            )
        case .category(.bangumi):
            ContentUnavailableView(
                "No Anime Updates",
                systemImage: "sparkles.tv",
                description: Text("Follow some anime and their updates will appear here.")
            )
        case .category(.article):
            ContentUnavailableView(
                "No Articles",
                systemImage: "doc.richtext",
                description: Text("Articles from people you follow will appear here.")
            )
        case .people:
            ContentUnavailableView(
                "No Moments",
                systemImage: "bolt.horizontal",
                description: Text("No dynamics from this person yet.")
            )
        }
    }

    private var signInState: some View {
        ContentUnavailableView {
            Label("Sign In Required", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("Sign in to view dynamics.")
        } actions: {
            Button("Sign In") { coordinator.presentLogin() }
        }
    }
}

private struct DynamicsTopHeaderBar: View, Equatable {
    let selection: DynamicFeedSelection
    let selectionKey: DynamicsSelectionKey
    let selectedAuthorMID: Int?
    let showsComposeButton: Bool
    let onSelect: (DynamicFeedSelection) -> Void
    let onCompose: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectionKey == rhs.selectionKey
            && lhs.selectedAuthorMID == rhs.selectedAuthorMID
            && lhs.showsComposeButton == rhs.showsComposeButton
    }

    private var tabItems: [SectionTabBar<String>.Item] {
        [
            .init(id: "all", label: Text(DynamicsViewModel.FeedFilter.all.title),
                  isSelected: selection == .category(.all)) { onSelect(.category(.all)) },
            .init(id: "people", label: Text("Following People"),
                  isSelected: selection.isPeopleMode) { onSelect(.people(authorMID: selectedAuthorMID)) },
            .init(id: "bangumi", label: Text(DynamicsViewModel.FeedFilter.bangumi.title),
                  isSelected: selection == .category(.bangumi)) { onSelect(.category(.bangumi)) },
            .init(id: "article", label: Text(DynamicsViewModel.FeedFilter.article.title),
                  isSelected: selection == .category(.article)) { onSelect(.category(.article)) }
        ]
    }

    var body: some View {
        HStack(spacing: 10) {
            SectionTabBar(items: tabItems, isScrollable: true, enablesSelectionHaptic: true)

            Spacer(minLength: 0)

            if showsComposeButton {
                AppTopBarCircleButton(
                    systemImage: "square.and.pencil",
                    accessibilityLabel: "New Moment",
                    action: onCompose
                )
            }
        }
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, 6)
        .frame(maxWidth: ReadableWidth.feed, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
