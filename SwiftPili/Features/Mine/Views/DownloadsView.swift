import SwiftData
import SwiftUI
import UIKit

struct DownloadsView: View {
    @Query(sort: \DownloadedVideo.addedAt, order: .reverse)
    var downloads: [DownloadedVideo]
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search = ""
    @State private var invalidDownloadID: String?
    @State private var activeError: ActiveErrorPresentation?
    @State var brokenIDs: Set<String> = []
    let manager = DownloadManager.shared
    let exports = DownloadExportCoordinator.shared
    @State var exportRequest: ExportPresentation?
    @State var saveRequest: ExportSavePresentation?
    @State var pendingSaveID: UUID?
    @State var exportError: String?
    @State var mutationRequest: ExportMutationPresentation?
    @State var isDownloadsVisible = false
    @State var pendingExportRequestID: UUID?
    @State var exportPreparation: Task<Void, Never>?
    @State private var openRequestID: UUID?
    @State private var openPreparation: Task<Void, Never>?

    static let gridHorizontalHalfGap: CGFloat = AppSpacing.m / 2
    static let gridVerticalHalfGap: CGFloat = AppSpacing.xs
    static let trailingMenuTitleInset: CGFloat = 28

    var exportNavigationRevision: UInt64 { coordinator.contentLinkNavigationRevision }

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
    private struct ActiveErrorPresentation {
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

    private var filteredActive: [DownloadManager.ActiveDownload] {
        let trimmedQuery = query
        guard !trimmedQuery.isEmpty else { return manager.active }
        return manager.active.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.ownerName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    func coverWidth(columnWidth: CGFloat?) -> CGFloat {
        let cardWidth = columnWidth.map { max(0, $0 - Self.gridHorizontalHalfGap * 2) }
        return LibraryRowMetrics.coverWidth(
            columnWidth: cardWidth,
            isRegularWidth: sizeClass == .regular
        )
    }

    func coverHeight(for width: CGFloat) -> CGFloat {
        CoverPresentationStore.shared.presentation.height(forWidth: width)
    }

    var body: some View {
        let completed = filtered
        let active = filteredActive
        let runningCount = manager.active.filter { !$0.phase.isResumable }.count
        let resumableCount = manager.active.filter { $0.phase.isResumable }.count
        return downloadsScrollContent(completed: completed, active: active)
            .appAmbientBrowseBackground()
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search downloads")
            .toolbar {
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
            .sheet(item: $saveRequest, onDismiss: settleCancelledSave) { request in
                DownloadExportFilePicker(fileURL: request.fileURL) { destination in
                    guard pendingSaveID == request.id else { return }
                    finishExportSave(id: request.id, destination: destination)
                    pendingSaveID = nil
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
            .onChange(of: search) { _, _ in cancelOpening() }
            .onAppear { isDownloadsVisible = true }
            .onDisappear {
                isDownloadsVisible = false
                cancelOpening()
                exportPreparation?.cancel()
                exportPreparation = nil
                pendingExportRequestID = nil
            }
    }

    func downloadRowCover(
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

    func rowMenuButton<MenuContent: View>(
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

    func qualityBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(AccentStore.shared.badgeFill, in: RoundedRectangle(cornerRadius: AppRadius.badge))
    }

    func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func open(_ item: DownloadedVideo, in shown: [DownloadedVideo], zoom: RouteZoomSource = .none) {
        cancelOpening()
        let requestID = UUID()
        let selected = item.fileSnapshot
        let navigationRevision = coordinator.contentLinkNavigationRevision
        let candidates = shown.map { candidate in
            (files: candidate.fileSnapshot, paging: OfflinePortraitPagingItem(
                downloadID: candidate.id,
                preview: .init(
                    title: candidate.title, coverURL: candidate.coverURL,
                    ownerName: candidate.ownerName, durationSeconds: candidate.durationSeconds
                )
            ))
        }
        let files = [selected] + candidates.map(\.files)
        openRequestID = requestID
        openPreparation = Task {
            defer {
                if openRequestID == requestID {
                    openRequestID = nil
                    openPreparation = nil
                }
            }
            guard let valid = try? await DownloadFileSnapshot.validSnapshots(in: files),
                  !Task.isCancelled, openRequestID == requestID, isDownloadsVisible,
                  coordinator.contentLinkNavigationRevision == navigationRevision else { return }
            let current = Dictionary(uniqueKeysWithValues: downloads.map { ($0.id, $0.fileSnapshot) })
            guard current[selected.id] == selected else { return }
            guard valid.contains(selected) else {
                invalidDownloadID = selected.id
                return
            }
            let sequence = candidates.compactMap { candidate -> OfflinePortraitPagingItem? in
                guard valid.contains(candidate.files),
                      current[candidate.files.id] == candidate.files else { return nil }
                return candidate.paging
            }
            if let context = OfflinePortraitPagingContext(items: sequence, selectedID: selected.id) {
                coordinator.navigate(to: .offlinePager(context, zoom: zoom))
            } else {
                coordinator.navigate(to: .offlinePlayer(selected.id, zoom: zoom))
            }
        }
    }

    private func cancelOpening() {
        openPreparation?.cancel()
        openPreparation = nil
        openRequestID = nil
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
        active: [DownloadManager.ActiveDownload]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.l) {
                if query.isEmpty, !downloads.isEmpty || !manager.active.isEmpty {
                    storageSummaryCard
                }
                if exports.activeJob != nil || !exports.artifacts.isEmpty {
                    exportSection
                }
                if !active.isEmpty {
                    activeSection(active)
                }
                if showsEmptyState(completed: completed, active: active) {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else if !completed.isEmpty {
                    completedSection(completed)
                }
            }
            .padding(.vertical, AppSpacing.m)
            .padding(.bottom, SettingsScaffoldingMetrics.floatingTabBarClearance)
        }
        .refreshable {
            await refreshMissingFiles()
        }
    }

    var exportSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            sectionHeader { Text("Export") }
            ExportProgressView(save: presentSave)
                .padding(.horizontal, AppSpacing.l)
        }
    }

    func activeSection(_ active: [DownloadManager.ActiveDownload]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            sectionHeader {
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
                    .padding(.horizontal, Self.gridHorizontalHalfGap)
                    .padding(.vertical, Self.gridVerticalHalfGap)
                }
            }
            .padding(.horizontal, AppSpacing.l - Self.gridHorizontalHalfGap)
            .padding(.vertical, -Self.gridVerticalHalfGap)
        }
    }

    func completedSection(_ completed: [DownloadedVideo]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            sectionHeader { completedHeader(for: completed) }
            LibraryRowLayout {
                ForEach(completed) { item in
                    RowCardColumnWidthReader { column in
                        completedRow(item, in: completed, columnWidth: column)
                    }
                    .padding(.horizontal, Self.gridHorizontalHalfGap)
                    .padding(.vertical, Self.gridVerticalHalfGap)
                }
            }
            .padding(.horizontal, AppSpacing.l - Self.gridHorizontalHalfGap)
            .padding(.vertical, -Self.gridVerticalHalfGap)
        }
    }

    var storageSummaryCard: some View {
        let totalBytes = downloads.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        return DownloadsStorageSummaryCard(
            downloadedCount: downloads.count,
            totalStorageText: byteString(totalBytes),
            activeCount: manager.active.count,
            brokenCount: brokenIDs.count
        )
        .padding(.horizontal, AppSpacing.l)
    }

    func pauseAllActive() {
        let queued = manager.active.filter { $0.phase == .queued }
        let running = manager.active.filter { $0.phase.isActivelyRunning }
        for item in queued + running {
            manager.pause(id: item.id)
        }
    }

    func resumeAllActive() {
        for item in manager.active where item.phase.isResumable {
            manager.retry(id: item.id)
        }
    }

    func activeRow(
        _ item: DownloadManager.ActiveDownload,
        columnWidth: CGFloat?
    ) -> some View {
        let width = coverWidth(columnWidth: columnWidth)
        let height = coverHeight(for: width)
        return HStack(alignment: .top, spacing: RowGeometry.coverToTextSpacing) {
            downloadRowCover(
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
                    .padding(.trailing, Self.trailingMenuTitleInset)

                activeProgressContent(item)

                Spacer(minLength: 0)

                activeFooterRow(item)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        }
        .padding(AppSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppFill.card,
            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            rowMenuButton {
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
    func activeProgressContent(_ item: DownloadManager.ActiveDownload) -> some View {
        switch item.phase {
        case .failed(let message):
            Button {
                activeError = ActiveErrorPresentation(
                    downloadID: item.id,
                    message: message
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
    func activeFooterRow(_ item: DownloadManager.ActiveDownload) -> some View {
        if dynamicTypeSize >= .xxLarge {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                qualityBadge(item.qualityLabel)
                activeActionButton(item)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppSpacing.s) {
                    qualityBadge(item.qualityLabel)
                        .fixedSize()
                    Spacer(minLength: 0)
                    activeActionButton(item)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    qualityBadge(item.qualityLabel)
                    activeActionButton(item)
                }
            }
        }
    }

    @ViewBuilder
    func activeActionButton(_ item: DownloadManager.ActiveDownload) -> some View {
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

    func metadataLine(_ item: DownloadManager.ActiveDownload) -> some View {
        HStack {
            Text(leftSlot(item))
                .monospacedDigit()
            Spacer(minLength: AppSpacing.xs)
            Text(rightSlot(item))
                .monospacedDigit()
        }
        .appFont(.libraryRowFooter)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    func activeActions(_ item: DownloadManager.ActiveDownload) -> some View {
        switch item.phase {
        case .failed(let message):
            Button {
                manager.retry(id: item.id)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel(Text("Retry download"))

            Button {
                activeError = ActiveErrorPresentation(
                    downloadID: item.id,
                    message: message
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

    func sectionHeader(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.l)
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

    func showsEmptyState(completed: [DownloadedVideo], active: [DownloadManager.ActiveDownload]) -> Bool {
        guard completed.isEmpty, active.isEmpty else { return false }
        if !query.isEmpty {
            return true
        }
        return exports.activeJob == nil && exports.artifacts.isEmpty
    }

    var emptyState: some View {
        ContentUnavailableView(
            query.isEmpty
                ? LocalizedStringKey("No Downloads")
                : LocalizedStringKey("No Matches"),
            systemImage: "arrow.down.circle",
            description: Text(query.isEmpty
                ? LocalizedStringKey("Videos you download for offline viewing appear here.")
                : LocalizedStringKey("No downloads match your search."))
        )
    }

    func leftSlot(_ item: DownloadManager.ActiveDownload) -> String {
        downloadRowLeftSlot(fraction: item.fraction, phase: item.phase)
    }

    func rightSlot(_ item: DownloadManager.ActiveDownload) -> String {
        downloadRowRightSlot(
            fraction: item.fraction, phase: item.phase,
            formattedSpeed: formattedSpeed(item.speedBytesPerSecond)
        )
    }

    func formattedSpeed(_ bytesPerSecond: Double?) -> String? {
        guard let value = bytesPerSecond, value.isFinite, value >= 0 else { return nil }
        let rounded = value.rounded()
        let readableBytes = rounded >= Double(Int64.max) ? Int64.max : Int64(rounded)
        return "\(byteString(readableBytes))/s"
    }
}

private struct DownloadsStorageSummaryCard: View {
    let downloadedCount: Int
    let totalStorageText: String
    let activeCount: Int
    let brokenCount: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        .background(
            AppFill.card,
            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        )
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
        VStack(alignment: .center, spacing: 2) {
            Text(verbatim: value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
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
                .font(.headline.weight(.semibold))
                .monospacedDigit()
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
