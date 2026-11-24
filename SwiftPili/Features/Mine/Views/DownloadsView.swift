import SwiftData
import SwiftUI
import UIKit

struct DownloadsView: View {
    @Query(sort: \DownloadedVideo.addedAt, order: .reverse)
    var downloads: [DownloadedVideo]
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var search = ""
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
    static let trailingMenuTitleInset: CGFloat = 28
    private static let maximumContentWidth: CGFloat = 1240

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

    private var query: String {
        search.trimmingCharacters(in: .whitespaces)
    }

    private var filtered: [DownloadedVideo] {
        let trimmedQuery = query
        guard !trimmedQuery.isEmpty else { return downloads }
        return downloads.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.ownerName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    static func coverWidth(columnWidth: CGFloat?, isRegularWidth: Bool) -> CGFloat {
        let cardWidth = columnWidth.map { max(0, $0 - Self.gridHorizontalHalfGap * 2) }
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
        let totalBytes = currentQuery.isEmpty
            ? downloads.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
            : 0
        return downloadsScrollContent(
            completed: completed,
            query: currentQuery,
            totalBytes: totalBytes
        )
            .appAmbientBrowseBackground()
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search downloads")
            .modifier(DownloadsToolbarModifier())
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
}

private extension DownloadsView {
    func downloadsScrollContent(
        completed: [DownloadedVideo],
        query: String,
        totalBytes: Int64
    ) -> some View {
        let horizontalMargin = FeedColumnPolicy.horizontalMargin(for: containerWidth)
        return ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                DownloadsStorageSummarySection(
                    query: query,
                    downloadedCount: downloads.count,
                    totalBytes: totalBytes,
                    brokenCount: brokenIDs.count,
                    horizontalMargin: horizontalMargin
                )
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
                if !completed.isEmpty {
                    completedSection(completed, horizontalMargin: horizontalMargin)
                }
            }
            .frame(maxWidth: Self.maximumContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.m)
            .padding(.bottom, SettingsScaffoldingMetrics.floatingTabBarClearance)
        }
        .measuringContentWidth(into: $containerWidth)
        .refreshable {
            await refreshMissingFiles()
        }
    }

    func completedSection(_ completed: [DownloadedVideo], horizontalMargin: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            DownloadsSectionHeader(horizontalMargin: horizontalMargin) {
                completedHeader(for: completed)
            }
            LibraryRowLayout {
                ForEach(completed) { item in
                    RowCardColumnWidthReader { column in
                        completedRow(item, in: completed, columnWidth: column)
                    }
                    .padding(.horizontal, Self.gridHorizontalHalfGap)
                    .padding(.vertical, Self.gridVerticalHalfGap)
                }
            }
            .padding(.horizontal, max(0, horizontalMargin - Self.gridHorizontalHalfGap))
            .padding(.vertical, -Self.gridVerticalHalfGap)
        }
    }

    func completedHeader(for shown: [DownloadedVideo]) -> some View {
        HStack {
            Text("Downloaded")
            Spacer()
            if !query.isEmpty {
                Text(String(format: String(localized: "%d videos"), shown.count))
                    .monospacedDigit()
            }
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
    private let manager = DownloadManager.shared

    func body(content: Content) -> some View {
        let runningCount = manager.active.filter { !$0.phase.isResumable }.count
        let resumableCount = manager.active.filter { $0.phase.isResumable }.count
        content.toolbar {
            if runningCount > 0 || resumableCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    if runningCount > 0, resumableCount > 0 {
                        Menu {
                            Button(action: pauseAllActive) {
                                Label("Pause All", systemImage: "pause.fill")
                            }
                            Button(action: resumeAllActive) {
                                Label("Resume All", systemImage: "play.fill")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(Text("Download actions"))
                    } else if runningCount > 0 {
                        Button("Pause All", action: pauseAllActive)
                    } else {
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

private struct DownloadsStorageSummarySection: View {
    let query: String
    let downloadedCount: Int
    let totalBytes: Int64
    let brokenCount: Int
    var horizontalMargin: CGFloat = AppSpacing.l

    private let manager = DownloadManager.shared

    var body: some View {
        let activeCount = query.isEmpty ? manager.active.count : 0
        if query.isEmpty, downloadedCount > 0 || activeCount > 0 {
            DownloadsStorageSummaryCard(
                downloadedCount: downloadedCount,
                totalStorageText: DownloadsView.byteString(totalBytes),
                activeCount: activeCount,
                brokenCount: brokenCount
            )
            .padding(.horizontal, horizontalMargin)
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
            ContentUnavailableView(
                query.isEmpty
                    ? LocalizedStringKey("No Downloads")
                    : LocalizedStringKey("No Matches"),
                systemImage: "arrow.down.circle",
                description: Text(query.isEmpty
                    ? LocalizedStringKey("Videos you download for offline viewing appear here.")
                    : LocalizedStringKey("No downloads match your search."))
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
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
                height: height
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .appFont(.libraryRowTitle)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.trailing, DownloadsView.trailingMenuTitleInset)

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

private struct DownloadsStorageSummaryCard: View {
    let downloadedCount: Int
    let totalStorageText: String
    let activeCount: Int
    let brokenCount: Int

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var valueFont: Font {
        sizeClass == .regular
            ? .title3.weight(.semibold).monospacedDigit()
            : .headline.weight(.semibold).monospacedDigit()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            metricsStrip

            if brokenCount > 0 {
                Divider()
                missingFilesRow
            }
        }
        .padding(.horizontal, AppSpacing.l)
        .padding(.vertical, AppSpacing.m)
        .appCardSurface(in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    @ViewBuilder
    private var metricsStrip: some View {
        if dynamicTypeSize >= .xxLarge {
            stackedMetrics
        } else {
            ViewThatFits(in: .horizontal) {
                horizontalMetrics
                stackedMetrics
            }
        }
    }

    private var horizontalMetrics: some View {
        HStack(spacing: 0) {
            horizontalMetricItem(
                title: "Downloaded",
                value: downloadedCount.formatted(),
                tint: .primary
            )
            metricDivider
            horizontalMetricItem(
                title: "Storage",
                value: totalStorageText,
                tint: .primary
            )
            if activeCount > 0 {
                metricDivider
                horizontalMetricItem(
                    title: "Downloading",
                    value: activeCount.formatted(),
                    tint: .biliAccent
                )
            }
        }
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 28)
            .padding(.horizontal, AppSpacing.s)
    }

    private func horizontalMetricItem(
        title: LocalizedStringKey,
        value: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .center, spacing: 3) {
            Text(verbatim: value)
                .font(valueFont)
                .foregroundStyle(tint)
                .fixedSize(horizontal: true, vertical: false)
            Text(title)
                .appFont(.libraryRowMeta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var stackedMetrics: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            stackedMetricRow(title: "Downloaded", value: downloadedCount.formatted(), tint: .primary)
            Divider()
            stackedMetricRow(title: "Storage", value: totalStorageText, tint: .primary)
            if activeCount > 0 {
                Divider()
                stackedMetricRow(
                    title: "Downloading",
                    value: activeCount.formatted(),
                    tint: .biliAccent
                )
            }
        }
    }

    private func stackedMetricRow(
        title: LocalizedStringKey,
        value: String,
        tint: Color
    ) -> some View {
        let stacksVertically = dynamicTypeSize.isAccessibilitySize
        let layout: AnyLayout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: AppSpacing.s))
        return layout {
            Text(title)
                .appFont(.libraryRowMeta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !stacksVertically {
                Spacer(minLength: AppSpacing.s)
            }
            Text(verbatim: value)
                .font(valueFont)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var missingFilesRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(String(format: String(localized: "%d downloads have missing files"), brokenCount))
                .appFont(.libraryRowMeta)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
