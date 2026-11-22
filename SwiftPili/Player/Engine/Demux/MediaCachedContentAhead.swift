import Foundation

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

struct MediaCachedTrackContentAhead: Equatable, Sendable {
    private let measuredSeconds: TimeInterval
    private let validity: MediaByteRangeStore.ResidentValidity?

    static let empty = MediaCachedTrackContentAhead(seconds: 0, validity: nil)

    init(seconds: TimeInterval, validity: MediaByteRangeStore.ResidentValidity?) {
        measuredSeconds = seconds.isFinite && validity != nil ? max(0, seconds) : 0
        self.validity = measuredSeconds > 0 ? validity : nil
    }

    var seconds: TimeInterval {
        validity?.isValid == true ? measuredSeconds : 0
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.measuredSeconds == rhs.measuredSeconds && lhs.validity === rhs.validity
    }
}

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
    func cachedContentAhead() async -> MediaCachedContentAhead { .empty }

    func retireResidentDisplay(video: Bool, audio: Bool) async {}

    var measuresCachedContentAhead: Bool { false }
}

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
