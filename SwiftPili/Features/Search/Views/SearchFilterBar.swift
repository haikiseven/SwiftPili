import SwiftUI

// MARK: - Filter Bar

struct SearchFilterBar: View {
    let viewModel: SearchViewModel
    let onRunRequest: (SearchViewModel.PreparedRequest) -> Void

    var body: some View {
        filters
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if hasFilters { Divider().opacity(0.35) }
            }
    }

    private var hasFilters: Bool {
        switch viewModel.selectedType {
        case .all, .video, .user, .article: true
        case .bangumi, .liveRoom: false
        }
    }

    @ViewBuilder
    private var filters: some View {
        switch viewModel.selectedType {
        case .all, .video:
            HStack(spacing: 12) {
                toggles(SearchVideoOrder.allCases, selected: viewModel.videoOrder, label: { $0.label }, onSelect: {
                    if let req = viewModel.prepareFilterChange(videoOrder: $0) { onRunRequest(req) }
                })
                durationMenu
            }
            .padding(.horizontal, 16)
        case .user:
            toggles(SearchUserOrder.allCases, selected: viewModel.userOrder, label: { $0.label }, onSelect: {
                if let req = viewModel.prepareFilterChange(userOrder: $0) { onRunRequest(req) }
            })
            .padding(.horizontal, 16)
        case .article:
            toggles(SearchArticleOrder.allCases, selected: viewModel.articleOrder, label: { $0.label }, onSelect: {
                if let req = viewModel.prepareFilterChange(articleOrder: $0) { onRunRequest(req) }
            })
            .padding(.horizontal, 16)
        case .bangumi, .liveRoom: EmptyView()
        }
    }

    private func toggles<Option: Hashable>(
        _ options: [Option], selected: Option,
        label: @escaping (Option) -> LocalizedStringKey, onSelect: @escaping (Option) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let isSelected = option == selected
                    Button { onSelect(option) } label: {
                        pill(isActive: isSelected) { Text(label(option)) }
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var durationMenu: some View {
        let isFiltered = viewModel.duration != .all
        return Menu {
            ForEach(SearchDuration.allCases, id: \.self) { option in
                Button {
                    if let req = viewModel.prepareFilterChange(duration: option) { onRunRequest(req) }
                } label: {
                    if option == viewModel.duration {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            pill(isActive: isFiltered) {
                HStack(spacing: 4) {
                    Text(viewModel.duration.label)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
            }
        }
        .accessibilityLabel(Text("Filter by duration"))
    }

    private func pill<Content: View>(isActive: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .appFont(.libraryRowMeta).fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? Color.biliAccent : .secondary).lineLimit(1)
            .padding(.vertical, 5).padding(.horizontal, 11)
            .background(Capsule().fill(isActive ? Color.biliAccent.opacity(0.14) : Color.clear))
            .frame(minHeight: 44).contentShape(Rectangle())
    }
}

private extension SearchVideoOrder {
    var label: LocalizedStringKey {
        switch self {
        case .totalrank: "SearchSortComprehensive"
        case .click: "Most Played"
        case .pubdate: "Newest"
        case .danmaku: "Most Danmaku"
        }
    }
}

private extension SearchDuration {
    var label: LocalizedStringKey {
        switch self {
        case .all: "All Durations"
        case .under10: "Under 10 min"
        case .tenTo30: "10-30 min"
        case .thirtyTo60: "30-60 min"
        case .over60: "Over 60 min"
        }
    }
}

private extension SearchUserOrder {
    var label: LocalizedStringKey {
        switch self {
        case .defaultOrder: "SearchSortDefault"
        case .fans: "SearchSortFans"
        case .level: "Level"
        }
    }
}

private extension SearchArticleOrder {
    var label: LocalizedStringKey {
        switch self {
        case .totalrank: "SearchSortComprehensive"
        case .click: "Most Read"
        case .pubdate: "Newest"
        case .attention: "Most Liked"
        }
    }
}
