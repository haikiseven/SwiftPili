import Foundation

struct MediaDisplayTime: Hashable, Comparable, Sendable {
    let value: Int64
    let scale: Int64

    init?(_ value: Int64, scale: Int64) {
        guard scale > 0 else { return nil }
        let divisor = Self.gcd(value.magnitude, UInt64(scale))
        self.value = value / Int64(divisor)
        self.scale = scale / Int64(divisor)
    }

    init?(seconds: Double) {
        guard seconds.isFinite else { return nil }
        if seconds == 0 { self.init(0, scale: 1); return }
        let bits = seconds.bitPattern
        let exponent = Int((bits >> 52) & 0x7ff) - 1023 - 52
        var magnitude = (bits & 0x000f_ffff_ffff_ffff) | 0x0010_0000_0000_0000
        var shift = exponent
        while magnitude & 1 == 0 { magnitude >>= 1; shift += 1 }
        guard shift > -63, shift < 63 else { return nil }
        let result: (partialValue: UInt64, overflow: Bool) = shift > 0
            ? magnitude.multipliedReportingOverflow(by: UInt64(1) << shift) : (magnitude, false)
        guard !result.overflow, result.partialValue <= UInt64(Int64.max) else { return nil }
        self.init(bits >> 63 == 0 ? Int64(result.partialValue) : -Int64(result.partialValue),
                  scale: shift < 0 ? Int64(1) << -shift : 1)
    }

    var seconds: Double { Double(value) / Double(scale) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let left = lhs.value.multipliedFullWidth(by: rhs.scale)
        let right = rhs.value.multipliedFullWidth(by: lhs.scale)
        return left.high == right.high ? left.low < right.low : left.high < right.high
    }

    func adding(_ other: Self) -> Self? {
        let divisor = Int64(Self.gcd(UInt64(scale), UInt64(other.scale)))
        let left = value.multipliedReportingOverflow(by: other.scale / divisor)
        let right = other.value.multipliedReportingOverflow(by: scale / divisor)
        let denominator = scale.multipliedReportingOverflow(by: other.scale / divisor)
        guard !left.overflow, !right.overflow, !denominator.overflow else { return nil }
        let sum = left.partialValue.addingReportingOverflow(right.partialValue)
        guard !sum.overflow else { return nil }
        return Self(sum.partialValue, scale: denominator.partialValue)
    }

    func adding(frames: Int, sampleRate: Double) -> Self? {
        guard let count = Int64(exactly: frames), let rate = Int64(exactly: sampleRate),
              let duration = Self(count, scale: rate) else { return nil }
        return adding(duration)
    }

    private static func gcd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var first = lhs
        var second = rhs
        while second != 0 { (first, second) = (second, first % second) }
        return first
    }
}

struct MediaDisplayInterval: Hashable, Sendable {
    let lower: MediaDisplayTime
    let upper: MediaDisplayTime

    init?(_ lower: MediaDisplayTime?, _ upper: MediaDisplayTime?) {
        guard let lower, let upper, lower < upper else { return nil }
        self.lower = lower
        self.upper = upper
    }

    static func connectedEnd(at position: MediaDisplayTime, in intervals: [Self]) -> MediaDisplayTime? {
        guard let first = intervals.firstIndex(where: { $0.upper > position }),
              intervals[first].lower <= position else { return nil }
        var end = intervals[first].upper
        for interval in intervals.dropFirst(first + 1) {
            guard interval.lower <= end else { break }
            end = max(end, interval.upper)
        }
        return end
    }

    static func pcm(start: MediaDisplayTime?, frames: Int, rate: Double) -> Self? {
        Self(start, start?.adding(frames: frames, sampleRate: rate))
    }
}
