import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Query(sort: \DownloadedVideo.addedAt, order: .reverse)
    var downloads: [DownloadedVideo]
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search = ""
    @State private var invalidDownloadID: String?
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

    private func coverWidth(columnWidth: CGFloat?) -> CGFloat {
        LibraryRowMetrics.coverWidth(
            columnWidth: columnWidth,
            isRegularWidth: sizeClass == .regular
        )
    }

    var body: some View {
        let completed = filtered
        let active = filteredActive
        return downloadsScrollContent(completed: completed, active: active)
            .appAmbientBrowseBackground()
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search downloads")
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
            .alert("Export", isPresented: Binding(
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

    func downloadRow(_ item: DownloadedVideo) -> some View {
        VideoListRowView(
            sources: VideoCoverSources(widescreen: item.coverURL),
            title: item.title,
            subtitle: item.ownerName,
            durationText: FormatUtils.duration(item.durationSeconds),
            progress: item.watchedFraction
        ) {
            HStack(spacing: 6) {
                qualityBadge(item.qualityLabel)
                Text(byteString(item.fileSizeBytes))
                    .monospacedDigit()
                if brokenIDs.contains(item.id) {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                        Text("Missing files")
                    }
                    .foregroundStyle(.red)
                }
            }
            .appFont(.libraryRowMeta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
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
                    .background(
                        AppFill.card,
                        in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    )
                    .contextMenu { activeActions(item) }
                    .padding(.horizontal, AppSpacing.xs)
                    .padding(.vertical, AppSpacing.xs)
                }
            }
            .padding(.horizontal, AppSpacing.m)
        }
    }

    func completedSection(_ completed: [DownloadedVideo]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            sectionHeader { storageSummaryHeader(for: completed) }
            LibraryRowLayout {
                ForEach(completed) { item in
                    completedRow(item, in: completed)
                        .padding(.trailing, AppSpacing.xs)
                        .background(
                            AppFill.card,
                            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        )
                        .contextMenu { completedActions(item, in: completed) }
                        .padding(.horizontal, AppSpacing.xs)
                        .padding(.vertical, AppSpacing.xs)
                }
            }
            .padding(.horizontal, AppSpacing.m)
        }
    }

    var storageSummaryCard: some View {
        let totalBytes = downloads.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let runningCount = manager.active.filter { !$0.phase.isResumable }.count
        let resumableCount = manager.active.filter { $0.phase.isResumable }.count
        return DownloadsStorageSummaryCard(
            downloadedCount: downloads.count,
            totalStorageText: byteString(totalBytes),
            activeCount: manager.active.count,
            runningCount: runningCount,
            resumableCount: resumableCount,
            brokenCount: brokenIDs.count,
            onPauseAll: pauseAllActive,
            onResumeAll: resumeAllActive
        )
        .padding(.horizontal, AppSpacing.l)
    }

    func pauseAllActive() {
        for item in manager.active where !item.phase.isResumable {
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
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack(alignment: .top, spacing: RowGeometry.coverToTextSpacing) {
                VideoCoverImage(
                    sources: VideoCoverSources(widescreen: item.coverURL),
                    width: coverWidth(columnWidth: columnWidth)
                )
                .videoCoverFrame(cornerRadius: AppRadius.thumbnail)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .appFont(.libraryRowTitle)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    activeProgressContent(item)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    activeActions(item)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Download actions"))
            }
            .padding(.leading, LibraryRowMetrics.horizontalInset)
            .padding(.trailing, AppSpacing.xs)
            .padding(.top, AppSpacing.m)

            activeTransportBar(item)
                .padding(.leading, LibraryRowMetrics.horizontalInset)
                .padding(.trailing, AppSpacing.m)
                .padding(.bottom, AppSpacing.s)
        }
    }

    @ViewBuilder
    func activeProgressContent(_ item: DownloadManager.ActiveDownload) -> some View {
        switch item.phase {
        case .failed(let message):
            HStack(alignment: .top, spacing: AppSpacing.xs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        case .paused:
            if let fraction = item.fraction {
                ProgressView(value: fraction)
                    .tint(.secondary)
            }
            metadataLine(item)
        default:
            if let fraction = item.fraction {
                ProgressView(value: fraction)
                    .tint(.biliAccent)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.biliAccent)
            }
            metadataLine(item)
        }
    }

    func activeTransportBar(_ item: DownloadManager.ActiveDownload) -> some View {
        let stacksVertically = dynamicTypeSize >= .xxLarge
        let layout: AnyLayout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: AppSpacing.s))
        return layout {
            qualityBadge(item.qualityLabel)
            if !stacksVertically {
                Spacer(minLength: 0)
            }
            activePrimaryButton(item)
        }
    }

    func activePrimaryButton(_ item: DownloadManager.ActiveDownload) -> some View {
        let isResumable = item.phase.isResumable
        let icon: String = if case .failed = item.phase {
            "arrow.clockwise"
        } else if isResumable {
            "play.fill"
        } else {
            "pause.fill"
        }
        return Button {
            if isResumable {
                manager.retry(id: item.id)
            } else {
                manager.pause(id: item.id)
            }
        } label: {
            Label {
                Text(isResumable ? LocalizedStringKey("Resume") : LocalizedStringKey("Pause"))
            } icon: {
                Image(systemName: icon)
            }
            .appFont(.controlLabel)
            .fontWeight(.medium)
            .foregroundStyle(isResumable ? Color.white : Color.biliAccent)
            .padding(.horizontal, AppSpacing.m)
            .frame(minWidth: 44, minHeight: 44)
            .background(
                isResumable
                    ? AnyShapeStyle(AccentStore.shared.badgeFill)
                    : AnyShapeStyle(Color.biliAccent.opacity(0.14)),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(
            isResumable ? Text("Resume download") : Text("Pause download")
        )
    }

    func qualityBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(AccentStore.shared.badgeFill, in: RoundedRectangle(cornerRadius: AppRadius.badge))
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
        if item.phase.isResumable {
            Button {
                manager.retry(id: item.id)
            } label: {
                Label("Resume", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel(Text("Resume download"))
        } else {
            Button {
                manager.pause(id: item.id)
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .accessibilityLabel(Text("Pause download"))
        }
        Button {
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
            .padding(.horizontal, AppSpacing.l + AppSpacing.xs)
    }

    func storageSummaryHeader(for shown: [DownloadedVideo]) -> some View {
        HStack {
            Text(String(format: String(localized: "%d videos"), shown.count))
                .monospacedDigit()
            Spacer()
            Text(String(
                format: String(localized: "%@ used"),
                byteString(shown.reduce(0) { $0 + $1.fileSizeBytes })
            ))
            .monospacedDigit()
        }
    }

    func showsEmptyState(completed: [DownloadedVideo], active: [DownloadManager.ActiveDownload]) -> Bool {
        completed.isEmpty && active.isEmpty
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

    func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct DownloadsStorageSummaryCard: View {
    let downloadedCount: Int
    let totalStorageText: String
    let activeCount: Int
    let runningCount: Int
    let resumableCount: Int
    let brokenCount: Int
    let onPauseAll: () -> Void
    let onResumeAll: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            HStack(spacing: AppSpacing.s) {
                Image(systemName: "internaldrive.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.biliAccent)
                    .accessibilityHidden(true)
                Text("Downloads & Storage")
                    .appFont(.sectionTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            metricsGrid

            if activeCount > 0 {
                bulkActions
            }

            if brokenCount > 0 {
                missingFilesBanner
            }
        }
        .padding(AppSpacing.l)
        .background(
            AppFill.card,
            in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
        )
    }

    @ViewBuilder
    private var metricsGrid: some View {
        if dynamicTypeSize >= .xxLarge {
            stackedMetrics
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppSpacing.s) {
                    horizontalMetricTile(title: "Downloaded", value: downloadedCount.formatted(), tint: .primary)
                    horizontalMetricTile(title: "Storage", value: totalStorageText, tint: .primary)
                    horizontalMetricTile(
                        title: "Downloading",
                        value: activeCount.formatted(),
                        tint: activeCount > 0 ? .biliAccent : .primary
                    )
                }
                stackedMetrics
            }
        }
    }

    private var stackedMetrics: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            stackedMetricRow(title: "Downloaded", value: downloadedCount.formatted(), tint: .primary)
            stackedMetricRow(title: "Storage", value: totalStorageText, tint: .primary)
            stackedMetricRow(
                title: "Downloading",
                value: activeCount.formatted(),
                tint: activeCount > 0 ? .biliAccent : .primary
            )
        }
    }

    private func horizontalMetricTile(title: LocalizedStringKey, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, AppSpacing.s)
        .background(
            AppFill.inset,
            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func stackedMetricRow(title: LocalizedStringKey, value: String, tint: Color) -> some View {
        let stacksVertically = dynamicTypeSize.isAccessibilitySize
        let layout: AnyLayout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.xs))
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
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, AppSpacing.s)
        .background(
            AppFill.inset,
            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private var bulkActions: some View {
        let layout: AnyLayout = dynamicTypeSize >= .xxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.s))
            : AnyLayout(HStackLayout(spacing: AppSpacing.s))
        return layout {
            if runningCount > 0 {
                Button(action: onPauseAll) {
                    Label("Pause All", systemImage: "pause.fill")
                        .appFont(.controlLabel)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, AppSpacing.m)
                        .background(
                            AppFill.inset,
                            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                }
                .buttonStyle(.appControl)
            }
            if resumableCount > 0 {
                Button(action: onResumeAll) {
                    Label("Resume All", systemImage: "play.fill")
                        .appFont(.controlLabel)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, AppSpacing.m)
                        .background(
                            AccentStore.shared.badgeFill,
                            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                }
                .buttonStyle(.appControl)
            }
        }
    }

    private var missingFilesBanner: some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "%d downloads have missing files"), brokenCount))
                    .appFont(.libraryRowMeta)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text("Downloaded files are missing or corrupt.")
                    .appFont(.libraryRowFooter)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppSpacing.m)
        .background(
            Color.red.opacity(0.10),
            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        )
    }
}
