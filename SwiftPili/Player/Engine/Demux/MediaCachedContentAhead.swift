import Foundation

/// Content seconds each track can still demux WITHOUT the network: whole
/// fragments held contiguously in `MediaByteRangeStore` from the reader's
/// committed read position onward (media cache P1, R4).
///
/// It is an ADDEND to the delivery runway, never a runway of its own: it
/// counts only what lies past the bytes the demuxer has already turned into
/// packets, so it cannot overlap what the session's queues hold. Zero is the
/// honest answer for every input that has no store behind it — file sources
/// (the local-file availability rule covers them), live HLS, the kill switch,
/// and demuxers that read no bytes at all — because none of them holds
/// anything beyond what it already demuxed.
struct MediaCachedContentAhead: Equatable, Sendable {
    let video: MediaCachedTrackContentAhead
    let audio: MediaCachedTrackContentAhead
    let videoDisplay: MediaResidentDisplayFragment?
    let audioDisplay: MediaResidentDisplayFragment?

    init(video: MediaCachedTrackContentAhead, audio: MediaCachedTrackContentAhead,
         videoDisplay: MediaResidentDisplayFragment? = nil, audioDisplay: MediaResidentDisplayFragment? = nil) {
        self.video = video
        self.audio = audio
        self.videoDisplay = videoDisplay
        self.audioDisplay = audioDisplay
    }

    static let empty = MediaCachedContentAhead(video: .empty, audio: .empty)
}

/// An immutable measurement with live, synchronous residency validation.
/// Equality compares the measurement and authority identity, never a changing
/// validity bit; this value has no publication/deduplication consumers today.
struct MediaCachedTrackContentAhead: Equatable, Sendable {
    private let measuredSeconds: TimeInterval
    private let validity: MediaByteRangeStore.ResidentValidity?

    static let empty = MediaCachedTrackContentAhead(seconds: 0, validity: nil)

    init(seconds: TimeInterval, validity: MediaByteRangeStore.ResidentValidity?) {
        measuredSeconds = seconds.isFinite && validity != nil ? max(0, seconds) : 0
        self.validity = measuredSeconds > 0 ? validity : nil
    }

    /// Valid at this synchronous observation's linearization point; removal
    /// can follow immediately. No bytes are pinned and no store hop is needed.
    var seconds: TimeInterval {
        validity?.isValid == true ? measuredSeconds : 0
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.measuredSeconds == rhs.measuredSeconds && lhs.validity === rhs.validity
    }
}

/// Reader usability is separate from byte residency. Copies share irreversible
/// retirement; a real reposition installs a fresh token, ordinary pumping does not.
final class MediaResidentDisplayUsability: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func revoke() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

/// One parsed, continuous fragment; no payload ownership or seekability claim.
struct MediaResidentDisplayFragment: Equatable, Sendable {
    let lower: TimeInterval
    let upper: TimeInterval
    let residency: MediaByteRangeStore.ResidentValidity
    let usability: MediaResidentDisplayUsability

    func supplement(_ endpoint: TimeInterval, at time: TimeInterval) -> TimeInterval {
        guard residency.isValid, usability.isValid, lower <= endpoint, upper > time else { return endpoint }
        return max(endpoint, upper)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lower == rhs.lower && lhs.upper == rhs.upper
            && lhs.residency === rhs.residency && lhs.usability === rhs.usability
    }
}

extension MediaDemuxing {
    /// Nothing held beyond what was demuxed. Only the progressive fMP4 reader
    /// (and the adaptive wrapper forwarding to it) reads through the store.
    func cachedContentAhead() async -> MediaCachedContentAhead { .empty }

    func retireResidentDisplay(video: Bool, audio: Bool) async {}

    var measuresCachedContentAhead: Bool { false }
}

/// The whole-fragment arithmetic behind `cachedContentAhead`, kept free of
/// reader and actor state. Its byte range includes required cursor reachability.
enum PathACachedFragmentRunway {
    struct Fragment: Equatable, Sendable {
        let offset: Int64
        let size: Int64
        let duration: TimeInterval
    }

    struct Measurement {
        let seconds: TimeInterval
        let bytes: Range<Int64>
    }

    /// Seconds of the fragments that lie ENTIRELY inside
    /// `[start, start + heldBytes)`, walking forward from `start` and stopping
    /// at the first fragment not fully held.
    ///
    /// `start` is the first byte the reader has not consumed. A fragment that
    /// begins before it — the one the reader is streaming — contributes no
    /// seconds: its already-emitted samples are in the queues and its
    /// remaining time is not known in whole fragments. Its unconsumed bytes
    /// must still be held for anything after it to count, because nothing
    /// after it is reachable without them. `fragments` is ascending by offset.
    static func measurement<Fragments: Sequence>(
        from start: Int64,
        heldBytes: Int64,
        fragments: Fragments
    ) -> Measurement? where Fragments.Element == Fragment {
        guard start >= 0, heldBytes > 0,
              let heldEnd = MediaByteRange.checkedEndExclusive(offset: start, length: heldBytes)
        else { return nil }
        var total: TimeInterval = 0
        var contributingEnd = start
        for fragment in fragments where fragment.offset >= start {
            guard fragment.size > 0,
                  let end = MediaByteRange.checkedEndExclusive(offset: fragment.offset, length: fragment.size),
                  end <= heldEnd,
                  fragment.duration.isFinite, fragment.duration >= 0
            else { break }
            total += fragment.duration
            if fragment.duration > 0 { contributingEnd = end }
        }
        guard total.isFinite, total > 0, contributingEnd > start else { return nil }
        return Measurement(seconds: total, bytes: start..<contributingEnd)
    }
}
