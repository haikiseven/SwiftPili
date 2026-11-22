import Foundation

/// Ordered hand-off for packets that are ready before the pump that produced
/// them has returned.
///
/// **The barrier this removes.** `demux.pump` returns `[MediaPacket]`, so every
/// sample it completes stays captive until the whole budget-sized call finishes.
/// Device capture 2026-08-22:
///
///     [PathA][gap] pump video wall=7969ms produced=1.00s maxNetWait=226ms
///
/// Eight seconds for one second of content, with no individual network wait
/// above 226ms — the bytes were arriving the whole time and complete samples
/// were piling up inside an array nobody could see. `ingestV` and `ingestA` both
/// went silent for ~7.97s, the video queue drained 6s → 0, and `[gap] FREEZE`
/// fired with `vQ=0` while the media clock kept running. Audio was captive too:
/// it pumps in a sibling task, but the task group awaits both before returning.
///
/// So packets leave through here as they are assembled. The pump still returns
/// (its budget, its cancellation, its error handling are unchanged) — it just no
/// longer owns the delivery.
///
/// **Ordering.** Per track, FIFO. `publish` is called sequentially from that
/// track's pump task, so decode order is the arrival order; the lock only
/// serialises the two tracks against each other and against the drain, and they
/// land in separate session queues where cross-track order is irrelevant. A
/// track never has two channels open at once — see `PacketEmitter` in
/// `PathAFMP4Demuxer`: with a relay installed EVERY packet goes through it, and
/// `pump` returns an empty array. Two ordered channels into one queue is a
/// decode-order inversion waiting to happen.
///
/// **Bounded by construction.** The session runs one pump at a time and drains
/// on every publish edge, so the depth here is at most one pump's budget
/// (`pumpCallBudgetCapSeconds`, 1s) per track. Nothing is ever dropped — a
/// dropped packet is a decode gap, which is worse than the delay it would save —
/// so an unexpected depth is reported rather than trimmed.
final class DemuxPacketRelay: @unchecked Sendable {
    /// Roughly two pumps' worth of 30fps video plus its audio. Not a cap: the
    /// bound is structural (one pump in flight), and crossing this means that
    /// assumption broke, which is worth a line in the log rather than silent
    /// trimming.
    private static let unexpectedDepth = 400

    private let lock = NSLock()
    private var videoPackets: [MediaPacket] = []
    private var audioPackets: [MediaPacket] = []
    /// Set on the publish edge that has no drain pending, cleared by `drain`.
    /// Without it every publish would spawn its own hop to the session and a
    /// busy fragment would schedule hundreds of redundant drains.
    private var drainPending = false
    private var reportedUnexpectedDepth = false
    private var wake: (@Sendable () -> Void)?

    /// Highest packet count seen between drains, for the F4 instrumentation.
    private(set) var peakDepth = 0

    /// Installed by the session. Called from the pump's thread on the edge where
    /// a drain becomes necessary — it must not block, and it must not call back
    /// into `publish`.
    func setWake(_ wake: (@Sendable () -> Void)?) {
        lock.lock()
        self.wake = wake
        lock.unlock()
    }

    /// Demuxer side. Returns after buffering the packets; the wake (if any)
    /// fires OUTSIDE the lock so a synchronous consumer can drain re-entrantly
    /// without deadlocking.
    func publish(_ packets: [MediaPacket], track: MediaTrackKind) {
        guard !packets.isEmpty else { return }
        lock.lock()
        switch track {
        case .video: videoPackets.append(contentsOf: packets)
        case .audio: audioPackets.append(contentsOf: packets)
        }
        let depth = videoPackets.count + audioPackets.count
        peakDepth = max(peakDepth, depth)
        let overDepth = depth > Self.unexpectedDepth && !reportedUnexpectedDepth
        if overDepth { reportedUnexpectedDepth = true }
        let shouldWake = !drainPending
        if shouldWake { drainPending = true }
        let wake = self.wake
        lock.unlock()
        if overDepth {
            PlayerLog.diagnostic(
                "[PathA] ⚠️ relay depth \(depth) packets — more than one pump's " +
                "budget is outstanding; the single-pump bound no longer holds"
            )
        }
        if shouldWake { wake?() }
    }

    /// Session side. Everything buffered, oldest first within each track.
    ///
    /// Video before audio matches `pump`'s own return order (`video + audio`);
    /// the session dispatches per packet by track, so the only order that
    /// carries meaning is within a track, and that is preserved.
    func drain() -> [MediaPacket] {
        lock.lock()
        defer { lock.unlock() }
        drainPending = false
        guard !videoPackets.isEmpty || !audioPackets.isEmpty else { return [] }
        let out = videoPackets + audioPackets
        videoPackets.removeAll(keepingCapacity: true)
        audioPackets.removeAll(keepingCapacity: true)
        return out
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return videoPackets.isEmpty && audioPackets.isEmpty
    }

    /// Discard everything buffered — the session flushed its queues, so these
    /// packets belong to a timeline that no longer exists.
    ///
    /// ORDERING REQUIREMENT: call this AFTER the demux-side fence for the same
    /// event (`seek` / `open` bump `readerMutationGeneration`, which makes
    /// `commitStreamedProgress` refuse, so no further publish can follow).
    /// Resetting before the fence leaves a window in which an in-flight pump
    /// republishes into the new timeline.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        videoPackets.removeAll(keepingCapacity: true)
        audioPackets.removeAll(keepingCapacity: true)
        drainPending = false
        peakDepth = 0
        reportedUnexpectedDepth = false
    }
}
