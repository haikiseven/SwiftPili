import SwiftData
import SwiftUI

struct SearchView: View {
    @State private var viewModel: SearchViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SearchHistoryItem.searchedAt, order: .reverse) private var searchHistory: [SearchHistoryItem]
    @FocusState private var isSearchFocused: Bool
    @State private var contentWidth: CGFloat = FeedWidth.seed
    @State private var isScreenVisible = false

    /// Non-nil when opened from a video tag; runs automatically on appear.
    private let initialKeyword: String?

    init(initialType: SearchType = .all, initialKeyword: String? = nil) {
        let model = SearchViewModel(initialType: initialType)
        if let initialKeyword, !initialKeyword.isEmpty { model.keyword = initialKeyword }
        _viewModel = State(initialValue: model)
        self.initialKeyword = initialKeyword
    }

    private var showsSuggestions: Bool {
        guard isSearchFocused, !viewModel.suggestions.isEmpty else { return false }
        let trimmed = viewModel.keyword.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && (!viewModel.hasSearched || trimmed != viewModel.submittedQuery?.term)
    }

    private var showsFilterBar: Bool {
        viewModel.selectedType != .bangumi && viewModel.selectedType != .liveRoom
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchHeaderBar(viewModel: viewModel, isSearchFocused: $isSearchFocused, onSubmit: runSearch)
                .searchReadableColumn()
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if viewModel.hasSearched {
                        typePicker
                        if showsFilterBar { SearchFilterBar(viewModel: viewModel, onRunRequest: performRequest) }
                        resultsList
                    } else {
                        idleContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if showsSuggestions {
                    SearchSuggestionsOverlay(
                        suggestions: viewModel.suggestions,
                        onSelectSuggestion: { viewModel.keyword = $0.value; runSearch() },
                        onFillSuggestion: { viewModel.updateKeyword($0.value); isSearchFocused = true }
                    )
                    .searchReadableColumn()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .guardIPadTopSafeArea()
        .appAmbientBrowseBackground()
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            FeedPerformanceSignposts.screenAdmission(.search)
            async let hotWords: Void = viewModel.loadHotWords()
            async let defaultTerm: Void = viewModel.loadDefaultSearchTerm()
            _ = await (hotWords, defaultTerm)
        }
        .onAppear {
            isScreenVisible = true
            if viewModel.keyword.isEmpty { isSearchFocused = true } else if initialKeyword != nil {
                if !viewModel.hasSearched { runSearch() }
            }
        }
        .onDisappear { isScreenVisible = false }
        .onChange(of: isSearchFocused) { _, focused in if !focused { viewModel.clearSuggestions() } }
    }

    // MARK: - Idle: history + trending

    private var idleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !searchHistory.isEmpty { historySection }
                if !viewModel.hotWords.isEmpty { trendingSection }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .measuringContentWidth(into: $contentWidth).padding(AppSpacing.l)
            .searchReadableColumn()
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History").appFont(.sectionTitle)
                Spacer()
                Button { for item in searchHistory { modelContext.delete(item) } } label: {
                    Image(systemName: "trash").font(.subheadline).foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.appControl).accessibilityLabel(Text("Clear"))
            }
            FlowLayout(spacing: 8) {
                ForEach(searchHistory.prefix(20)) { item in
                    Button { viewModel.keyword = item.keyword; runSearch() } label: {
                        Text(item.keyword).appFont(.messageTitle).foregroundStyle(.primary).lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color(.quaternarySystemFill)))
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.appControl)
                }
            }
        }
    }

    /// BiliBili hot search terms (搜索热词), ranked grid.
    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").font(.subheadline).foregroundStyle(.orange)
                Text("Trending").appFont(.sectionTitle)
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12),
                    count: contentWidth >= 700 ? 3 : 2
                ),
                alignment: .leading, spacing: 4
            ) {
                ForEach(Array(viewModel.hotWords.prefix(20).enumerated()), id: \.element.id) { index, word in
                    Button { viewModel.keyword = word.keyword; runSearch() } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .appFont(.messageMeta, monospacedDigit: true).fontWeight(.bold).monospacedDigit()
                                .foregroundStyle(index < 3 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                                .frame(width: 18, alignment: .center)
                            Text(word.showName ?? word.keyword)
                                .appFont(.messageTitle).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Result Type Tabs & Results

    private static let tabKeys: [SearchType: String] = [
        .all: "SearchTabAll", .video: "Videos", .bangumi: "Bangumi",
        .liveRoom: "Live", .user: "Users", .article: "Articles",
    ]

    private var typePicker: some View {
        SectionTabBar(
            values: [SearchType.all, .video, .bangumi, .liveRoom, .user, .article],
            selection: viewModel.selectedType,
            isScrollable: true,
            enablesSelectionHaptic: true,
            label: { Text(LocalizedStringKey(Self.tabKeys[$0] ?? "SearchTabAll")) },
            onSelect: switchSearchType
        )
        // Leading-aligned like Home's and Dynamics' section bars; the bar's own
        // 4pt inset puts the first title on the page's 16pt content margin.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.bottom, showsFilterBar ? 0 : 8)
    }

    @ViewBuilder
    private var resultsList: some View {
        let model = viewModel
        if let query = model.submittedQuery {
            let showsEmpty = !model.hasResults && !model.isSearching
            ZStack {
                SearchResultsCollectionView(
                    searchType: query.type, generation: model.resultGeneration,
                    buckets: model.allBuckets.map(makeBucketData),
                    items: model.results.map { makeResultData($0, type: query.type) },
                    isSearching: model.isSearching,
                    isActive: isScreenVisible && !showsEmpty && !showsSuggestions,
                    isTabSelected: isScreenVisible, scrollToTopTick: coordinator.scrollToTopTick,
                    actions: SearchResultsActions(
                        isCurrentResult: { model.isCurrentResult(generation: $0) },
                        onLoadMore: { performRequest(model.prepareLoadMore(generation: $0)) },
                        onSelectVideo: { coordinator.navigateToVideo($0) },
                        onSelectLiveRoom: { coordinator.navigate(to: .liveRoom($0, zoom: .none)) },
                        onSelectUser: { coordinator.navigate(to: .userSpace($0)) },
                        onSelectBangumi: { coordinator.navigate(to: .bangumiDetail($0, zoom: .none)) },
                        onSelectArticle: { coordinator.navigate(to: .articleReader($0)) },
                        onSwitchToType: switchSearchType
                    )
                )
                .opacity(showsEmpty ? 0 : 1).allowsHitTesting(!showsEmpty).accessibilityHidden(showsEmpty)
                if showsEmpty {
                    ContentUnavailableView.search(text: query.term).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - Actions

    private func runSearch() { performRequest(viewModel.prepareSearch(modelContext: modelContext)) }
    private func switchSearchType(to type: SearchType) { performRequest(viewModel.prepareTypeChange(to: type)) }
    private func performRequest(_ request: SearchViewModel.PreparedRequest?) {
        isSearchFocused = false
        guard let request else { return }
        let model = viewModel
        Task { await model.perform(request) }
    }
}

// MARK: - Snapshot Mapping

extension SearchView {
    private func makeBucketData(_ bucket: SearchViewModel.AllSearchBucket) -> SearchAllBucketData {
        .init(
            targetType: bucket.targetType,
            items: bucket.items.map { makeResultData($0, type: bucket.targetType) },
            totalCount: bucket.totalCount, hasMore: bucket.hasMore
        )
    }

    private func makeResultData(_ result: SearchViewModel.PreparedResult, type: SearchType) -> SearchResultItemData {
        let item = result.item
        let kind: SearchResultItemData.Kind
        switch type {
        case .all, .video:
            kind = .video(.init(
                title: result.displayTitle, sources: VideoCoverSources(widescreen: Self.fixScheme(item.pic)),
                durationSeconds: result.durationSeconds, author: item.author ?? "",
                playCount: item.play ?? 0, routeTarget: Self.routeTarget(result)
            ))
        case .bangumi:
            kind = .bangumi(.init(
                seasonID: item.seasonId, title: result.displayTitle,
                coverURL: Self.fixScheme(item.cover ?? item.pic), seasonTypeName: item.seasonTypeName,
                score: item.mediaScore?.score, userCount: item.mediaScore?.userCount,
                areas: item.areas, styles: item.styles, indexShow: item.indexShow, desc: result.displayDesc
            ))
        case .user: kind = .user(makeUserPayload(result))
        case .liveRoom:
            kind = .liveRoom(.init(
                roomID: item.roomid, title: result.displayTitle, uname: item.uname ?? item.author ?? "",
                areaName: item.areaName ?? item.cateName,
                coverURL: Self.fixScheme(item.liveArtwork ?? item.pic),
                online: item.online ?? item.play ?? 0, liveStatus: item.liveStatus
            ))
        case .article:
            let cover = Self.fixScheme(item.imageUrls?.first ?? item.pic)
            kind = .article(.init(
                articleID: item.articleId ?? item.aid, title: result.displayTitle,
                coverURL: cover.isEmpty ? nil : cover, author: item.author ?? item.uname ?? "",
                categoryName: item.categoryName, viewCount: item.view ?? item.play ?? 0,
                likeCount: item.like ?? 0, desc: result.displayDesc
            ))
        }
        return SearchResultItemData(id: result.id, kind: kind)
    }

    private func makeUserPayload(_ result: SearchViewModel.PreparedResult) -> SearchResultItemData.UserPayload {
        let item = result.item, ownerName = item.uname ?? item.author ?? ""
        let repVideos: [SearchRepresentativeVideoData] = (item.res ?? []).map { rep in
            let cover = Self.fixScheme(rep.pic)
            return .init(
                id: rep.id, title: rep.cleanTitle, sources: VideoCoverSources(widescreen: cover),
                durationSeconds: rep.durationSeconds, playCount: rep.play ?? 0,
                routeTarget: .make(
                    bvid: rep.bvid, aid: rep.aid, title: rep.cleanTitle, coverURL: cover,
                    ownerName: ownerName, durationSeconds: rep.durationSeconds
                )
            )
        }
        return .init(
            mid: item.mid, uname: item.uname ?? result.displayTitle,
            avatarURL: Self.fixScheme(item.upic ?? item.pic),
            officialVerifyType: item.officialVerify?.type, officialVerifyDesc: item.officialVerify?.desc,
            fans: item.fans ?? 0, videos: item.videos ?? 0, usign: item.usign ?? result.displayDesc,
            isLive: item.isLive ?? false, representativeVideos: repVideos
        )
    }

    /// Search covers arrive scheme-relative ("//i0.hdslb.com/…").
    static func fixScheme(_ pic: String?) -> String {
        guard let pic else { return "" }
        if pic.hasPrefix("//") { return "https:" + pic }
        return pic.replacingOccurrences(of: "http://", with: "https://")
    }

    private static func routeTarget(_ result: SearchViewModel.PreparedResult) -> VideoRouteTarget? {
        let item = result.item
        return .make(
            bvid: item.bvid, aid: item.aid, title: result.displayTitle,
            coverURL: fixScheme(item.pic), ownerName: item.author ?? "", durationSeconds: result.durationSeconds
        )
    }
}

// MARK: - Readable Column

private extension View {
    /// Centers search chrome in the feed's readable column on wide iPad
    /// windows; below the cap the content fills the width unchanged.
    func searchReadableColumn() -> some View {
        frame(maxWidth: ReadableWidth.feed).frame(maxWidth: .infinity)
    }
}

// MARK: - Header Bar

/// Isolates keystroke-level `viewModel.keyword` edits from `SearchView`'s
/// result grid and idle history/trending tree.
private struct SearchHeaderBar: View {
    @Bindable var viewModel: SearchViewModel
    var isSearchFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var keywordBinding: Binding<String> {
        Binding(get: { viewModel.keyword }, set: { viewModel.updateKeyword($0) })
    }

    private var placeholderPrompt: Text {
        if let showName = viewModel.defaultSearchTerm?.showName, !showName.isEmpty { return Text(verbatim: showName) }
        return Text("Search videos, users, live rooms")
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: keywordBinding, prompt: placeholderPrompt)
                    .focused(isSearchFocused).submitLabel(.search).autocorrectionDisabled().onSubmit(onSubmit)
                if !viewModel.keyword.isEmpty {
                    Button { viewModel.clearSearch(); isSearchFocused.wrappedValue = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .padding(.vertical, -9).padding(.trailing, -8).accessibilityLabel(Text("Clear"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
            if isSearchFocused.wrappedValue {
                Button("Cancel") { viewModel.cancelEditing(); isSearchFocused.wrappedValue = false }
                    .foregroundStyle(.primary).frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .animation(reduceMotion ? nil : KeyboardAnimation.current, value: isSearchFocused.wrappedValue)
    }
}

private struct SearchSuggestionsOverlay: View {
    let suggestions: [SearchSuggestion]
    let onSelectSuggestion: (SearchSuggestion) -> Void
    let onFillSuggestion: (SearchSuggestion) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    HStack(spacing: 4) {
                        Button { onSelectSuggestion(suggestion) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(.secondary)
                                highlightedText(for: suggestion).appFont(.messageTitle).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { onFillSuggestion(suggestion) } label: {
                            Image(systemName: "arrow.up.left").font(.subheadline).foregroundStyle(.secondary)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(Text("Fill search term"))
                    }
                    .padding(.leading, 16).padding(.trailing, 8)
                    if index < suggestions.count - 1 { Divider().opacity(0.45).padding(.leading, 44) }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollDismissesKeyboard(.immediately)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).appAmbientBrowseBackground()
    }

    private func highlightedText(for suggestion: SearchSuggestion) -> Text {
        suggestion.segments.reduce(Text("")) { partial, segment in
            partial + Text(verbatim: segment.text)
                .foregroundStyle(segment.isHighlighted ? Color.biliAccent : .primary)
                .fontWeight(segment.isHighlighted ? .semibold : .regular)
        }
    }
}
