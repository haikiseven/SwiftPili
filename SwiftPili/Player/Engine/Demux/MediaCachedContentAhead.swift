import Foundation

struct MediaCachedContentAhead: Equatable, Sendable {
    let video: MediaCachedTrackContentAhead
    let audio: MediaCachedTrackContentAhead

    init(video: MediaCachedTrackContentAhead, audio: MediaCachedTrackContentAhead) {
        self.video = video
        self.audio = audio
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

extension MediaDemuxing {
    func cachedContentAhead() async -> MediaCachedContentAhead { .empty }

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
        for fragment in fragments {
            guard fragment.offset >= contributingEnd else { continue }
            guard fragment.offset == contributingEnd,
                  fragment.size > 0,
                  let end = MediaByteRange.checkedEndExclusive(offset: fragment.offset, length: fragment.size),
                  end <= heldEnd,
                  fragment.duration.isFinite, fragment.duration >= 0
            else { break }
            total += fragment.duration
            contributingEnd = end
        }
        guard total.isFinite, total > 0, contributingEnd > start else { return nil }
        return Measurement(seconds: total, bytes: start..<contributingEnd)
    }
}
