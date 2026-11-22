import CoreTransferable
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PlaybackReportRow: Identifiable, Sendable {
    let id: Int
    let stamp: String
    let line: String
}

@MainActor
@Observable
final class PlaybackReportViewModel {
    private(set) var rows: [PlaybackReportRow] = []
    private(set) var matches: [PlaybackReportRow] = []
    private(set) var query = ""
    private(set) var eventCount = 0
    private(set) var dropped = 0
    private(set) var startedAt: Date?
    private(set) var isPreparing = false
    private(set) var isSearching = false
    private(set) var isSerializing = false
    private(set) var copied = false
    private(set) var liveTail = false

    var isFiltering: Bool { !query.isEmpty }

    @ObservationIgnored private var held = PlaybackDebugRecorder.Snapshot()
    @ObservationIgnored private var cursor = -1
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    private static let batchSize = 500
    private static let searchDebounce = Duration.milliseconds(180)
    private static let tailInterval = Duration.seconds(1)

    // MARK: - Lifecycle

    func start() {
        load()
        if liveTail { startTail() }
    }

    func stop() {
        loadTask?.cancel()
        searchTask?.cancel()
        liveTask?.cancel()
        loadTask = nil
        searchTask = nil
        liveTask = nil
    }

    // MARK: - Reading the ring

    func load() {
        loadTask?.cancel()
        searchTask?.cancel()
        isPreparing = true
        isSearching = false
        copied = false
        rows = []
        matches = []
        loadTask = Task { [weak self] in
            let snapshot = await Self.readRing()
            guard let self, !Task.isCancelled else { return }
            self.held = snapshot
            self.cursor = snapshot.latestSequence
            self.eventCount = snapshot.entries.count
            self.dropped = snapshot.dropped
            self.startedAt = snapshot.startedAt
            await self.publishRows(from: snapshot.entries)
            guard !Task.isCancelled else { return }
            self.isPreparing = false
            if !self.query.isEmpty { self.search(self.query) }
        }
    }

    private func publishRows(from entries: [PlaybackDebugRecorder.Entry]) async {
        var start = 0
        while start < entries.count {
            let end = min(start + Self.batchSize, entries.count)
            let batch = await Self.formatRows(entries, in: start..<end)
            guard !Task.isCancelled else { return }
            rows.append(contentsOf: batch)
            start = end
        }
    }

    // MARK: - Live tail

    func setLiveTail(_ on: Bool) {
        liveTail = on
        liveTask?.cancel()
        liveTask = nil
        if on { startTail() }
    }

    private func startTail() {
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tailInterval)
                guard !Task.isCancelled, let self else { return }
                let resumeAt = self.cursor
                let update = await Self.readRing(after: resumeAt)
                guard !Task.isCancelled else { return }
                if update.latestSequence < resumeAt {
                    self.load()
                    continue
                }
                let fresh = await Self.formatRows(update.entries, in: 0..<update.entries.count)
                guard !Task.isCancelled else { return }
                self.append(update, rows: fresh)
            }
        }
    }

    private func append(_ update: PlaybackDebugRecorder.Snapshot, rows fresh: [PlaybackReportRow]) {
        cursor = max(cursor, update.latestSequence)
        dropped = update.dropped
        guard !fresh.isEmpty else { return }
        held.entries.append(contentsOf: update.entries)
        if held.entries.count > update.capacity {
            held.entries.removeFirst(held.entries.count - update.capacity)
        }
        held.dropped = update.dropped
        held.latestSequence = cursor
        eventCount = held.entries.count
        rows.append(contentsOf: fresh)
        if let oldest = held.entries.first?.id {
            Self.dropRows(&rows, olderThan: oldest)
            Self.dropRows(&matches, olderThan: oldest)
        }
        guard !query.isEmpty, !isSearching else { return }
        let current = query
        matches.append(contentsOf: fresh.filter { Self.lineMatches($0.line, query: current) })
    }

    private static func dropRows(_ rows: inout [PlaybackReportRow], olderThan oldest: Int) {
        var drop = 0
        while drop < rows.count, rows[drop].id < oldest { drop += 1 }
        if drop > 0 { rows.removeFirst(drop) }
    }

    // MARK: - Search

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed
        copied = false
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            matches = []
            isSearching = false
            return
        }
        let corpus = held.entries
        let searchedThrough = corpus.last?.id ?? -1
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            let found = await Self.filterRows(corpus, query: trimmed)
            guard let self, !Task.isCancelled else { return }
            self.matches = found + Self.matchingRows(
                in: self.held.entries,
                after: searchedThrough,
                query: trimmed
            )
            self.isSearching = false
        }
    }

    // MARK: - Export

    func copyVisible() {
        guard !isSerializing else { return }
        isSerializing = true
        let snapshot = held
        let filter = query.isEmpty ? nil : query
        Task { [weak self] in
            let text = await Self.serialize(snapshot, filter: filter)
            UIPasteboard.general.string = text
            guard let self else { return }
            self.isSerializing = false
            self.copied = true
        }
    }

    func resetCapture() {
        stop()
        query = ""
        matches = []
        copied = false
        PlaybackDebugRecorder.shared.reset()
        cursor = -1
        load()
        if liveTail { startTail() }
    }

    func exportPayload() -> PlaybackReportExport {
        PlaybackReportExport(
            snapshot: held,
            filter: query.isEmpty ? nil : query,
            filename: exportFilename
        )
    }

    var exportFilename: String {
        var name = "playback-report"
        let slug = String(query.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-")
            .joined(separator: "-")
        if !slug.isEmpty { name += "-\(slug)" }
        return name + "-" + Self.filenameStamp.string(from: startedAt ?? Date()) + ".txt"
    }

    private static let filenameStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - Off-main-actor work

    private nonisolated static func readRing() async -> PlaybackDebugRecorder.Snapshot {
        PlaybackDebugRecorder.shared.snapshot()
    }

    private nonisolated static func readRing(after sequence: Int) async -> PlaybackDebugRecorder.Snapshot {
        PlaybackDebugRecorder.shared.snapshot(newerThan: sequence)
    }

    private nonisolated static func formatRows(
        _ entries: [PlaybackDebugRecorder.Entry],
        in range: Range<Int>
    ) async -> [PlaybackReportRow] {
        entries[range].map(row(from:))
    }

    private nonisolated static func filterRows(
        _ entries: [PlaybackDebugRecorder.Entry],
        query: String
    ) async -> [PlaybackReportRow] {
        var out: [PlaybackReportRow] = []
        for (index, entry) in entries.enumerated() {
            if index & 0xFF == 0, Task.isCancelled { return out }
            guard lineMatches(entry.line, query: query) else { continue }
            out.append(row(from: entry))
        }
        return out
    }

    private nonisolated static func matchingRows(
        in entries: [PlaybackDebugRecorder.Entry],
        after sequence: Int,
        query: String
    ) -> [PlaybackReportRow] {
        guard let newest = entries.last?.id, newest > sequence else { return [] }
        let fresh = min(entries.count, newest - sequence)
        return entries.suffix(fresh)
            .filter { $0.id > sequence && lineMatches($0.line, query: query) }
            .map(row(from:))
    }

    private nonisolated static func serialize(
        _ snapshot: PlaybackDebugRecorder.Snapshot,
        filter: String?
    ) async -> String {
        PlaybackDebugRecorder.reportText(from: snapshot, filter: filter)
    }

    private nonisolated static func row(from entry: PlaybackDebugRecorder.Entry) -> PlaybackReportRow {
        PlaybackReportRow(
            id: entry.id,
            stamp: String(format: "+%10.3fs", entry.offset),
            line: entry.line
        )
    }

    nonisolated static func lineMatches(_ line: String, query: String) -> Bool {
        PlaybackDebugRecorder.matchesFilter(line, query: query)
    }
}

struct PlaybackReportExport: Transferable, Sendable {
    let snapshot: PlaybackDebugRecorder.Snapshot
    let filter: String?
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { export in
            Data(
                PlaybackDebugRecorder
                    .reportText(from: export.snapshot, filter: export.filter)
                    .utf8
            )
        }
        .suggestedFileName { $0.filename }
    }
}

struct PlaybackDebugReportView: View {
    @State private var model = PlaybackReportViewModel()
    @State private var query = ""
    @State private var showResetPrompt = false

    private var displayed: [PlaybackReportRow] {
        model.isFiltering ? model.matches : model.rows
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            List {
                if displayed.isEmpty {
                    placeholder
                } else {
                    ForEach(displayed) { row in
                        PlaybackReportRowView(row: row)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle(Text("Playback Report"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, newValue in
            model.search(newValue)
        }
        .onChange(of: model.query) { _, modelQuery in
            if modelQuery.isEmpty, !query.isEmpty { query = "" }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.copyVisible()
                } label: {
                    if model.isSerializing {
                        ProgressView()
                    } else {
                        Label {
                            model.copied ? Text("Copied") : Text("Copy")
                        } icon: {
                            Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
                .disabled(model.isSerializing || model.eventCount == 0)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: model.exportPayload(),
                    preview: SharePreview(model.exportFilename)
                ) {
                    Label {
                        Text("Share")
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(model.eventCount == 0)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.setLiveTail(!model.liveTail)
                } label: {
                    Label {
                        Text("Live Tail")
                    } icon: {
                        Image(systemName: model.liveTail ? "record.circle.fill" : "record.circle")
                    }
                }
                .tint(model.liveTail ? Color.red : nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.load()
                } label: {
                    Label {
                        Text("Refresh")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showResetPrompt = true
                } label: {
                    Label {
                        Text("Reset Capture")
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(model.eventCount == 0)
            }
        }
        .confirmationDialog(
            Text("Discard \(model.eventCount) captured events?"),
            isPresented: $showResetPrompt,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                model.resetCapture()
            } label: {
                Text("Discard and Restart")
            }
            Button(role: .cancel) {} label: { Text("Cancel") }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            filterField
            VStack(alignment: .leading, spacing: 2) {
            if model.isFiltering {
                Text("\(model.matches.count) of \(model.eventCount) events match · \(model.dropped) dropped")
            } else {
                Text("\(model.eventCount) events · \(model.dropped) dropped")
            }
            if let startedAt = model.startedAt {
                Text("Capture started \(startedAt.formatted(date: .abbreviated, time: .standard))")
            }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField(text: $query) {
                Text("Filter lines")
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            Button {
                query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.appControl)
            .accessibilityLabel(Text("Clear filter"))
            .opacity(query.isEmpty ? 0 : 1)
            .disabled(query.isEmpty)
            .allowsHitTesting(!query.isEmpty)
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.isPreparing || model.isSearching {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .listRowSeparator(.hidden)
        } else {
            (model.isFiltering ? Text("No matching events.") : Text("No events captured."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .listRowSeparator(.hidden)
        }
    }
}

private struct PlaybackReportRowView: View {
    let row: PlaybackReportRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: row.stamp)
                .foregroundStyle(.secondary)
            Text(verbatim: row.line)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)
        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
        .listRowSeparator(.hidden)
    }
}
