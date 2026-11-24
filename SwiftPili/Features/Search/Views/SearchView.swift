import SwiftData
import SwiftUI

struct SearchView: View {
    @State private var viewModel: SearchViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isSearchFocused: Bool
    @State private var isScreenVisible = false

    private let initialKeyword: String?

    init(initialType: SearchType = .all, initialKeyword: String? = nil) {
        let model = SearchViewModel(initialType: initialType)
        if let initialKeyword, !initialKeyword.isEmpty { model.keyword = initialKeyword }
        _viewModel = State(initialValue: model)
        self.initialKeyword = initialKeyword
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchHeaderBar(viewModel: viewModel, isSearchFocused: $isSearchFocused, onSubmit: runSearch)
                .searchReadableColumn()
            ZStack(alignment: .topLeading) {
                Group {
                    if viewModel.hasSearched {
                        SearchResultsContainer(
                            viewModel: viewModel,
                            coordinator: coordinator,
                            isScreenVisible: isScreenVisible,
                            isSearchFocused: isSearchFocused,
                            onSwitchType: switchSearchType,
                            onRunRequest: performRequest
                        )
                    } else {
                        SearchIdleContentView(
                            viewModel: viewModel,
                            onSelectKeyword: { keyword in
                                viewModel.keyword = keyword
                                runSearch()
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                SearchSuggestionsHost(
                    viewModel: viewModel,
                    isSearchFocused: isSearchFocused,
                    onSelectSuggestion: { viewModel.keyword = $0.value; runSearch() },
                    onFillSuggestion: { viewModel.updateKeyword($0.value); isSearchFocused = true }
                )
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

    // MARK: - Actions

    private func runSearch() { performRequest(viewModel.prepareSearch(modelContext: modelContext)) }
    private func switchSearchType(to type: SearchType) { performRequest(viewModel.prepareTypeChange(to: type)) }
    private func performRequest(_ request: SearchViewModel.PreparedRequest?) {
        isSearchFocused = false
        guard let request else { return }
        let model = viewModel
        Task { await model.perform(request) }
    }

    static func fixScheme(_ pic: String?) -> String {
        guard let pic else { return "" }
        if pic.hasPrefix("//") { return "https:" + pic }
        return pic.replacingOccurrences(of: "http://", with: "https://")
    }
}

// MARK: - Idle: history + trending

private struct SearchIdleContentView: View {
    let viewModel: SearchViewModel
    let onSelectKeyword: (String) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SearchHistoryItem.searchedAt, order: .reverse) private var searchHistory: [SearchHistoryItem]
    @State private var contentWidth: CGFloat = FeedWidth.seed

    var body: some View {
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
                    Button { onSelectKeyword(item.keyword) } label: {
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
                    Button { onSelectKeyword(word.keyword) } label: {
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
}

// MARK: - Results Container

private struct SearchResultsContainer: View {
    let viewModel: SearchViewModel
    let coordinator: AppCoordinator
    let isScreenVisible: Bool
    let isSearchFocused: Bool
    let onSwitchType: (SearchType) -> Void
    let onRunRequest: (SearchViewModel.PreparedRequest?) -> Void

    private static let tabKeys: [SearchType: String] = [
        .all: "SearchTabAll", .video: "Videos", .bangumi: "Bangumi",
        .liveRoom: "Live", .user: "Users", .article: "Articles",
    ]

    private var showsFilterBar: Bool {
        viewModel.selectedType != .bangumi && viewModel.selectedType != .liveRoom
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionTabBar(
                values: [SearchType.all, .video, .bangumi, .liveRoom, .user, .article],
                selection: viewModel.selectedType,
                isScrollable: true,
                enablesSelectionHaptic: true,
                label: { Text(LocalizedStringKey(Self.tabKeys[$0] ?? "SearchTabAll")) },
                onSelect: onSwitchType
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.bottom, showsFilterBar ? 0 : 8)

            if showsFilterBar {
                SearchFilterBar(viewModel: viewModel, onRunRequest: { onRunRequest($0) })
            }

            if let query = viewModel.submittedQuery {
                let showsEmpty = !viewModel.hasResults && !viewModel.isSearching
                let showsSuggestions = isSearchFocused && viewModel.hasEligibleSuggestions
                ZStack {
                    SearchResultsCollectionView(
                        searchType: query.type,
                        generation: viewModel.resultGeneration,
                        buckets: viewModel.preparedBuckets,
                        items: viewModel.preparedItems,
                        snapshotRevision: viewModel.snapshotRevision,
                        isSearching: viewModel.isSearching,
                        isActive: isScreenVisible && !showsEmpty && !showsSuggestions,
                        isTabSelected: isScreenVisible,
                        scrollToTopTick: coordinator.scrollToTopTick,
                        actions: SearchResultsActions(
                            isCurrentResult: { viewModel.isCurrentResult(generation: $0) },
                            onLoadMore: { onRunRequest(viewModel.prepareLoadMore(generation: $0)) },
                            onSelectVideo: { coordinator.navigateToVideo($0) },
                            onSelectLiveRoom: { coordinator.navigate(to: .liveRoom($0, zoom: .none)) },
                            onSelectUser: { coordinator.navigate(to: .userSpace($0)) },
                            onSelectBangumi: { coordinator.navigate(to: .bangumiDetail($0, zoom: .none)) },
                            onSelectArticle: { coordinator.navigate(to: .articleReader($0)) },
                            onSwitchToType: onSwitchType
                        )
                    )
                    .opacity(showsEmpty ? 0 : 1).allowsHitTesting(!showsEmpty).accessibilityHidden(showsEmpty)
                    if showsEmpty {
                        ContentUnavailableView.search(text: query.term)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

private struct SearchSuggestionsHost: View {
    let viewModel: SearchViewModel
    let isSearchFocused: Bool
    let onSelectSuggestion: (SearchSuggestion) -> Void
    let onFillSuggestion: (SearchSuggestion) -> Void

    var body: some View {
        if isSearchFocused && viewModel.hasEligibleSuggestions {
            SearchSuggestionsOverlay(
                suggestions: viewModel.suggestions,
                onSelectSuggestion: onSelectSuggestion,
                onFillSuggestion: onFillSuggestion
            )
            .searchReadableColumn()
        }
    }
}

// MARK: - Readable Column

private extension View {
    func searchReadableColumn() -> some View {
        frame(maxWidth: ReadableWidth.feed).frame(maxWidth: .infinity)
    }
}

// MARK: - Header Bar

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
