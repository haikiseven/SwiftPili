import Foundation

/// Payload-free ownership metadata. Producers acquire this lock only after
/// their own lock; this object never invokes a producer, parser or native API.
final class MediaDisplayAvailability: MediaDisplayEvidenceQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var tracks: [UUID: MediaTrackKind] = [:]
    private var entries: [UUID: Entry] = [:]
    private var layouts: [UUID: [Int64: Layout]] = [:]
    private var directEvidence: [UUID: DirectDisplayEvidence] = [:]

    var hasTracks: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !tracks.isEmpty
    }

    private struct Entry {
        let track: UUID
        var interval: MediaDisplayInterval?
        var bytes: Range<Int64>?
        let audio: AudioDisplayRepresentation?
        /// Typed, pure, irreversible byte witnesses only. Their locks never
        /// call back into this book or any media producer.
        let residencies: [MediaByteRangeStore.ResidentValidity]

        /// Only lease membership can revoke these intervals. Byte-backed or
        /// mixed facts stay in the live witness-qualified query path.
        var indexedInterval: MediaDisplayInterval? {
            bytes == nil && residencies.isEmpty ? interval : nil
        }
    }

    /// Constructed by the fragment producer before publication. Full held
    /// fragments reuse their exact normalized intervals on every clock read.
    private struct Layout {
        let samples: [MediaDisplaySample]
        let requiredBytes: Range<Int64>?
        let intervals: [MediaDisplayInterval]
        let metadataResidency: MediaByteRangeStore.ResidentValidity?

        init(_ samples: [MediaDisplaySample], metadataResidency: MediaByteRangeStore.ResidentValidity?) {
            self.metadataResidency = metadataResidency
            self.samples = samples.sorted { $0.interval.lower < $1.interval.lower }
            intervals = MediaDisplayAvailability.mergedIntervals(self.samples.map(\.interval))
            if let first = samples.first {
                let lower = samples.reduce(first.bytes.lowerBound) { min($0, $1.bytes.lowerBound) }
                let upper = samples.reduce(first.bytes.upperBound) { max($0, $1.bytes.upperBound) }
                requiredBytes = lower..<upper
            } else {
                requiredBytes = nil
            }
        }

        func coveredIntervals(in spans: [Range<Int64>]) -> [MediaDisplayInterval] {
            if let requiredBytes, MediaDisplayAvailability.covers(requiredBytes, spans: spans) {
                return intervals
            }
            let covered = samples.lazy.filter {
                MediaDisplayAvailability.covers($0.bytes, spans: spans)
            }.map(\.interval)
            return MediaDisplayAvailability.mergedIntervals(covered)
        }

        func hasCoveredSample(startingAt time: MediaDisplayTime, spans: [Range<Int64>]) -> Bool {
            guard !spans.isEmpty else { return false }
            let start = MediaDisplayAvailability.firstIndex(count: samples.count) { samples[$0].interval.lower < time }
            for sample in samples[start...] {
                guard sample.interval.lower == time else { break }
                if MediaDisplayAvailability.covers(sample.bytes, spans: spans) { return true }
            }
            return false
        }
    }

    private struct HeldTrack {
        var intervals: [MediaDisplayInterval] = []
        var bytes: [Range<Int64>] = []

        mutating func append(_ entry: Entry) {
            if let interval = entry.interval { intervals.append(interval) }
            if let range = entry.bytes { bytes.append(range) }
        }
    }

    func makeTrack(_ kind: MediaTrackKind) -> MediaDisplayTrack {
        let identity = UUID()
        lock.lock()
        tracks[identity] = kind
        lock.unlock()
        return MediaDisplayTrack(book: self, identity: identity)
    }

    fileprivate func own(track: UUID, interval: MediaDisplayInterval?, bytes: Range<Int64>?,
                         residency: MediaByteRangeStore.ResidentValidity? = nil,
                         metadataResidency: MediaByteRangeStore.ResidentValidity? = nil,
                         audio: AudioDisplayRepresentation? = nil) -> MediaDisplayLease? {
        let identity = UUID()
        lock.lock()
        guard tracks[track] != nil else { lock.unlock(); return nil }
        let entry = Entry(
            track: track, interval: interval, bytes: bytes, audio: audio,
            residencies: [residency, metadataResidency].compactMap { $0 }
        )
        entries[identity] = entry
        if let interval = entry.indexedInterval {
            directEvidence[track, default: DirectDisplayEvidence()].insert(interval, audio: audio, id: identity)
        }
        lock.unlock()
        return MediaDisplayLease(book: self, track: track, identity: identity, interval: interval, audio: audio)
    }

    fileprivate func retire(_ identity: UUID) {
        lock.lock()
        if let entry = entries.removeValue(forKey: identity), let interval = entry.indexedInterval {
            directEvidence[entry.track]?.remove(interval, audio: entry.audio, id: identity)
        }
        lock.unlock()
    }

    fileprivate func isCurrent(_ identity: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[identity], tracks[entry.track] != nil else { return false }
        return entry.residencies.allSatisfy(\.isValid)
    }

    fileprivate func retireTrack(_ track: UUID) {
        lock.lock()
        tracks.removeValue(forKey: track)
        entries = entries.filter { $0.value.track != track }
        layouts.removeValue(forKey: track)
        directEvidence.removeValue(forKey: track)
        lock.unlock()
    }

    fileprivate func setLayout(
        _ samples: [MediaDisplaySample], track: UUID, fragment: Int64,
        metadataResidency: MediaByteRangeStore.ResidentValidity?
    ) {
        let layout = Layout(samples, metadataResidency: metadataResidency)
        lock.lock()
        // Upsert, not replace: the active fragment and cache-only inspected
        // future fragments describe disjoint byte ranges and must coexist.
        if tracks[track] != nil {
            var fragments = layouts[track] ?? [:]
            fragments[fragment] = layout
            layouts[track] = fragments
        }
        lock.unlock()
    }

    fileprivate func removeLayouts(below fragment: Int64, track: UUID) {
        lock.lock()
        if let fragments = layouts[track] {
            let kept = fragments.filter { $0.key >= fragment }
            layouts[track] = kept.isEmpty ? nil : kept
        }
        lock.unlock()
    }

    fileprivate func clearLayouts(track: UUID) {
        lock.lock()
        layouts[track] = nil
        lock.unlock()
    }

    /// Read both connected components from one current snapshot. This retains
    /// value metadata only, never the owners' leases or media payload. Residency
    /// is checked on every read; no historical endpoint survives revocation.
    func qualifiedEndpoints(
        at seconds: Double, audioPosition: MediaAudioDisplayPosition?
    ) -> MediaDisplayEndpoints {
        guard let scalarPosition = MediaDisplayTime(seconds: seconds) else {
            return MediaDisplayEndpoints(video: nil, audio: nil)
        }
        lock.lock()
        let kinds = tracks
        let position = audioPosition.flatMap { position in
            kinds[position.track] == .audio ? position.time : nil
        } ?? scalarPosition
        // Qualify inside the same book transaction as candidate selection.
        // Otherwise a copy can add destination B/revoke source A after this
        // snapshot, and a later residency read rejects A without seeing B.
        // Lock order is producer -> book -> typed residency witness; the
        // witness protects booleans only and has no reverse book/callback edge.
        let facts = entries.values.filter { entry in
            entry.indexedInterval == nil && entry.residencies.allSatisfy(\.isValid)
        }
        // Snapshot value geometry and AU boundaries, never counts or leases.
        // Normalize coverage and project its endpoint outside the book lock.
        let direct = directEvidence.mapValues(\.snapshot)
        let fragments = layouts.mapValues { fragments in
            fragments.filter { $0.value.metadataResidency?.isValid != false }
        }
        lock.unlock()

        var held: [UUID: HeldTrack] = [:]
        for entry in facts where kinds[entry.track] != nil {
            held[entry.track, default: HeldTrack()].append(entry)
        }
        var video: [MediaDisplayInterval] = []
        var audio: Double?
        var audioJoin: MediaAudioDisplayJoin?
        for (track, kind) in kinds {
            let snapshot = direct[track] ?? DirectDisplayEvidence.Snapshot()
            let bytes = held[track] ?? HeldTrack()
            let trackLayouts = fragments[track] ?? [:]
            let spans = Self.mergedSpans(bytes.bytes)
            let source = Self.sourceIntervals(direct: snapshot.source, held: bytes, spans: spans, layouts: trackLayouts)
            switch kind {
            case .video: video = Self.unionSortedIntervals(video, source)
            case .audio:
                let result = AudioDisplayProjection.endpoint(
                    at: position, source: source, direct: snapshot
                ) { boundary in
                    Self.hasStart(boundary, in: snapshot.source) || bytes.intervals.contains { $0.lower == boundary }
                        || trackLayouts.values.contains { $0.hasCoveredSample(startingAt: boundary, spans: spans) }
                }
                if let end = result.end, audio.map({ end > $0 }) ?? true {
                    audio = end
                    audioJoin = result.join
                }
            }
        }
        return MediaDisplayEndpoints(
            video: MediaDisplayInterval.connectedEnd(at: position, in: video)?.seconds,
            audio: audio, audioJoin: audioJoin
        )
    }

    private static func sourceIntervals(
        direct: [MediaDisplayInterval], held: HeldTrack, spans: [Range<Int64>], layouts: [Int64: Layout]
    ) -> [MediaDisplayInterval] {
        var intervals = mergedIntervals(direct)
        if !held.intervals.isEmpty {
            let fallback = mergedIntervals(held.intervals.sorted(by: OrderedDisplayIntervals.precedes))
            intervals = unionSortedIntervals(intervals, fallback)
        }
        if !spans.isEmpty {
            for layout in layouts.values {
                intervals = unionSortedIntervals(intervals, layout.coveredIntervals(in: spans))
            }
        }
        return intervals
    }

    private static func hasStart(_ time: MediaDisplayTime, in intervals: [MediaDisplayInterval]) -> Bool {
        let start = firstIndex(count: intervals.count) { intervals[$0].lower < time }
        return start < intervals.count && intervals[start].lower == time
    }

    /// Both inputs are already ordered and compacted. Empty contributions reuse
    /// the other value array; nonempty ones union without re-sorting coverage.
    private static func unionSortedIntervals(
        _ first: [MediaDisplayInterval], _ second: [MediaDisplayInterval]
    ) -> [MediaDisplayInterval] {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        var merged: [MediaDisplayInterval] = []
        var left = 0
        var right = 0
        while left < first.count || right < second.count {
            let interval: MediaDisplayInterval
            if right == second.count || (left < first.count &&
                OrderedDisplayIntervals.precedes(first[left], second[right])) {
                interval = first[left]
                left += 1
            } else {
                interval = second[right]
                right += 1
            }
            appendMerged(interval, to: &merged)
        }
        return merged
    }

    /// Sort and union once per track. Coverage then needs only the predecessor
    /// range instead of rescanning every held byte span for every sample.
    private static func mergedSpans(_ spans: [Range<Int64>]) -> [Range<Int64>] {
        var merged: [Range<Int64>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) where !span.isEmpty {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func covers(_ range: Range<Int64>, spans: [Range<Int64>]) -> Bool {
        let end = firstIndex(count: spans.count) { spans[$0].lowerBound <= range.lowerBound }
        return end > 0 && spans[end - 1].upperBound >= range.upperBound
    }

    private static func firstIndex(count: Int, before: (Int) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if before(middle) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    /// Input is already time-ordered, either by immutable layout preparation or
    /// by filtering that layout. Preserve real gaps and exact rational adjacency.
    private static func mergedIntervals<S: Sequence>(_ intervals: S) -> [MediaDisplayInterval]
        where S.Element == MediaDisplayInterval {
        var merged: [MediaDisplayInterval] = []
        for interval in intervals {
            appendMerged(interval, to: &merged)
        }
        return merged
    }

    private static func appendMerged(_ interval: MediaDisplayInterval, to merged: inout [MediaDisplayInterval]) {
        if let last = merged.last, interval.lower <= last.upper {
            if let joined = MediaDisplayInterval(last.lower, max(last.upper, interval.upper)) {
                merged[merged.count - 1] = joined
            }
        } else {
            merged.append(interval)
        }
    }
}

struct MediaDisplaySample: Sendable {
    let fragment: Int64
    let ordinal: Int
    let bytes: Range<Int64>
    let interval: MediaDisplayInterval
}

final class MediaDisplayTrack: @unchecked Sendable {
    let book: MediaDisplayAvailability
    fileprivate let identity: UUID

    fileprivate init(book: MediaDisplayAvailability, identity: UUID) {
        self.book = book
        self.identity = identity
    }

    func retire() { book.retireTrack(identity) }
    func own(_ interval: MediaDisplayInterval) -> MediaDisplayLease? {
        book.own(track: identity, interval: interval, bytes: nil)
    }
    func own(
        bytes: Range<Int64>, residency: MediaByteRangeStore.ResidentValidity? = nil,
        metadataResidency: MediaByteRangeStore.ResidentValidity? = nil
    ) -> MediaDisplayLease? {
        book.own(
            track: identity, interval: nil, bytes: bytes,
            residency: residency, metadataResidency: metadataResidency
        )
    }
    func install(
        _ samples: [MediaDisplaySample], fragment: Int64,
        metadataResidency: MediaByteRangeStore.ResidentValidity? = nil
    ) {
        book.setLayout(samples, track: identity, fragment: fragment, metadataResidency: metadataResidency)
    }
    func removeLayouts(below fragment: Int64) {
        book.removeLayouts(below: fragment, track: identity)
    }
    func clearLayouts() {
        book.clearLayouts(track: identity)
    }
}

/// Shared by copies of the corresponding packet/frame only. Transfer through
/// relay, queues, residual and in-flight locals needs no independent roster.
final class MediaDisplayLease: @unchecked Sendable {
    fileprivate let book: MediaDisplayAvailability
    fileprivate let track: UUID
    fileprivate let identity: UUID
    let interval: MediaDisplayInterval?
    private let audio: AudioDisplayRepresentation?

    fileprivate init(
        book: MediaDisplayAvailability, track: UUID, identity: UUID, interval: MediaDisplayInterval?,
        audio: AudioDisplayRepresentation?
    ) {
        self.book = book
        self.track = track
        self.identity = identity
        self.interval = interval
        self.audio = audio
    }
    deinit { book.retire(identity) }

    var isCurrent: Bool { book.isCurrent(identity) }
    var trackIdentity: UUID { track }

    func producing(_ interval: MediaDisplayInterval?) -> MediaDisplayLease? {
        guard let interval else { return nil }
        let representation: AudioDisplayRepresentation?
        if case .accepted(let handoff) = audio {
            // Copies and a front trim conserve the AU tail. A suffix trim
            // cannot claim its continuation and stays on the PCM time axis.
            representation = .accepted(interval.upper == self.interval?.upper ? handoff : nil)
        } else if case .decoded(let tail) = audio {
            representation = .decoded(interval == self.interval ? tail : nil)
        } else {
            representation = nil
        }
        return book.own(track: track, interval: interval, bytes: nil, audio: representation)
    }

    func producingDecodedAudio(
        _ interval: MediaDisplayInterval?, tail: AudioDisplayDecodedTail? = nil
    ) -> MediaDisplayLease? {
        guard let interval else { return nil }
        return book.own(track: track, interval: interval, bytes: nil, audio: .decoded(tail))
    }

    func producingAcceptedAudio(
        _ interval: MediaDisplayInterval?, tail: AudioDisplayAcceptedTail
    ) -> MediaDisplayLease? {
        guard let interval else { return nil }
        let handoff: AudioDisplayHandoff?
        if case .decoded(let decodedTail?) = audio {
            handoff = AudioDisplayHandoff(sourceEnd: decodedTail.sourceEnd, acceptedTail: tail)
        } else {
            handoff = nil
        }
        return book.own(track: track, interval: interval, bytes: nil, audio: .accepted(handoff))
    }
}

/// The owner of one real read/assembly operation; contains no Data. The caller
/// releases its reads only after installing sample and remaining-partial owners.
final class MediaDisplayByteOwner: @unchecked Sendable {
    let track: MediaDisplayTrack
    private let lock = NSLock()
    private var leases: [MediaDisplayLease] = []

    init(track: MediaDisplayTrack) { self.track = track }
    func hold(_ bytes: Range<Int64>) {
        guard !bytes.isEmpty, let lease = track.own(bytes: bytes) else { return }
        lock.lock()
        leases.append(lease)
        lock.unlock()
    }
    func release() {
        lock.lock()
        let retired = leases
        leases = []
        lock.unlock()
        withExtendedLifetime(retired) {}
    }
}
