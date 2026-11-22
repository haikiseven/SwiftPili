import Foundation

struct DanmakuWindowPlan: Equatable, Sendable {
    let resident: Set<Int>
    let fetch: Set<Int>
    let evict: Set<Int>
    let cancel: Set<Int>

    var isQuiet: Bool { fetch.isEmpty && evict.isEmpty && cancel.isEmpty }
}

enum DanmakuSegmentWindow {
    static let segmentSeconds: TimeInterval = 360

    static let prefetchLeadSeconds: TimeInterval = 60

    private static let indexCeiling = Int(Int32.max)

    static func index(for mediaTime: TimeInterval, pageSeconds: TimeInterval = segmentSeconds) -> Int {
        guard mediaTime > 0, mediaTime.isFinite else { return 1 }
        let ordinal = mediaTime / validPageSeconds(pageSeconds)
        guard ordinal < TimeInterval(indexCeiling) else { return indexCeiling }
        return Int(ordinal) + 1
    }

    static func lastIndex(duration: TimeInterval, pageSeconds: TimeInterval = segmentSeconds) -> Int? {
        guard duration > 0, duration.isFinite else { return nil }
        let ordinal = (duration / validPageSeconds(pageSeconds)).rounded(.up)
        guard ordinal < TimeInterval(indexCeiling) else { return indexCeiling }
        return max(1, Int(ordinal))
    }

    static func resident(
        mediaTime: TimeInterval, duration: TimeInterval, pageSeconds: TimeInterval = segmentSeconds
    ) -> Set<Int> {
        let current = index(for: mediaTime, pageSeconds: pageSeconds)
        let last = lastIndex(duration: duration, pageSeconds: pageSeconds)
        var window: Set<Int> = [current]
        if current > 1 { window.insert(current - 1) }

        let segmentEnd = TimeInterval(current) * validPageSeconds(pageSeconds)
        if mediaTime >= segmentEnd - prefetchLeadSeconds {
            let next = current + 1
            if last.map({ next <= $0 }) ?? true { window.insert(next) }
        }
        if let last { return window.filter { $0 >= 1 && $0 <= last } }
        return window.filter { $0 >= 1 }
    }

    static let minimumPageSeconds: TimeInterval = 60

    static func admissiblePageSeconds(_ seconds: TimeInterval) -> TimeInterval? {
        seconds >= minimumPageSeconds && seconds.isFinite ? seconds : nil
    }

    static func validPageSeconds(_ seconds: TimeInterval) -> TimeInterval {
        admissiblePageSeconds(seconds) ?? segmentSeconds
    }

    static func plan(
        mediaTime: TimeInterval,
        duration: TimeInterval,
        loaded: Set<Int>,
        inFlight: Set<Int>,
        blocked: Set<Int> = [],
        pageSeconds: TimeInterval = segmentSeconds
    ) -> DanmakuWindowPlan {
        let resident = resident(mediaTime: mediaTime, duration: duration, pageSeconds: pageSeconds)
        return DanmakuWindowPlan(
            resident: resident,
            fetch: resident.subtracting(loaded).subtracting(inFlight).subtracting(blocked),
            evict: loaded.subtracting(resident),
            cancel: inFlight.subtracting(resident)
        )
    }
}
