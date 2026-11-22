import Foundation

/// Bytes this playback actually RECEIVED from the network — the figure the
/// player's network-speed display is denominated in.
///
/// Not the pipeline goodput: `MediaEngineSession.bytesRead` counts the payload
/// of packets entering the decode pipeline (≈ playback consumption), which is
/// what delivery health compares against demand. This counter answers a
/// different question — what crossed the wire — and the two diverge exactly
/// when multi-connection read-ahead fills far ahead of the playhead, or when a
/// stretch plays from bytes the store already holds.
///
/// Producers (each counts body bytes as they arrive, valid or not):
/// - `MediaNetworkDataTask` and the primary chunk delegate — response bodies
///   before validation/slicing; store-served and primed-head reads add nothing.
/// - `MultiConnectionURLBridge` — every helper body chunk, including bytes a
///   later failure or seek discards.
/// - Live playlist/map/segment loads use `MediaNetworkDataTask` too.
///
/// Ownership is per stream: `MediaEngineSession` installs a FRESH instance on
/// every open and every stop, and hands it down through `MediaOpenRequest`.
/// A late callback from a retired source therefore lands in the retired
/// instance and can never inflate the next stream. Seeks keep the instance.
final class MediaNetworkByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0

    init() {}

    var total: Int64 { lock.withLock { bytes } }

    /// Saturating: a counter that wrapped would read as a regression, which
    /// the sampler drops — never as a negative rate.
    func add(_ count: Int) {
        guard count > 0, let amount = Int64(exactly: count) else { return }
        lock.withLock {
            let (sum, overflow) = bytes.addingReportingOverflow(amount)
            bytes = overflow ? Int64.max : sum
        }
    }
}
