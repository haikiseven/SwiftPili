import CoreTransferable
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One prepared report line.
///
/// The stamp is formatted ONCE, in the background pass that builds the row —
/// never in `body`, which would re-run `String(format:)` for every realized row
/// on every re-render and every scroll tick.
///
/// File scope rather than nested inside the `@MainActor` view model on purpose:
/// the formatter that builds these runs off the main actor, so the type it
/// constructs must not be actor-isolated.
struct PlaybackReportRow: Identifiable, Sendable {
    /// The recorder's record sequence — stable while the ring rolls, so a live
    /// append diffs as an append instead of reshuffling every row identity.
    let id: Int
    let stamp: String
    let line: String
}

/// Backs `PlaybackDebugReportView`: owns the held snapshot, the prepared rows,
/// and the three cancellable tasks (prepare / search / live tail).
///
/// Kept in this file with its only client — the screen is one self-contained
/// diagnostic surface, and its plumbing has no other caller.
@MainActor
@Observable
final class PlaybackReportViewModel {
    /// Rows of the held snapshot, oldest first — the report's existing
    /// user-facing order, and the order Copy All has always produced.
    private(set) var rows: [PlaybackReportRow] = []
    /// Search results over the WHOLE snapshot (not merely the realized rows).
    private(set) var matches: [PlaybackReportRow] = []
    /// The trimmed live filter. Observable because `isFiltering` is derived
    /// from it and decides which of the two arrays the list renders — a
    /// whitespace-only field must show the whole report, not "no matches".
    private(set) var query = ""
    private(set) var eventCount = 0
    private(set) var dropped = 0
    private(set) var startedAt: Date?
    /// True while the background pass is still formatting the tail of the ring.
    private(set) var isPreparing = false
    private(set) var isSearching = false
    /// True while Copy All is serializing. The only thing that ever builds the
    /// full text, and it is user-initiated.
    private(set) var isSerializing = false
    private(set) var copied = false
    private(set) var liveTail = false

    var isFiltering: Bool { !query.isEmpty }

    /// The snapshot this viewer holds: the search corpus AND the export source,
    /// so both cover the whole report rather than what happens to be realized.
    /// `@ObservationIgnored` — the view reads the `rows`/count mirrors, and
    /// invalidating on the corpus would redraw the list for every tail append.
    @ObservationIgnored private var held = PlaybackDebugRecorder.Snapshot()
    /// Highest sequence already displayed; what the incremental read resumes at.
    @ObservationIgnored private var cursor = -1
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    /// Rows formatted per hop back to the main actor. The first batch is what
    /// the screen shows; the rest stream in behind it, below the fold.
    private static let batchSize = 500
    /// Keystroke-collapsing window for search.
    private static let searchDebounce = Duration.milliseconds(180)
    private static let tailInterval = Duration.seconds(1)

    // MARK: - Lifecycle

    func start() {
        load()
        if liveTail { startTail() }
    }

    /// Leaving the screen must not leave a 1 Hz poll or a half-finished
    /// formatting pass running behind it.
    func stop() {
        loadTask?.cancel()
        searchTask?.cancel()
        liveTask?.cancel()
        loadTask = nil
        searchTask = nil
        liveTask = nil
    }

    // MARK: - Reading the ring

    /// Re-reads the ring into a fresh frozen snapshot. Nothing here touches the
    /// main actor except assigning already-prepared values: the lock-guarded
    /// ring copy and all row formatting happen on the cooperative pool.
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
            // A live query survives a Refresh; re-run it against the new read.
            if !self.query.isEmpty { self.search(self.query) }
        }
    }

    /// Formats in background batches and appends each batch on the main actor,
    /// so the first screenful is on screen before the tail of a full ring has
    /// been touched at all.
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

    /// Frozen snapshot by default — the documented behaviour of this screen,
    /// and the right default for reading a capture that is still being written.
    /// The opt-in tail is a 1 Hz PULL, deliberately: the recorder is written
    /// from the player's own threads under a lock, so a push callback would hop
    /// arbitrary audio/network threads onto the main actor once per emitted
    /// line. Each poll asks only for what is newer than the cursor, so an
    /// append costs O(new events) and never re-reads or re-formats the ring.
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
                // The capture was restarted under us (sequences re-based), so
                // the cursor names events that no longer exist: re-read whole.
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
        // Mirror the ring's own bound: a long tail must not grow the viewer
        // past the capture it is showing.
        if held.entries.count > update.capacity {
            held.entries.removeFirst(held.entries.count - update.capacity)
        }
        held.dropped = update.dropped
        held.latestSequence = cursor
        eventCount = held.entries.count
        rows.append(contentsOf: fresh)
        // Whatever the corpus rolled past leaves the rendered list and the
        // filtered list with it, so neither can outlive what it is a view of.
        if let oldest = held.entries.first?.id {
            Self.dropRows(&rows, olderThan: oldest)
            Self.dropRows(&matches, olderThan: oldest)
        }
        // A search pass in flight tops itself up from `held` when it lands, so
        // appending here as well would double-count these rows.
        guard !query.isEmpty, !isSearching else { return }
        let current = query
        matches.append(contentsOf: fresh.filter { Self.lineMatches($0.line, query: current) })
    }

    /// Drops the leading rows the ring has rolled past. Sequences ascend, so
    /// the stale part is always a prefix: O(dropped), never a full scan.
    private static func dropRows(_ rows: inout [PlaybackReportRow], olderThan oldest: Int) {
        var drop = 0
        while drop < rows.count, rows[drop].id < oldest { drop += 1 }
        if drop > 0 { rows.removeFirst(drop) }
    }

    // MARK: - Search

    /// Runs over the whole snapshot, off the main actor, in ONE cancellable
    /// task: the previous pass is cancelled before a new one starts, so typing
    /// cannot queue N passes over 2500 lines.
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed
        // The export follows the filter, so a "Copied" badge earned under the
        // previous scope would now describe something the clipboard no longer
        // holds.
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
            // Debounce: a keystroke inside this window cancels the whole task
            // before it reads a single line.
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            let found = await Self.filterRows(corpus, query: trimmed)
            guard let self, !Task.isCancelled else { return }
            // The live tail may have appended behind this pass; `corpus` was a
            // copy taken before those. Top up from the held snapshot so the
            // result set is complete without rescanning what was just scanned.
            self.matches = found + Self.matchingRows(
                in: self.held.entries,
                after: searchedThrough,
                query: trimmed
            )
            self.isSearching = false
        }
    }

    // MARK: - Export

    /// Copies what the screen is showing: with a filter active the export is
    /// the matched lines, not the whole ring.
    ///
    /// This used to copy the entire snapshot regardless of the filter, on the
    /// reasoning that an export should never be partial. That reasoning was
    /// wrong in the one way that matters — the clipboard is not a reliable
    /// transport at this size. A full capture is ~0.24 MB, and twice a pasted
    /// report arrived with its middle silently missing while this screen's own
    /// header reported `0 older events dropped`: the loss was in the transfer,
    /// and the app had made it as large as it could possibly be. Narrowing the
    /// payload to what was asked for is the fix; `reportText` stamps the filter
    /// into the header so a narrowed artifact declares itself rather than
    /// passing for a whole capture.
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

    /// Clears the ring and re-reads it, so the next capture starts at this
    /// moment.
    ///
    /// The reason this earned a control of its own: a report is read by
    /// reproducing something and then looking for it, and a 2500-event ring
    /// that already holds ten minutes of unrelated playback buries the twenty
    /// lines that matter. Refresh re-reads what is there; this decides what
    /// there is. Timestamps are relative to capture start, so resetting also
    /// re-zeroes them onto the reproduction.
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

    /// The share payload for the current scope — the transport that has no size
    /// limit to be caught by, for the case where the whole capture is genuinely
    /// what is wanted.
    ///
    /// Holds the snapshot and the filter, never the text: `Transferable`
    /// resolves the bytes only once a destination has been chosen, so building
    /// this on every body pass costs an array retain rather than a 0.24 MB
    /// serialization on the main actor.
    func exportPayload() -> PlaybackReportExport {
        PlaybackReportExport(
            snapshot: held,
            filter: query.isEmpty ? nil : query,
            filename: exportFilename
        )
    }

    /// Names the scope and the capture, so several reports pulled off one
    /// device during one session do not all arrive called the same thing.
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
        // POSIX locale: a filename must not change shape with the device's
        // region, and a non-Gregorian calendar would produce a stamp that no
        // longer sorts alongside the others.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - Off-main-actor work
    //
    // `nonisolated` + `async`: these run on the cooperative pool rather than
    // inheriting the caller's main-actor isolation, which is the whole point —
    // the ring copy, `String(format:)` × 2500, the filter pass and the 0.4 MB
    // serialization must never land on the thread that has to draw.

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
            // Cancellation checkpoint every 256 lines: a keystroke abandons the
            // pass instead of finishing it and throwing the result away.
            if index & 0xFF == 0, Task.isCancelled { return out }
            guard lineMatches(entry.line, query: query) else { continue }
            out.append(row(from: entry))
        }
        return out
    }

    /// Matching rows recorded after `sequence`. Sequences are contiguous, so
    /// the count is arithmetic and the scan touches only the new tail —
    /// O(new events), which is what makes the search top-up affordable on the
    /// main actor.
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

    /// The one place a row is built, so the timestamp a row shows cannot drift
    /// from the one the exported text prints.
    private nonisolated static func row(from entry: PlaybackDebugRecorder.Entry) -> PlaybackReportRow {
        PlaybackReportRow(
            id: entry.id,
            stamp: String(format: "+%10.3fs", entry.offset),
            line: entry.line
        )
    }

    /// The filter predicate lives in `PlaybackDebugRecorder` because the export
    /// applies it too, and a filtered export that matched a different rule than
    /// the list would be a report of lines the user never saw. Forwarded here
    /// because the live-tail append and the full pass both sit in this file.
    nonisolated static func lineMatches(_ line: String, query: String) -> Bool {
        PlaybackDebugRecorder.matchesFilter(line, query: query)
    }
}

/// The Playback Report's share payload — a real `.txt` file rather than a
/// clipboard string.
///
/// It exists because the clipboard turned out to be the lossy part of getting a
/// capture off the device: a full ring is ~0.24 MB, and a pasted report twice
/// arrived with its middle gone while the header still read
/// `0 older events dropped`. A file transfers whole or fails visibly, which is
/// the property a diagnostic artifact needs.
///
/// The bytes are produced INSIDE the representation, so nothing is serialized
/// until a share destination has actually been picked — a `ShareLink` over an
/// eagerly built `String` would re-serialize the ring on every body pass.
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

/// Row-virtualized view over the `PlaybackDebugRecorder` ring — the dedicated
/// diagnostic entry in Settings → Playback for pulling a freeze capture off the
/// device by hand — no tethered Mac, no console. Two transports, because they
/// fail differently: Copy for the narrow case (a filter active, a handful of
/// lines, straight into a chat), Share for the whole capture, which is too big
/// to survive a clipboard paste intact.
///
/// Why rows and not one `Text`: a full ring is 2500 lines / ~0.24 MB, and a
/// single selectable `Text` in a `ScrollView` has to lay the WHOLE document out
/// on the main actor before the first frame — so the report stalled on open,
/// worse the longer the capture. `List` realizes only what is on screen, so
/// opening costs a screenful, and the 2500-line serialization happens only when
/// Copy All asks for it (off the main actor, complete, unaffected by the
/// search filter).
///
/// Content is a frozen snapshot — Refresh re-reads the ring — with an opt-in
/// Live Tail that appends only what was recorded since the last read.
struct PlaybackDebugReportView: View {
    @State private var model = PlaybackReportViewModel()
    @State private var query = ""
    @State private var showResetPrompt = false

    /// The model's trimmed filter decides this, not the raw field text: a
    /// whitespace-only query filters nothing, so it must show the whole report
    /// rather than an empty "no matches".
    private var displayed: [PlaybackReportRow] {
        model.isFiltering ? model.matches : model.rows
    }

    var body: some View {
        // The control bar is a SIBLING of the list, not a row or a section
        // header inside it.
        //
        // It was a pinned section header, and typing in the filter kept getting
        // interrupted: every keystroke changes `matches`, which changes the
        // section's content, and SwiftUI rebuilds a list header when its
        // section rebuilds — taking first responder away from the text field
        // mid-word. Re-asserting focus with `@FocusState` would be a guard
        // around a producer that publishes a broken state; keeping the field
        // out of the list means the state is never produced. Nothing here
        // depends on list identity, so it survives every append the live tail
        // makes.
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
            // Scrolling the log puts the keyboard away; the field stays on
            // screen because it is not part of what scrolled.
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle(Text("Playback Report"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, newValue in
            model.search(newValue)
        }
        // A reset clears the model's filter; the field holds its own copy, so
        // without this the box would still show a query that no longer filters
        // anything.
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
                            // Ternary INSIDE Text() would bypass localization —
                            // the String overload wins over LocalizedStringKey.
                            model.copied ? Text("Copied") : Text("Copy")
                        } icon: {
                            Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
                // Gated on the capture being non-empty and nothing else. It is
                // deliberately NOT gated on the search pass having landed:
                // `reportText` re-applies the filter to the snapshot itself, so
                // the export is correct whether or not `matches` is settled, and
                // a button that goes dead while you type is indistinguishable
                // from one that does not work.
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
        // Confirmed, because the ring is the only copy: the events it holds
        // were produced by something that has already happened, and a mistap
        // cannot be undone by reproducing it again. The warning belongs here
        // rather than under the button — a gating warning goes in the
        // confirmation, never in a persistent footnote.
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

    /// The counts the report text has always carried in its header, kept as
    /// data on screen rather than re-derived from the rendered rows.
    ///
    /// With a filter active it leads with the MATCHED count, because that is
    /// what both Copy and Share will export — the nav bar renders its buttons
    /// icon-only, so this line is where the scope of those actions is legible.
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

    /// The report's filter, in the list rather than in the navigation bar.
    ///
    /// It was a `.searchable` modifier, which on iOS takes the navigation bar
    /// over while it is active and replaces the trailing items with Cancel —
    /// hiding Copy and Share for exactly as long as a filter is being used.
    /// Since the whole point of the filter here is to narrow what gets
    /// exported, "filtering" and "exporting" have to be reachable at the same
    /// time, so the filter moved instead of the actions.
    ///
    /// Its second home, a pinned list section header, was no better: a header
    /// is rebuilt whenever its section is, so every keystroke that changed the
    /// match set took the keyboard away mid-word. Both failures are the same
    /// mistake — putting a control that must hold focus inside a container that
    /// owns when it is rebuilt. It now lives outside the list.
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
            // Always present, only faded: wrapping this in `if !query.isEmpty`
            // inserts a view into the stack on the FIRST keystroke, changing
            // the shape of the tree the text field is being diffed in at
            // precisely the moment it must keep focus. Constant structure,
            // varying appearance.
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
            // Ternary INSIDE Text() would bypass localization.
            (model.isFiltering ? Text("No matching events.") : Text("No events captured."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .listRowSeparator(.hidden)
        }
    }
}

/// One report line. Deliberately its own view: SwiftUI re-evaluates only the
/// rows it realizes, and nothing in here builds a string.
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
