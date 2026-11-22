import Foundation

/// Source-time coverage and accepted PCM are separate coordinate systems.
/// Both indexes and the handoff ownership change under the same book lock.
struct DirectDisplayEvidence {
    struct Snapshot {
        var source: [MediaDisplayInterval] = []
        var acceptedPCM: [MediaDisplayInterval] = []
        var pendingPCM: [MediaDisplayInterval] = []
        var handoffs: [MediaDisplayTime: [UUID: AudioDisplayHandoff]] = [:]

        func handoff(at end: MediaDisplayTime) -> AudioDisplayHandoff? {
            guard let peers = handoffs[end], let first = peers.values.first,
                  peers.values.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
    }

    private var source = OrderedDisplayIntervals()
    private var acceptedPCM = OrderedDisplayIntervals()
    private var pendingPCM = OrderedDisplayIntervals()
    private var handoffs: [MediaDisplayTime: [UUID: AudioDisplayHandoff]] = [:]

    var snapshot: Snapshot {
        Snapshot(source: source.intervals, acceptedPCM: acceptedPCM.intervals,
                 pendingPCM: pendingPCM.intervals, handoffs: handoffs)
    }

    mutating func insert(_ interval: MediaDisplayInterval, audio: AudioDisplayRepresentation?, id: UUID) {
        if case .accepted(let handoff) = audio {
            acceptedPCM.insert(interval)
            if let handoff { handoffs[interval.upper, default: [:]][id] = handoff }
        } else if case .decoded(let tail) = audio, tail?.matchesNativeSourceEnd(interval.upper) != true {
            pendingPCM.insert(interval)
        } else {
            source.insert(interval)
        }
    }

    mutating func remove(_ interval: MediaDisplayInterval, audio: AudioDisplayRepresentation?, id: UUID) {
        if case .accepted(let handoff) = audio {
            acceptedPCM.remove(interval)
            if handoff != nil {
                handoffs[interval.upper]?[id] = nil
                if handoffs[interval.upper]?.isEmpty == true { handoffs[interval.upper] = nil }
            }
        } else if case .decoded(let tail) = audio, tail?.matchesNativeSourceEnd(interval.upper) != true {
            pendingPCM.remove(interval)
        } else {
            source.remove(interval)
        }
    }
}

struct AudioDisplayHandoff: Equatable, Sendable {
    let sourceEnd: MediaDisplayTime
    let acceptedTail: AudioDisplayAcceptedTail
}

enum AudioDisplayDecodedTail: Sendable {
    case native(MediaDisplayTime)
    case resampled(MediaDisplayTime)

    var sourceEnd: MediaDisplayTime {
        switch self {
        case .native(let end), .resampled(let end): end
        }
    }

    func matchesNativeSourceEnd(_ end: MediaDisplayTime) -> Bool {
        guard case .native(let sourceEnd) = self else { return false }
        return sourceEnd == end
    }
}

enum AudioDisplayRepresentation: Sendable {
    case decoded(AudioDisplayDecodedTail?)
    case accepted(AudioDisplayHandoff?)
}

/// Value-only index; the enclosing book lock protects every mutation. Equal
/// intervals retain separate lease counts, so one handoff cannot retire another.
struct OrderedDisplayIntervals {
    private var counts: [MediaDisplayInterval: Int] = [:]
    private(set) var intervals: [MediaDisplayInterval] = []

    mutating func insert(_ interval: MediaDisplayInterval) {
        if let count = counts[interval] {
            counts[interval] = count + 1
            return
        }
        counts[interval] = 1
        let index = insertionIndex(for: interval)
        intervals.insert(interval, at: index)
    }

    mutating func remove(_ interval: MediaDisplayInterval) {
        guard let count = counts[interval] else { return }
        if count > 1 {
            counts[interval] = count - 1
            return
        }
        counts.removeValue(forKey: interval)
        let index = insertionIndex(for: interval)
        intervals.remove(at: index)
    }

    static func precedes(_ first: MediaDisplayInterval, _ second: MediaDisplayInterval) -> Bool {
        first.lower == second.lower ? first.upper < second.upper : first.lower < second.lower
    }

    private func insertionIndex(for interval: MediaDisplayInterval) -> Int {
        var lower = 0
        var upper = intervals.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Self.precedes(intervals[middle], interval) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
