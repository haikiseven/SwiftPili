import Foundation

enum PathAHLSTimeline {
    static func normalize(
        _ packets: [MediaPacket],
        origin: inout TimeInterval?
    ) -> [MediaPacket] {
        guard !packets.isEmpty else { return [] }
        if origin == nil {
            origin = packets.compactMap { packet -> TimeInterval? in
                let value = packet.dts ?? packet.pts
                return value.isFinite ? value : nil
            }.min()
        }
        guard let origin else { return packets }
        return packets.map { packet in
            var normalized = packet
            let pts = packet.pts - origin
            normalized.pts = abs(pts) < 1e-9 ? 0 : pts
            if let dts = packet.dts {
                let value = dts - origin
                normalized.dts = abs(value) < 1e-9 ? 0 : value
            }
            return normalized
        }
    }
}
