import SwiftData
import SwiftUI

struct BatchDownloadEpisodeItem: Identifiable, Hashable, Sendable {
    let aid: Int
    let bvid: String
    let cid: Int
    let epId: Int?
    let indexLabel: String
    let title: String
    let downloadTitle: String
    let durationSeconds: Int
    let coverURL: String
    let ownerName: String

    var downloadID: String { "\(bvid)_\(cid)" }
    var id: String { downloadID }

    init(
        aid: Int,
        bvid: String,
        cid: Int,
        epId: Int? = nil,
        indexLabel: String,
        title: String,
        downloadTitle: String? = nil,
        durationSeconds: Int,
        coverURL: String,
        ownerName: String
    ) {
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.epId = epId
        self.indexLabel = indexLabel
        self.title = title
        self.downloadTitle = downloadTitle ?? title
        self.durationSeconds = durationSeconds
        self.coverURL = coverURL
        self.ownerName = ownerName
    }
}

enum BatchDownloadItemStatus: Equatable, Sendable {
    case uncached
    case downloading(fraction: Double?)
    case cached

    var isSelectable: Bool {
        self == .uncached
    }
}

struct BatchDownloadSelectionState: Equatable, Sendable {
    let items: [BatchDownloadEpisodeItem]
    private(set) var statuses: [String: BatchDownloadItemStatus]
    private(set) var selectedIDs: Set<String>

    init(
        items: [BatchDownloadEpisodeItem],
        statuses: [String: BatchDownloadItemStatus] = [:],
        initialSelection: Set<String> = []
    ) {
        self.items = items
        self.statuses = statuses
        let validSelectableIDs = Set(
            items.compactMap { item -> String? in
                let status = statuses[item.id] ?? .uncached
                return status.isSelectable ? item.id : nil
            }
        )
        self.selectedIDs = initialSelection.intersection(validSelectableIDs)
    }

    func status(for id: String) -> BatchDownloadItemStatus {
        statuses[id] ?? .uncached
    }

    var selectableItems: [BatchDownloadEpisodeItem] {
        items.filter { status(for: $0.id).isSelectable }
    }

    var selectedItems: [BatchDownloadEpisodeItem] {
        items.filter { selectedIDs.contains($0.id) && status(for: $0.id).isSelectable }
    }

    var selectedCount: Int {
        selectedItems.count
    }

    var cachedCount: Int {
        items.reduce(into: 0) { count, item in
            if status(for: item.id) == .cached { count += 1 }
        }
    }

    var downloadingCount: Int {
        items.reduce(into: 0) { count, item in
            if case .downloading = status(for: item.id) { count += 1 }
        }
    }

    var hasSelectableUncachedItems: Bool {
        !selectableItems.isEmpty
    }

    var allUncachedSelected: Bool {
        let selectable = selectableItems
        guard !selectable.isEmpty else { return false }
        return selectable.allSatisfy { selectedIDs.contains($0.id) }
    }

    mutating func toggle(_ id: String) {
        guard status(for: id).isSelectable,
              items.contains(where: { $0.id == id }) else {
            return
        }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    mutating func selectAllUncached() {
        selectedIDs = Set(selectableItems.map(\.id))
    }

    mutating func deselectAll() {
        selectedIDs.removeAll()
    }

    mutating func reconcileStatuses(_ nextStatuses: [String: BatchDownloadItemStatus]) {
        statuses = nextStatuses
        selectedIDs = selectedIDs.filter { id in
            status(for: id).isSelectable && items.contains(where: { $0.id == id })
        }
    }

    static func defaultQualityCode(
        from qualities: [DownloadQualityOption],
        preferredWiFiQuality: Int = PlayerPlaybackPreferences.wifiQuality
    ) -> Int {
        guard !qualities.isEmpty else { return preferredWiFiQuality }
        if qualities.contains(where: { $0.code == preferredWiFiQuality }) {
            return preferredWiFiQuality
        }
        if let bestUnderPreferred = qualities
            .filter({ $0.code <= preferredWiFiQuality })
            .max(by: { $0.code < $1.code }) {
            return bestUnderPreferred.code
        }
        return qualities[0].code
    }

    @MainActor
    static func fallbackQualities() -> [DownloadQualityOption] {
        [116, 80, 64, 32].map { code in
            DownloadQualityOption(
                code: code,
                label: PlayerViewModel.qualityLabel(for: code),
                estimatedBytes: nil
            )
        }
    }

    static func items(from info: VideoInfo) -> [BatchDownloadEpisodeItem] {
        guard let pages = info.pages, !pages.isEmpty else { return [] }
        return pages.map { page in
            let indexLabel = "P\(page.page)"
            let partTitle = page.part.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = partTitle.isEmpty ? indexLabel : partTitle
            let downloadTitle = partTitle.isEmpty
                ? "\(info.title) (\(indexLabel))"
                : "\(info.title) - \(indexLabel) \(partTitle)"
            return BatchDownloadEpisodeItem(
                aid: info.aid,
                bvid: info.bvid,
                cid: page.cid,
                epId: nil,
                indexLabel: indexLabel,
                title: displayTitle,
                downloadTitle: downloadTitle,
                durationSeconds: page.duration > 0 ? page.duration : info.duration,
                coverURL: info.pic,
                ownerName: info.owner.name
            )
        }
    }

    static func items(from season: PGCSeasonInfo) -> [BatchDownloadEpisodeItem] {
        guard let episodes = season.episodes, !episodes.isEmpty else { return [] }
        let seasonTitle = season.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedSeasonTitle = seasonTitle.isEmpty ? String(localized: "Anime") : seasonTitle
        var seenIDs = Set<String>()
        return episodes.compactMap { episode in
            guard let aid = episode.aid, aid > 0,
                  let cid = episode.cid, cid > 0 else { return nil }
            let rawBvid = episode.bvid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bvid = rawBvid.isEmpty ? "ep\(episode.id)" : rawBvid
            let downloadID = "\(bvid)_\(cid)"
            guard seenIDs.insert(downloadID).inserted else { return nil }
            let longTitle = episode.longTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rowTitle = longTitle.isEmpty ? episode.indexLabel : longTitle
            let cover = (episode.cover?.isEmpty == false ? episode.cover : season.cover) ?? ""
            return BatchDownloadEpisodeItem(
                aid: aid,
                bvid: bvid,
                cid: cid,
                epId: episode.id,
                indexLabel: episode.indexLabel,
                title: rowTitle,
                downloadTitle: "\(resolvedSeasonTitle) - \(episode.displayTitle)",
                durationSeconds: 0,
                coverURL: cover,
                ownerName: resolvedSeasonTitle
            )
        }
    }
}

struct BatchDownloadPresentation: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let items: [BatchDownloadEpisodeItem]
    let qualities: [DownloadQualityOption]
    let initialSelectedID: String?

    init(
        title: String,
        items: [BatchDownloadEpisodeItem],
        qualities: [DownloadQualityOption],
        initialSelectedID: String? = nil
    ) {
        self.title = title
        self.items = items
        self.qualities = qualities
        self.initialSelectedID = initialSelectedID
    }
}

struct BatchEpisodeDownloadSheet: View {
    let title: String
    let items: [BatchDownloadEpisodeItem]
    let qualities: [DownloadQualityOption]
    let initialSelectedID: String?
    var onEnqueued: ((Int) -> Void)?

    @Query private var downloadedVideos: [DownloadedVideo]
    @State private var selectionState: BatchDownloadSelectionState
    @State private var selectedQualityCode: Int
    @State private var validDownloadedIDs: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private let manager = DownloadManager.shared

    private var effectiveQualities: [DownloadQualityOption] {
        qualities.isEmpty ? BatchDownloadSelectionState.fallbackQualities() : qualities
    }

    init(
        title: String,
        items: [BatchDownloadEpisodeItem],
        qualities: [DownloadQualityOption],
        initialSelectedID: String? = nil,
        onEnqueued: ((Int) -> Void)? = nil
    ) {
        self.title = title
        self.items = items
        self.qualities = qualities
        self.initialSelectedID = initialSelectedID
        self.onEnqueued = onEnqueued
        let effective = qualities.isEmpty ? BatchDownloadSelectionState.fallbackQualities() : qualities
        _selectedQualityCode = State(
            initialValue: BatchDownloadSelectionState.defaultQualityCode(from: effective)
        )
        let initialSet: Set<String> = initialSelectedID.map { [$0] } ?? []
        _selectionState = State(
            initialValue: BatchDownloadSelectionState(
                items: items,
                statuses: [:],
                initialSelection: initialSet
            )
        )
    }

    private var selectedQualityOption: DownloadQualityOption? {
        effectiveQualities.first(where: { $0.code == selectedQualityCode })
            ?? effectiveQualities.first
    }

    private var relevantDownloadedSnapshots: [DownloadFileSnapshot] {
        let itemIDs = Set(items.map(\.id))
        return downloadedVideos.compactMap { video in
            itemIDs.contains(video.id) ? video.fileSnapshot : nil
        }
    }

    private var liveStatuses: [String: BatchDownloadItemStatus] {
        let activeByID = Dictionary(
            manager.active.map { ($0.id, $0.fraction) },
            uniquingKeysWith: { first, _ in first }
        )
        var map: [String: BatchDownloadItemStatus] = [:]
        map.reserveCapacity(items.count)
        for item in items {
            if validDownloadedIDs.contains(item.id) {
                map[item.id] = .cached
            } else if let fraction = activeByID[item.id] {
                map[item.id] = .downloading(fraction: fraction)
            } else {
                map[item.id] = .uncached
            }
        }
        return map
    }

    var body: some View {
        accentedBody
            .accentContentBoundary()
            .appAdaptiveSheet(compactDetents: [.medium, .large], padSizing: .form)
    }

    @ViewBuilder
    private var accentedBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controlBar
                Divider()
                episodeList
            }
            .navigationTitle("Batch Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    qualityMenu
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
        }
        .task(id: relevantDownloadedSnapshots) {
            await refreshValidDownloads(snapshots: relevantDownloadedSnapshots)
        }
        .onAppear {
            selectionState.reconcileStatuses(liveStatuses)
        }
        .onChange(of: liveStatuses) { _, next in
            selectionState.reconcileStatuses(next)
        }
    }

    private func refreshValidDownloads(snapshots: [DownloadFileSnapshot]) async {
        guard !snapshots.isEmpty else {
            validDownloadedIDs = []
            return
        }
        guard let valid = try? await DownloadFileSnapshot.validSnapshots(in: snapshots),
              !Task.isCancelled else { return }
        validDownloadedIDs = Set(valid.map(\.id))
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(effectiveQualities, id: \.code) { option in
                Button {
                    selectedQualityCode = option.code
                } label: {
                    HStack {
                        Text(option.label)
                        if option.code == selectedQualityCode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedQualityOption?.label ?? PlayerViewModel.qualityLabel(for: selectedQualityCode))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.biliAccent)
        }
        .accessibilityIdentifier("batchDownload.qualityMenu")
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(summarySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button("Select All Uncached") {
                    selectionState.selectAllUncached()
                }
                .font(.footnote.weight(.medium))
                .disabled(!selectionState.hasSelectableUncachedItems || selectionState.allUncachedSelected)
                .accessibilityIdentifier("batchDownload.selectAllUncached")

                Button("Deselect All") {
                    selectionState.deselectAll()
                }
                .font(.footnote.weight(.medium))
                .disabled(selectionState.selectedCount == 0)
                .accessibilityIdentifier("batchDownload.deselectAll")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summarySubtitle: String {
        let total = items.count
        let cached = selectionState.cachedCount
        let active = selectionState.downloadingCount
        if active > 0 {
            return String(
                format: String(localized: "%lld cached, %lld downloading, %lld total"),
                cached,
                active,
                total
            )
        }
        return String(
            format: String(localized: "%lld of %lld cached"),
            cached,
            total
        )
    }

    private var episodeList: some View {
        List {
            ForEach(items) { item in
                episodeRow(for: item)
            }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Downloadable Episodes",
                    systemImage: "arrow.down.circle"
                )
            }
        }
    }

    private func episodeRow(for item: BatchDownloadEpisodeItem) -> some View {
        let status = selectionState.status(for: item.id)
        let isSelected = selectionState.selectedIDs.contains(item.id)
        return Button {
            selectionState.toggle(item.id)
        } label: {
            HStack(spacing: 12) {
                statusLeadingIcon(status: status, isSelected: isSelected)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.indexLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status == .uncached ? Color.biliAccent : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (status == .uncached ? Color.biliAccent.opacity(0.14) : Color.secondary.opacity(0.12)),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )

                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(status.isSelectable ? .primary : .secondary)
                            .lineLimit(2)
                    }

                    if item.durationSeconds > 0 {
                        Text(FormatUtils.duration(item.durationSeconds))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 8)

                statusTrailingBadge(status: status)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!status.isSelectable)
    }

    @ViewBuilder
    private func statusLeadingIcon(status: BatchDownloadItemStatus, isSelected: Bool) -> some View {
        switch status {
        case .cached:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .uncached:
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.biliAccent) : AnyShapeStyle(.tertiary))
        }
    }

    @ViewBuilder
    private func statusTrailingBadge(status: BatchDownloadItemStatus) -> some View {
        switch status {
        case .cached:
            Text("Cached")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.green.opacity(0.12), in: Capsule())
        case .downloading(let fraction):
            HStack(spacing: 4) {
                Text("Downloading")
                if let fraction, fraction.isFinite, fraction > 0 {
                    Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                        .monospacedDigit()
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.biliAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.biliAccent.opacity(0.12), in: Capsule())
        case .uncached:
            EmptyView()
        }
    }

    private var bottomActionBar: some View {
        let count = selectionState.selectedCount
        return VStack(spacing: 0) {
            Divider()
            Button {
                enqueueSelected()
            } label: {
                Text(String(format: String(localized: "Cache Selected (%lld)"), count))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.biliAccent)
            .disabled(count == 0)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityIdentifier("batchDownload.confirm")
        }
        .background(.bar)
    }

    private func enqueueSelected() {
        let toEnqueue = selectionState.selectedItems
        guard !toEnqueue.isEmpty else { return }
        let quality = selectedQualityCode
        for item in toEnqueue {
            if let existing = manager.existing(bvid: item.bvid, cid: item.cid), !existing.filesExist {
                _ = manager.delete(existing)
            }
        }
        Task { @MainActor in
            for item in toEnqueue {
                await manager.startDownload(
                    aid: item.aid,
                    cid: item.cid,
                    bvid: item.bvid,
                    title: item.downloadTitle,
                    coverURL: item.coverURL,
                    ownerName: item.ownerName,
                    durationSeconds: item.durationSeconds,
                    quality: quality,
                    epId: item.epId
                )
            }
        }
        onEnqueued?(toEnqueue.count)
        dismiss()
    }
}
