import Foundation

struct PlaybackByteRateSampler {
    struct Reading: Equatable, Sendable {
        var networkBytes: Int64
        var pipelineBytes: Int64
    }

    struct Rates: Equatable, Sendable {
        var network: Double?
        var goodput: Double
        var pipelineAdvanced: Bool
    }

    private var last: (reading: Reading, at: TimeInterval)?

    mutating func reset() {
        last = nil
    }

    mutating func sample(_ reading: Reading, at now: TimeInterval) -> Rates? {
        defer { last = (reading, now) }
        guard let last,
              reading.pipelineBytes >= last.reading.pipelineBytes,
              now > last.at else { return nil }
        let elapsed = now - last.at
        let goodput = Double(reading.pipelineBytes - last.reading.pipelineBytes) / elapsed
        let network: Double? = reading.networkBytes >= last.reading.networkBytes
            ? Double(reading.networkBytes - last.reading.networkBytes) / elapsed
            : nil
        return Rates(
            network: network,
            goodput: goodput,
            pipelineAdvanced: reading.pipelineBytes > last.reading.pipelineBytes
        )
    }
}
