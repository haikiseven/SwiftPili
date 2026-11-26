import SwiftData
import SwiftUI
import UIKit

enum DownloadSortOption: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded
    case largestSize
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyAdded: String(localized: "Recently Added")
        case .largestSize: String(localized: "Largest Size")
        case .title: String(localized: "Title")
        }
    }
}

struct DownloadSeriesGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let coverURL: String
    let episodes: [DownloadedVideo]
    let totalBytes: Int64
    let latestAddedAt: Date
    let brokenCount: Int
    let isBangumiSeason: Bool
}

enum DownloadDisplayEntry: Identifiable {
    case single(DownloadedVideo)
    case series(DownloadSeriesGroup)

    var id: String {
        switch self {
        case .single(let item): "single:\(item.id)"
        case .series(let group): "series:\(group.id)"
        }
    }

    var sortDate: Date {
        switch self {
        case .single(let item): item.addedAt
        case .series(let group): group.latestAddedAt
        }
    }

    var sortBytes: Int64 {
        switch self {
        case .single(let item): item.fileSizeBytes
        case .series(let group): group.totalBytes
        }
    }

    var sortTitle: String {
        switch self {
        case .single(let item): item.title
        case .series(let group): group.title
        }
    }
}

struct DownloadsView: View {
    @Query(sort: \DownloadedVideo.addedAt, order: .reverse)
    var downloads: [DownloadedVideo]
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var search = ""
    @State private var sortOption: DownloadSortOption = .recentlyAdded
    @State private var groupSeries = true
    @State var expandedGroupIDs: Set<String> = []
    @State private var showCleanMissingConfirm = false
    @State var pendingGroupDelete: DownloadSeriesGroup?
    @State private var notice: ToastMessage?
    @State private var invalidDownloadID: String?
    @State private var activeError: ActiveErrorPresentation?
    @State var brokenIDs: Set<String> = []
    let manager = DownloadManager.shared
    let exports = DownloadExportCoordinator.shared
    @State var exportRequest: ExportPresentation?
    @State var saveRequest: ExportSavePresentation?
    @State var exportError: String?
    @State var mutationRequest: ExportMutationPresentation?
    @State private var containerWidth: CGFloat = FeedWidth.fullContainerSeed

    static let gridHorizontalHalfGap: CGFloat = AppSpacing.m / 2
    static let gridVerticalHalfGap: CGFloat = AppSpacing.xs
    static let trailingMenuTitleInset: CGFloat = 36
    private static let maximumContentWidth: CGFloat = LibraryRowMetrics.maximumContentWidth

    struct ExportPresentation: Identifiable {
        let id = UUID()
        let source: DownloadExportSource
    }
    struct ExportSavePresentation: Identifiable {
        let id: UUID
        let fileURL: URL
    }
    struct ExportMutationPresentation {
        let downloadID: String
        let folderName: String
        let addedAt: Date
        let redownload: Bool
    }
    struct ActiveErrorPresentation {
        let downloadID: String
        let message: String
    }

    private var usesSidebarLayout: Bool {
        ShellNavigationPolicy.showsSidebar(
            isPad: DeviceCapability.supportsPadDetailSplit,
            isRegularWidth: sizeClass == .regular
        )
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespaces)
    }

    private var filtered: [DownloadedVideo] {
        let trimmedQuery = query
        var result = downloads
        if !trimmedQuery.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                    || $0.ownerName.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }
        switch sortOption {
        case .recentlyAdded:
            result.sort { $0.addedAt > $1.addedAt }
        case .largestSize:
            result.sort {
                if $0.fileSizeBytes != $1.fileSizeBytes {
                    return $0.fileSizeBytes > $1.fileSizeBytes
                }
                return $0.addedAt > $1.addedAt
            }
        case .title:
            result.sort {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return result
    }

    private var hasAnyGroupableSeries: Bool {
        let entries = Self.buildDisplayEntries(
            from: downloads,
            sort: .recentlyAdded,
            brokenIDs: brokenIDs,
            groupSeries: true
        )
        return entries.contains {
            if case .series = $0 { return true }
            return false
        }
    }

    static func buildDisplayEntries(
        from items: [DownloadedVideo],
        sort: DownloadSortOption,
        brokenIDs: Set<String>,
        groupSeries: Bool
    ) -> [DownloadDisplayEntry] {
        guard groupSeries else {
            return items.map { .single($0) }
        }

        var byBvid: [String: [DownloadedVideo]] = [:]
        for item in items where !item.bvid.isEmpty && !item.bvid.hasPrefix("ep") {
            byBvid[item.bvid, default: []].append(item)
        }
        let multiPartBvids = Set(byBvid.compactMap { $0.value.count > 1 ? $0.key : nil })

        var bySeasonOwner: [String: [DownloadedVideo]] = [:]
        for item in items where !multiPartBvids.contains(item.bvid) {
            guard isBangumiEpisodeItem(item) else { continue }
            bySeasonOwner[item.ownerName, default: []].append(item)
        }
        let multiEpisodeSeasons = Set(bySeasonOwner.compactMap { $0.value.count > 1 ? $0.key : nil })

        var entries: [DownloadDisplayEntry] = []
        var emittedMultiPart = Set<String>()
        var emittedSeasons = Set<String>()

        for item in items {
            if multiPartBvids.contains(item.bvid) {
                guard emittedMultiPart.insert(item.bvid).inserted,
                      let groupItems = byBvid[item.bvid] else { continue }
                let ordered = groupItems.sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                let groupTitle = multiPartSeriesTitle(from: ordered)
                let owner = ordered.first?.ownerName ?? ""
                let group = DownloadSeriesGroup(
                    id: "bvid:\(item.bvid)",
                    title: groupTitle,
                    subtitle: owner.isEmpty ? nil : owner,
                    coverURL: ordered.first?.coverURL ?? item.coverURL,
                    episodes: ordered,
                    totalBytes: ordered.reduce(Int64(0)) { $0 + $1.fileSizeBytes },
                    latestAddedAt: ordered.map(\.addedAt).max() ?? item.addedAt,
                    brokenCount: ordered.reduce(0) { $0 + (brokenIDs.contains($1.id) ? 1 : 0) },
                    isBangumiSeason: false
                )
                entries.append(.series(group))
            } else if isBangumiEpisodeItem(item), multiEpisodeSeasons.contains(item.ownerName) {
                guard emittedSeasons.insert(item.ownerName).inserted,
                      let groupItems = bySeasonOwner[item.ownerName] else { continue }
                let ordered = groupItems.sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                let group = DownloadSeriesGroup(
                    id: "season:\(item.ownerName)",
                    title: item.ownerName,
                    subtitle: nil,
                    coverURL: ordered.first?.coverURL ?? item.coverURL,
                    episodes: ordered,
                    totalBytes: ordered.reduce(Int64(0)) { $0 + $1.fileSizeBytes },
                    latestAddedAt: ordered.map(\.addedAt).max() ?? item.addedAt,
                    brokenCount: ordered.reduce(0) { $0 + (brokenIDs.contains($1.id) ? 1 : 0) },
                    isBangumiSeason: true
                )
                entries.append(.series(group))
            } else {
                entries.append(.single(item))
            }
        }

        switch sort {
        case .recentlyAdded:
            entries.sort { $0.sortDate > $1.sortDate }
        case .largestSize:
            entries.sort {
                if $0.sortBytes != $1.sortBytes {
                    return $0.sortBytes > $1.sortBytes
                }
                return $0.sortDate > $1.sortDate
            }
        case .title:
            entries.sort {
                $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending
            }
        }
        return entries
    }

    private static func isBangumiEpisodeItem(_ item: DownloadedVideo) -> Bool {
        guard !item.ownerName.isEmpty else { return false }
        return item.bvid.hasPrefix("ep") || item.title.hasPrefix("\(item.ownerName) - ")
    }

    private static func multiPartSeriesTitle(from episodes: [DownloadedVideo]) -> String {
        guard let firstTitle = episodes.first?.title else { return "" }
        if let range = firstTitle.range(of: " - P", options: .backwards) {
            let prefix = firstTitle[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { return prefix }
        }
        if let range = firstTitle.range(of: " (P", options: .backwards) {
            let prefix = firstTitle[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { return prefix }
        }
        return firstTitle
    }

    static func episodeShortTitle(for item: DownloadedVideo, in group: DownloadSeriesGroup) -> String {
        let prefixWithDash = "\(group.title) - "
        if item.title.hasPrefix(prefixWithDash) {
            let suffix = String(item.title.dropFirst(prefixWithDash.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty { return suffix }
        }
        let prefixWithParen = "\(group.title) ("
        if item.title.hasPrefix(prefixWithParen), item.title.hasSuffix(")") {
            let inner = String(item.title.dropFirst(prefixWithParen.count).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { return inner }
        }
        return item.title
    }

    static func coverWidth(columnWidth: CGFloat?, isRegularWidth: Bool) -> CGFloat {
        let cardWidth = columnWidth.map { max(0, $0 - Self.gridHorizontalHalfGap * 2 - AppSpacing.m * 2) }
        return LibraryRowMetrics.coverWidth(
            columnWidth: cardWidth,
            isRegularWidth: isRegularWidth
        )
    }

    static func coverHeight(for width: CGFloat) -> CGFloat {
        CoverPresentationStore.shared.presentation.height(forWidth: width)
    }

    func coverWidth(columnWidth: CGFloat?) -> CGFloat {
        Self.coverWidth(columnWidth: columnWidth, isRegularWidth: sizeClass == .regular)
    }

    func coverHeight(for width: CGFloat) -> CGFloat {
        Self.coverHeight(for: width)
    }

    var body: some View {
        let completed = filtered
        let currentQuery = query
        let playable = completed.filter { !brokenIDs.contains($0.id) }
        let entries = Self.buildDisplayEntries(
            from: completed,
            sort: sortOption,
            brokenIDs: brokenIDs,
            groupSeries: groupSeries
        )
        return downloadsScrollContent(
            completed: completed,
            entries: entries,
            query: currentQuery
        )
            .appAmbientBrowseBackground()
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search downloads")
            .modifier(DownloadsToolbarModifier(
                canPlayAll: !playable.isEmpty,
                hasDownloads: !downloads.isEmpty,
                hasGroupableSeries: hasAnyGroupableSeries,
                brokenCount: brokenIDs.count,
                sortOption: $sortOption,
                groupSeries: $groupSeries,
                onPlayAll: {
                    if let first = playable.first {
                        open(first, in: playable)
                    }
                },
                onCleanMissing: {
                    showCleanMissingConfirm = true
                }
            ))
            .overlay(alignment: .bottom) {
                if let notice {
                    ToastView(message: notice)
                        .padding()
                }
            }
            .task(id: notice?.id) {
                let noticeID = notice?.id
                guard noticeID != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled, notice?.id == noticeID { notice = nil }
            }
            .alert(
                "Download unavailable",
                isPresented: Binding(
                    get: { invalidDownloadID != nil },
                    set: { if !$0 { invalidDownloadID = nil } }
                )
            ) {
                if let item = downloads.first(where: { $0.id == invalidDownloadID }) {
                    Button("Re-download") {
                        invalidDownloadID = nil
                        redownload(item)
                    }
                    Button("Delete", role: .destructive) {
                        invalidDownloadID = nil
                        requestMutation(item, redownload: false)
                    }
                }
                Button("Cancel", role: .cancel) { invalidDownloadID = nil }
            } message: {
                Text("Downloaded files are missing or corrupt.")
            }
            .alert(
                "Download Failed",
                isPresented: Binding(
                    get: { activeError != nil },
                    set: { if !$0 { activeError = nil } }
                )
            ) {
                if let failed = activeError {
                    if manager.active.contains(where: { $0.id == failed.downloadID }) {
                        Button("Retry") {
                            activeError = nil
                            manager.retry(id: failed.downloadID)
                        }
                    }
                    Button("Copy") {
                        UIPasteboard.general.string = failed.message
                    }
                }
                Button("OK", role: .cancel) { activeError = nil }
            } message: {
                if let failed = activeError {
                    Text(verbatim: failed.message)
                }
            }
            .sheet(item: $exportRequest) { request in
                DownloadExportSheet(source: request.source)
                    .appAdaptiveSheet(padSizing: .form)
            }
            .sheet(item: $saveRequest) { request in
                DownloadExportFilePicker(fileURL: request.fileURL) { destination in
                    if destination != nil {
                        exports.completeExternalSave(id: request.id)
                    }
                    saveRequest = nil
                }
            }
            .alert("Export Failed", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                if let message = exportError {
                    Button("Copy") { UIPasteboard.general.string = message }
                }
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(verbatim: exportError ?? "")
            }
            .confirmationDialog(
                "Cancel export before changing this download?",
                isPresented: Binding(
                    get: { mutationRequest != nil },
                    set: { if !$0 { mutationRequest = nil } }
                )
            ) {
                Button("Cancel export and continue", role: .destructive) { settleMutation() }
                Button("Keep export", role: .cancel) { mutationRequest = nil }
            }
            .confirmationDialog(
                String(format: String(localized: "Remove %d downloads with missing files?"), brokenIDs.count),
                isPresented: $showCleanMissingConfirm,
                titleVisibility: .visible
            ) {
                Button("Clean Missing", role: .destructive) { cleanMissingFiles() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                String(
                    format: String(localized: "Delete all %d episodes in “%@”?"),
                    pendingGroupDelete?.episodes.count ?? 0,
                    pendingGroupDelete?.title ?? ""
                ),
                isPresented: Binding(
                    get: { pendingGroupDelete != nil },
                    set: { if !$0 { pendingGroupDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    if let group = pendingGroupDelete {
                        deleteSeriesGroup(group)
                    }
                    pendingGroupDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingGroupDelete = nil }
            }
            .task(id: downloads.map(\.fileSnapshot)) { await refreshMissingFiles() }
    }

    static func downloadRowCover(
        coverURL: String,
        width: CGFloat,
        height: CGFloat,
        durationSeconds: Int? = nil,
        watchedFraction: Double? = nil
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            VideoCoverImage(
                sources: VideoCoverSources(widescreen: coverURL),
                width: width
            )
            .videoCoverFrame(cornerRadius: AppRadius.thumbnail)

            if let watchedFraction {
                CoverWatchProgressBar(
                    progress: watchedFraction,
                    width: width,
                    height: height
                )
            }

            if let durationSeconds, durationSeconds > 0 {
                Text(FormatUtils.duration(durationSeconds))
                    .appFont(.overlayBadge, monospacedDigit: true)
                    .fontWeight(.medium)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        .black.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                    )
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
    }

    func downloadRowCover(
        coverURL: String,
        width: CGFloat,
        height: CGFloat,
        durationSeconds: Int? = nil,
        watchedFraction: Double? = nil
    ) -> some View {
        Self.downloadRowCover(
            coverURL: coverURL,
            width: width,
            height: height,
            durationSeconds: durationSeconds,
            watchedFraction: watchedFraction
        )
    }

    static func rowMenuButton<MenuContent: View>(
        @ViewBuilder actions: () -> MenuContent
    ) -> some View {
        Menu {
            actions()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.callout)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.secondary)
                .padding(.top, AppSpacing.m - 2)
                .padding(.trailing, AppSpacing.m - 2)
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Download actions"))
    }

    func rowMenuButton<MenuContent: View>(
        @ViewBuilder actions: () -> MenuContent
    ) -> some View {
        Self.rowMenuButton(actions: actions)
    }

    static func qualityBadge(_ label: String) -> some View {
        Text(label)
            .appFont(.overlayBadge)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                AccentStore.shared.badgeFill,
                in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
            )
    }

    func qualityBadge(_ label: String) -> some View {
        Self.qualityBadge(label)
    }

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func byteString(_ bytes: Int64) -> String {
        Self.byteString(bytes)
    }

    func open(_ item: DownloadedVideo, in shown: [DownloadedVideo], zoom: RouteZoomSource = .none) {
        guard item.fileSnapshot.filesExist else {
            brokenIDs.insert(item.id)
            invalidDownloadID = item.id
            return
        }
        brokenIDs.remove(item.id)
        let sequence = shown.compactMap { candidate -> OfflinePortraitPagingItem? in
            guard !brokenIDs.contains(candidate.id) else { return nil }
            return OfflinePortraitPagingItem(
                downloadID: candidate.id,
                preview: .init(
                    title: candidate.title,
                    coverURL: candidate.coverURL,
                    ownerName: candidate.ownerName,
                    durationSeconds: candidate.durationSeconds
                )
            )
        }
        if let context = OfflinePortraitPagingContext(items: sequence, selectedID: item.id) {
            coordinator.navigate(to: .offlinePager(context, zoom: zoom))
        } else {
            coordinator.navigate(to: .offlinePlayer(item.id, zoom: zoom))
        }
    }

    private func refreshMissingFiles() async {
        let snapshots = downloads.map(\.fileSnapshot)
        guard let valid = try? await DownloadFileSnapshot.validSnapshots(in: snapshots),
              !Task.isCancelled, downloads.map(\.fileSnapshot) == snapshots else { return }
        brokenIDs = Set(snapshots.filter { !valid.contains($0) }.map(\.id))
    }

    private func cleanMissingFiles() {
        let brokenItems = downloads.filter { brokenIDs.contains($0.id) }
        var removedCount = 0
        for item in brokenItems {
            if !exports.sourceIsLocked(downloadID: item.id), manager.delete(item) {
                brokenIDs.remove(item.id)
                removedCount += 1
            }
        }
        if removedCount > 0 {
            notice = ToastMessage(
                text: String(format: String(localized: "Removed %d missing downloads"), removedCount),
                style: .success
            )
        }
    }

    private func deleteSeriesGroup(_ group: DownloadSeriesGroup) {
        var removedCount = 0
        for item in group.episodes {
            if !exports.sourceIsLocked(downloadID: item.id), manager.delete(item) {
                brokenIDs.remove(item.id)
                removedCount += 1
            }
        }
        expandedGroupIDs.remove(group.id)
        if removedCount > 0 {
            notice = ToastMessage(text: String(localized: "Removed"), style: .success)
        }
    }
}

private extension DownloadsView {
    func downloadsScrollContent(
        completed: [DownloadedVideo],
        entries: [DownloadDisplayEntry],
        query: String
    ) -> some View {
        let horizontalMargin = FeedColumnPolicy.horizontalMargin(for: containerWidth)
        let hasVisibleActive = query.isEmpty
            ? !manager.active.isEmpty
            : manager.active.contains {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.ownerName.localizedCaseInsensitiveContains(query)
            }
        let showsCompletedHeader = hasVisibleActive
            || exports.activeJob != nil
            || !exports.artifacts.isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                DownloadsExportSectionView(
                    horizontalMargin: horizontalMargin,
                    saveToFiles: presentSaveToFiles
                )
                ActiveDownloadsSectionView(
                    query: query,
                    horizontalMargin: horizontalMargin
                ) { error in
                    activeError = error
                }
                DownloadsEmptyStateView(
                    query: query,
                    hasCompleted: !completed.isEmpty
                )
                if !entries.isEmpty {
                    completedSection(
                        entries,
                        allShown: completed,
                        showsHeader: showsCompletedHeader,
                        horizontalMargin: horizontalMargin
                    )
                }
            }
            .frame(maxWidth: Self.maximumContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.m)
            .padding(.bottom, usesSidebarLayout ? 0 : SettingsScaffoldingMetrics.floatingTabBarClearance)
        }
        .measuringContentWidth(into: $containerWidth)
        .refreshable {
            await refreshMissingFiles()
        }
    }

    func completedSection(
        _ entries: [DownloadDisplayEntry],
        allShown: [DownloadedVideo],
        showsHeader: Bool,
        horizontalMargin: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            if showsHeader {
                DownloadsSectionHeader(horizontalMargin: horizontalMargin) {
                    Text("Downloaded")
                }
            }
            LibraryRowLayout {
                ForEach(entries) { entry in
                    RowCardColumnWidthReader { column in
                        switch entry {
                        case .single(let item):
                            completedRow(item, in: allShown, columnWidth: column)
                        case .series(let group):
                            seriesGroupRow(group, columnWidth: column)
                        }
                    }
                    .padding(.horizontal, Self.gridHorizontalHalfGap)
                    .padding(.vertical, Self.gridVerticalHalfGap)
                }
            }
            .padding(.horizontal, max(0, horizontalMargin - Self.gridHorizontalHalfGap))
            .padding(.vertical, -Self.gridVerticalHalfGap)
        }
    }
}

private struct DownloadsSectionHeader<Content: View>: View {
    var horizontalMargin: CGFloat = AppSpacing.l
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .appFont(.libraryRowMeta)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalMargin)
    }
}

private struct DownloadsToolbarModifier: ViewModifier {
    let canPlayAll: Bool
    let hasDownloads: Bool
    let hasGroupableSeries: Bool
    let brokenCount: Int
    @Binding var sortOption: DownloadSortOption
    @Binding var groupSeries: Bool
    let onPlayAll: () -> Void
    let onCleanMissing: () -> Void
    private let manager = DownloadManager.shared

    func body(content: Content) -> some View {
        let runningCount = manager.active.filter { !$0.phase.isResumable }.count
        let resumableCount = manager.active.filter { $0.phase.isResumable }.count
        let hasActiveActions = runningCount > 0 || resumableCount > 0
        let showsMoreMenu = hasDownloads || (runningCount > 0 && resumableCount > 0)
        content.toolbar {
            if canPlayAll || hasDownloads || hasActiveActions {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if canPlayAll {
                        Button(action: onPlayAll) {
                            HStack(spacing: 5) {
                                Image(systemName: "play.fill")
                                    .font(.caption.weight(.semibold))
                                Text("Play All")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        .accessibilityIdentifier("downloads.playAll")
                    }
                    if showsMoreMenu {
                        Menu {
                            if runningCount > 0 {
                                Button(action: pauseAllActive) {
                                    Label("Pause All", systemImage: "pause.fill")
                                }
                            }
                            if resumableCount > 0 {
                                Button(action: resumeAllActive) {
                                    Label("Resume All", systemImage: "play.fill")
                                }
                            }
                            if hasActiveActions, hasDownloads {
                                Divider()
                            }
                            if hasDownloads {
                                Menu {
                                    ForEach(DownloadSortOption.allCases) { option in
                                        Button {
                                            sortOption = option
                                        } label: {
                                            if sortOption == option {
                                                Label(option.label, systemImage: "checkmark")
                                            } else {
                                                Text(option.label)
                                            }
                                        }
                                    }
                                } label: {
                                    Label("Sort", systemImage: "arrow.up.arrow.down")
                                }
                                if hasGroupableSeries {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            groupSeries.toggle()
                                        }
                                    } label: {
                                        Label(
                                            groupSeries
                                                ? LocalizedStringKey("Ungroup Series")
                                                : LocalizedStringKey("Group by Series"),
                                            systemImage: groupSeries ? "list.bullet" : "rectangle.stack"
                                        )
                                    }
                                }
                                if brokenCount > 0 {
                                    Divider()
                                    Button(role: .destructive, action: onCleanMissing) {
                                        Label("Clean Missing", systemImage: "trash")
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(Text("Download actions"))
                    } else if runningCount > 0 {
                        Button("Pause All", action: pauseAllActive)
                    } else if resumableCount > 0 {
                        Button("Resume All", action: resumeAllActive)
                    }
                }
            }
        }
    }

    private func pauseAllActive() {
        let queued = manager.active.filter { $0.phase == .queued }
        let running = manager.active.filter { $0.phase.isActivelyRunning }
        for item in queued + running {
            manager.pause(id: item.id)
        }
    }

    private func resumeAllActive() {
        for item in manager.active where item.phase.isResumable {
            manager.retry(id: item.id)
        }
    }
}

private struct DownloadsExportSectionView: View {
    var horizontalMargin: CGFloat = AppSpacing.l
    let saveToFiles: (ExportArtifact) -> Void
    private let exports = DownloadExportCoordinator.shared

    var body: some View {
        if exports.activeJob != nil || !exports.artifacts.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                DownloadsSectionHeader(horizontalMargin: horizontalMargin) { Text("Export") }
                ExportProgressView(saveToFiles: saveToFiles)
                    .padding(.horizontal, horizontalMargin)
            }
        }
    }
}

private struct DownloadsEmptyStateView: View {
    let query: String
    let hasCompleted: Bool

    private let manager = DownloadManager.shared
    private let exports = DownloadExportCoordinator.shared

    private var showsEmpty: Bool {
        guard !hasCompleted else { return false }
        let hasActive: Bool
        if query.isEmpty {
            hasActive = !manager.active.isEmpty
        } else {
            hasActive = manager.active.contains {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.ownerName.localizedCaseInsensitiveContains(query)
            }
        }
        guard !hasActive else { return false }
        if !query.isEmpty {
            return true
        }
        return exports.activeJob == nil && exports.artifacts.isEmpty
    }

    var body: some View {
        if showsEmpty {
            if !query.isEmpty {
                ContentUnavailableView(
                    LocalizedStringKey("No Matches"),
                    systemImage: "magnifyingglass",
                    description: Text(LocalizedStringKey("No downloads match your search."))
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
            } else {
                ContentUnavailableView(
                    LocalizedStringKey("No Downloads"),
                    systemImage: "arrow.down.circle",
                    description: Text(LocalizedStringKey("Videos you download for offline viewing appear here."))
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
            }
        }
    }
}

private struct ActiveDownloadsSectionView: View {
    let query: String
    var horizontalMargin: CGFloat = AppSpacing.l
    let onShowError: (DownloadsView.ActiveErrorPresentation) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let manager = DownloadManager.shared

    private var filteredActive: [DownloadManager.ActiveDownload] {
        guard !query.isEmpty else { return manager.active }
        return manager.active.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.ownerName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let active = filteredActive
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                DownloadsSectionHeader(horizontalMargin: horizontalMargin) {
                    HStack {
                        Text("Downloading")
                        Spacer()
                        Text(verbatim: "\(active.count)")
                            .monospacedDigit()
                    }
                }
                LibraryRowLayout {
                    ForEach(active) { item in
                        RowCardColumnWidthReader { column in
                            activeRow(item, columnWidth: column)
                        }
                        .padding(.horizontal, DownloadsView.gridHorizontalHalfGap)
                        .padding(.vertical, DownloadsView.gridVerticalHalfGap)
                    }
                }
                .padding(.horizontal, max(0, horizontalMargin - DownloadsView.gridHorizontalHalfGap))
                .padding(.vertical, -DownloadsView.gridVerticalHalfGap)
            }
        }
    }

    private func activeRow(
        _ item: DownloadManager.ActiveDownload,
        columnWidth: CGFloat?
    ) -> some View {
        let width = DownloadsView.coverWidth(
            columnWidth: columnWidth,
            isRegularWidth: sizeClass == .regular
        )
        let height = DownloadsView.coverHeight(for: width)
        return HStack(alignment: .top, spacing: RowGeometry.coverToTextSpacing) {
            DownloadsView.downloadRowCover(
                coverURL: item.coverURL,
                width: width,
                height: height,
                durationSeconds: item.durationSeconds > 0 ? item.durationSeconds : nil
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .appFont(.libraryRowTitle)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.trailing, DownloadsView.trailingMenuTitleInset)

                if !item.ownerName.isEmpty {
                    Text(item.ownerName)
                        .appFont(.libraryRowMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                activeProgressContent(item)

                Spacer(minLength: 0)

                activeFooterRow(item)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        }
        .padding(AppSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardSurface(in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(alignment: .topTrailing) {
            DownloadsView.rowMenuButton {
                activeActions(item)
            }
        }
        .contentShape(
            .contextMenuPreview,
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        )
        .contextMenu {
            activeActions(item)
        }
    }

    @ViewBuilder
    private func activeProgressContent(_ item: DownloadManager.ActiveDownload) -> some View {
        switch item.phase {
        case .failed(let message):
            Button {
                onShowError(
                    DownloadsView.ActiveErrorPresentation(
                        downloadID: item.id,
                        message: message
                    )
                )
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .accessibilityHidden(true)
                    Text(verbatim: message)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .appFont(.libraryRowMeta)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("View Details"))
        case .queued:
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if let fraction = item.fraction {
                    ProgressView(value: fraction)
                        .tint(.secondary)
                }
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    metadataLine(item)
                }
            }
        case .paused:
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if let fraction = item.fraction {
                    ProgressView(value: fraction)
                        .tint(.secondary)
                }
                metadataLine(item)
            }
        default:
            if let fraction = item.fraction {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ProgressView(value: fraction)
                        .tint(.biliAccent)
                    metadataLine(item)
                }
            } else {
                HStack(spacing: AppSpacing.xs) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.biliAccent)
                    metadataLine(item)
                }
            }
        }
    }

    @ViewBuilder
    private func activeFooterRow(_ item: DownloadManager.ActiveDownload) -> some View {
        if dynamicTypeSize >= .xxLarge {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                DownloadsView.qualityBadge(item.qualityLabel)
                activeActionButton(item)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppSpacing.s) {
                    DownloadsView.qualityBadge(item.qualityLabel)
                        .fixedSize()
                    Spacer(minLength: 0)
                    activeActionButton(item)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    DownloadsView.qualityBadge(item.qualityLabel)
                    activeActionButton(item)
                }
            }
        }
    }

    @ViewBuilder
    private func activeActionButton(_ item: DownloadManager.ActiveDownload) -> some View {
        let isFailed: Bool = if case .failed = item.phase { true } else { false }
        let isResumable = item.phase.isResumable
        let title: LocalizedStringKey = if isFailed {
            "Retry"
        } else if isResumable {
            "Resume"
        } else {
            "Pause"
        }
        let icon: String = if isFailed {
            "arrow.clockwise"
        } else if isResumable {
            "play.fill"
        } else {
            "pause.fill"
        }
        let accessibilityText: LocalizedStringKey = if isFailed {
            "Retry download"
        } else if isResumable {
            "Resume download"
        } else {
            "Pause download"
        }

        if isResumable {
            Button {
                manager.retry(id: item.id)
            } label: {
                Label(title, systemImage: icon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .tint(.biliAccent)
            .accessibilityLabel(Text(accessibilityText))
        } else {
            Button {
                manager.pause(id: item.id)
            } label: {
                Label(title, systemImage: icon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .tint(.biliAccent)
            .accessibilityLabel(Text(accessibilityText))
        }
    }

    private func metadataLine(_ item: DownloadManager.ActiveDownload) -> some View {
        let byteText = byteProgressText(item)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(downloadRowLeftSlot(fraction: item.fraction, phase: item.phase))
                    .monospacedDigit()
                Spacer(minLength: AppSpacing.xs)
                Text(downloadRowRightSlot(
                    fraction: item.fraction,
                    phase: item.phase,
                    formattedSpeed: formattedSpeed(item.speedBytesPerSecond)
                ))
                    .monospacedDigit()
            }
            .appFont(.libraryRowFooter)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let byteText {
                Text(verbatim: byteText)
                    .appFont(.libraryRowFooter, monospacedDigit: true)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func byteProgressText(_ item: DownloadManager.ActiveDownload) -> String? {
        let transferred = max(0, item.bytesTransferred)
        if let expected = item.expectedBytes, expected > 0 {
            let clamped = min(transferred, expected)
            return "\(DownloadsView.byteString(clamped)) / \(DownloadsView.byteString(expected))"
        }
        if transferred > 0 {
            return DownloadsView.byteString(transferred)
        }
        return nil
    }

    @ViewBuilder
    private func activeActions(_ item: DownloadManager.ActiveDownload) -> some View {
        switch item.phase {
        case .failed(let message):
            Button {
                manager.retry(id: item.id)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel(Text("Retry download"))

            Button {
                onShowError(
                    DownloadsView.ActiveErrorPresentation(
                        downloadID: item.id,
                        message: message
                    )
                )
            } label: {
                Label("View Details", systemImage: "exclamationmark.circle")
            }
        case .paused:
            Button {
                manager.retry(id: item.id)
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .accessibilityLabel(Text("Resume download"))
        default:
            Button {
                manager.pause(id: item.id)
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .accessibilityLabel(Text("Pause download"))
        }

        Button(role: .destructive) {
            manager.cancel(id: item.id)
        } label: {
            Label("Cancel", systemImage: "xmark")
        }
        .accessibilityLabel(Text("Cancel"))
    }

    private func formattedSpeed(_ bytesPerSecond: Double?) -> String? {
        guard let value = bytesPerSecond, value.isFinite, value >= 0 else { return nil }
        let rounded = value.rounded()
        let readableBytes = rounded >= Double(Int64.max) ? Int64.max : Int64(rounded)
        return "\(DownloadsView.byteString(readableBytes))/s"
    }
}
