import Foundation

final class DemuxPacketRelay: @unchecked Sendable {
    private static let unexpectedDepth = 400

    private let lock = NSLock()
    private var videoPackets: [MediaPacket] = []
    private var audioPackets: [MediaPacket] = []
    private var drainPending = false
    private var reportedUnexpectedDepth = false
    private var wake: (@Sendable () -> Void)?

    private(set) var peakDepth = 0

    func setWake(_ wake: (@Sendable () -> Void)?) {
        lock.lock()
        self.wake = wake
        lock.unlock()
    }

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
