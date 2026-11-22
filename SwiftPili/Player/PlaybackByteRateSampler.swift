import Foundation

/// The 1Hz byte-rate arithmetic behind `PlayerViewModel.sampleNetworkSpeed`,
/// split out so the two rates it produces can be told apart in a test.
///
/// Two counters, two questions — and they must not be swapped:
/// - `pipelineBytes` (`PlayerDynamicStats.bytesRead`) → `goodput`: payload of
///   packets ENTERING the pipeline, store-fed included. Delivery health, the
///   `dataFlowing` liveness window and the freeze watchdog read this, because
///   they ask whether content reaches the decoder fast enough for playback.
/// - `networkBytes` (`PlayerDynamicStats.networkBytesReceived`) → `network`:
///   bytes received from the wire, store hits excluded. Only the network-speed
///   display reads this. With multi-connection read-ahead the wire runs many
///   times faster than consumption, and a store-fed stretch reads near zero on
///   the wire while goodput stays at the playback rate — neither is a health
///   signal.
///
/// The sample is gated on the GOODPUT counter exactly as before the split: a
/// regression (backend swap, new stream) or a non-advancing clock drops the
/// whole sample. A regression of the wire counter alone drops only the
/// display figure (`network == nil` — the caller leaves the display as is).
struct PlaybackByteRateSampler {
    struct Reading: Equatable, Sendable {
        var networkBytes: Int64
        var pipelineBytes: Int64
    }

    struct Rates: Equatable, Sendable {
        /// Wire bytes/s for the display; nil = not measurable this sample.
        var network: Double?
        /// Pipeline goodput bytes/s for health/liveness.
        var goodput: Double
        /// The pipeline counter moved — the `dataFlowing` stamp.
        var pipelineAdvanced: Bool
    }

    private var last: (reading: Reading, at: TimeInterval)?

    mutating func reset() {
        last = nil
    }

    /// Records `reading` as the new baseline and returns the rates since the
    /// previous one, or nil when there is no previous one / the goodput
    /// counter regressed / time did not advance.
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
