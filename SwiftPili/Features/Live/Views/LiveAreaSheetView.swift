import Kingfisher
import SwiftUI

struct LiveAreaSheet: View {
    let areas: [LiveParentArea]
    var initialParentID: Int?
    let selectedSection: LiveSection
    let onSelect: (LiveSection) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var query = ""
    @State private var focusedParentID: Int?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private struct AreaMatch: Identifiable {
        let parent: LiveParentArea
        let area: LiveParentArea.LiveArea
        var id: String { "\(parent.id)-\(area.id)" }
    }

    private var matches: [AreaMatch] {
        guard !trimmedQuery.isEmpty else { return [] }
        return areas.flatMap { parent in
            parent.list
                .filter { $0.name.localizedStandardContains(trimmedQuery) }
                .map { AreaMatch(parent: parent, area: $0) }
        }
    }

    private var tileColumns: [GridItem] {
        let isRegular = horizontalSizeClass == .regular
        let minimum: CGFloat = isRegular ? 148 : 100
        let spacing: CGFloat = isRegular ? AppSpacing.m : 10
        return [GridItem(.adaptive(minimum: minimum), spacing: spacing, alignment: .top)]
    }

    private func isSelectedAreaMatch(parentID: Int, areaID: Int) -> Bool {
        if case let .area(activeParent, activeArea, _) = selectedSection {
            return activeParent == parentID && activeArea == areaID
        }
        return false
    }

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            Group {
                if areas.isEmpty {
                    ContentUnavailableView(
                        "No Categories",
                        systemImage: "tag",
                        description: Text("Could not load the live category list.")
                    )
                } else if !trimmedQuery.isEmpty {
                    searchResults
                } else {
                    categoryBrowser
                }
            }
            .navigationTitle("All Tags")
            .navigationBarTitleDisplayMode(.inline)
            .appAmbientBrowseBackground()
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search categories"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .modifier(LiveAreaSheetSizing(isRegular: horizontalSizeClass == .regular))
        .onAppear {
            focusedParentID = initialParentID ?? areas.first?.id
        }
    }

    private var selectedParent: LiveParentArea? {
        areas.first { $0.id == focusedParentID } ?? areas.first
    }

    private var usesSplitBrowser: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    @ViewBuilder
    private var categoryBrowser: some View {
        if usesSplitBrowser {
            splitBrowser
        } else {
            compactBrowser
        }
    }

    private var compactBrowser: some View {
        VStack(spacing: 0) {
            LiveAreaQuickJumpBar(
                areas: areas,
                activeParentID: selectedParent?.id,
                onSelectParent: { focusedParentID = $0 }
            )
            Divider()
                .opacity(0.4)
            selectedParentContent
        }
    }

    private var splitBrowser: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(areas) { parent in
                        LiveAreaParentRow(
                            name: parent.name,
                            isActive: parent.id == selectedParent?.id
                        ) { focusedParentID = parent.id }
                    }
                }
                .padding(.horizontal, AppSpacing.m)
                .padding(.vertical, AppSpacing.l)
            }
            .frame(width: 212)
            Divider()
                .opacity(0.4)
            selectedParentContent
        }
    }

    @ViewBuilder
    private var selectedParentContent: some View {
        if let parent = selectedParent {
            let isRegular = horizontalSizeClass == .regular
            ScrollView {
                LiveAreaSectionView(
                    parent: parent,
                    columns: tileColumns,
                    isRegularWidth: isRegular,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    isSelectedArea: isSelectedAreaMatch,
                    onSelect: onSelect
                )
                .padding(.horizontal, isRegular ? AppSpacing.xl : AppSpacing.l)
                .padding(.vertical, isRegular ? AppSpacing.xl : AppSpacing.l)
            }
            .id(parent.id)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if matches.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            List {
                Section {
                    ForEach(matches) { match in
                        let isSelected = isSelectedAreaMatch(
                            parentID: match.parent.id,
                            areaID: match.area.id
                        )
                        LiveAreaRowView(
                            area: match.area,
                            subtitle: match.parent.name,
                            isSelected: isSelected
                        ) {
                            onSelect(.area(
                                parentID: match.parent.id,
                                areaID: match.area.id,
                                name: match.area.name
                            ))
                        }
                        .listRowBackground(isSelected ? Color.biliAccent.opacity(0.12) : AppFill.card)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }
}

private struct LiveAreaQuickJumpBar: View {
    let areas: [LiveParentArea]
    let activeParentID: Int?
    let onSelectParent: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { barProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xs) {
                    ForEach(areas) { parent in
                        let isActive = activeParentID == parent.id
                        Button {
                            onSelectParent(parent.id)
                        } label: {
                            Text(parent.name)
                                .font(.footnote.weight(isActive ? .semibold : .medium))
                                .foregroundStyle(isActive ? Color.biliAccent : Color.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, AppSpacing.m)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(isActive ? Color.biliAccent.opacity(0.14) : AppFill.nested)
                                )
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.appControl)
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                        .id(parent.id)
                    }
                }
                .padding(.horizontal, AppSpacing.l)
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onAppear {
                scrollBar(using: barProxy, to: activeParentID, animated: false)
            }
            .onChange(of: activeParentID) { _, newValue in
                scrollBar(using: barProxy, to: newValue, animated: !reduceMotion)
            }
        }
    }

    private func scrollBar(using proxy: ScrollViewProxy, to parentID: Int?, animated: Bool) {
        guard let parentID else { return }
        if animated {
            withAnimation(.snappy(duration: 0.25)) {
                proxy.scrollTo(parentID, anchor: .center)
            }
        } else {
            proxy.scrollTo(parentID, anchor: .center)
        }
    }
}

private struct LiveAreaSectionView: View {
    let parent: LiveParentArea
    let columns: [GridItem]
    let isRegularWidth: Bool
    let isAccessibilitySize: Bool
    let isSelectedArea: (Int, Int) -> Bool
    let onSelect: (LiveSection) -> Void

    var body: some View {
        let allSelected = isSelectedArea(parent.id, 0)
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            HStack(alignment: .center, spacing: AppSpacing.m) {
                Text(parent.name)
                    .font(isRegularWidth ? .title2.weight(.bold) : .title3.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer(minLength: AppSpacing.s)
                Button {
                    onSelect(.area(parentID: parent.id, areaID: 0, name: parent.name))
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Text("All")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(allSelected ? Color.biliAccent : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(allSelected ? Color.biliAccent.opacity(0.14) : AppFill.card))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appControl)
                .accessibilityLabel(String(localized: "All of \(parent.name)"))
                .accessibilityAddTraits(allSelected ? .isSelected : [])
            }

            if isAccessibilitySize {
                accessibilityRows
            } else if !parent.list.isEmpty {
                gridContent
            }
        }
    }

    private var accessibilityRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(parent.list.enumerated()), id: \.element.id) { index, area in
                let isSelected = isSelectedArea(parent.id, area.id)
                LiveAreaRowView(area: area, isSelected: isSelected) {
                    onSelect(.area(parentID: parent.id, areaID: area.id, name: area.name))
                }
                .padding(.horizontal, AppSpacing.m)
                .background(isSelected ? Color.biliAccent.opacity(0.12) : Color.clear)

                if index < parent.list.count - 1 {
                    Divider().padding(.leading, 60)
                }
            }
        }
        .background(AppFill.card)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    private var gridContent: some View {
        LazyVGrid(columns: columns, spacing: isRegularWidth ? AppSpacing.m : 10) {
            ForEach(parent.list) { area in
                LiveAreaGridTile(
                    area: area,
                    isRegularWidth: isRegularWidth,
                    isSelected: isSelectedArea(parent.id, area.id)
                ) {
                    onSelect(.area(parentID: parent.id, areaID: area.id, name: area.name))
                }
            }
        }
    }
}

private struct LiveAreaGridTile: View {
    let area: LiveParentArea.LiveArea
    let isRegularWidth: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var iconFailed = false

    private var showsIcon: Bool {
        guard let pic = area.pic, !pic.isEmpty else { return false }
        return !iconFailed
    }

    var body: some View {
        Button(action: action) { tileBody.contentShape(Rectangle()) }
            .buttonStyle(.appControl)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var tileBody: some View {
        let fill = isSelected ? Color.biliAccent.opacity(0.14) : AppFill.card
        let textColor = isSelected ? Color.biliAccent : Color.primary
        if showsIcon {
            VStack(spacing: AppSpacing.s) {
                LiveAreaIconView(pic: area.pic, onFailure: { iconFailed = true })
                Text(area.name)
                    .font((isRegularWidth ? Font.subheadline : Font.footnote).weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(textColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: isRegularWidth ? 96 : 86, maxHeight: .infinity)
            .padding(AppSpacing.m)
            .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous).fill(fill))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(Color.biliAccent)
                        .padding(8).accessibilityHidden(true)
                }
            }
        } else {
            HStack(spacing: AppSpacing.xs) {
                Text(area.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(textColor).lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(Color.biliAccent).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, AppSpacing.m).padding(.vertical, AppSpacing.s)
            .background(Capsule().fill(fill))
        }
    }
}

private struct LiveAreaRowView: View {
    let area: LiveParentArea.LiveArea
    var subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.m) {
                LiveAreaIconView(pic: area.pic)
                VStack(alignment: .leading, spacing: 2) {
                    Text(area.name)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.biliAccent : Color.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: AppSpacing.xs)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.biliAccent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .padding(.vertical, AppSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LiveAreaSheetSizing: ViewModifier {
    let isRegular: Bool

    func body(content: Content) -> some View {
        if isRegular, #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}

private struct LiveAreaParentRow: View {
    let name: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.subheadline.weight(isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Color.biliAccent : Color.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .background(Capsule().fill(isActive ? Color.biliAccent.opacity(0.14) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.appControl)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct LiveAreaIconView: View {
    let pic: String?
    var onFailure: (() -> Void)?
    private let size: CGFloat = 44
    private let inset: CGFloat = 5
    private var inner: CGFloat { size - inset * 2 }

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadFailed = false

    private var imageURL: URL? {
        guard let pic, !pic.isEmpty else { return nil }
        let pixels = inner * displayScale
        return URL(string: pic.httpsURL.biliResized(toPixel: CGSize(width: pixels, height: pixels)))
    }

    var body: some View {
        if let imageURL, !loadFailed {
            KFImage(imageURL)
                .setProcessor(DownsamplingImageProcessor(size: CGSize(width: inner, height: inner)))
                .scaleFactor(displayScale)
                .cancelOnDisappear(true)
                .imageFadePolicy(reduceMotion: reduceMotion)
                .onFailure { _ in loadFailed = true; onFailure?() }
                .resizable()
                .scaledToFit()
                .padding(inset)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous).fill(AppFill.nested))
                .accessibilityHidden(true)
        }
    }
}
