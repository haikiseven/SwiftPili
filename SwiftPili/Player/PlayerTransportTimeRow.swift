import SwiftUI

private enum PlayerTransportReadout {
    case finite(elapsed: String, duration: String, network: String?)
    case live(network: String?)
}

private struct PlayerTransportReadoutKey: Equatable {
    let player: ObjectIdentifier
    let backend: ObjectIdentifier
    let requestedOwner: String
    let currentOwner: String
    let ownerLeaseGeneration: UInt64
    let loadGeneration: Int
    let playerGeneration: Int
    let mode: PlayerMode
    let currentURL: URL?
    let showsNetworkSpeed: Bool
    let localeIdentifier: String
    let isSeeking: Bool
}

/// One real composed readout; this is presentation data, never media authority.
@MainActor
private final class PlayerTransportReadoutMemo {
    private struct Entry {
        let key: PlayerTransportReadoutKey
        let readout: PlayerTransportReadout
    }
    private var entry: Entry?

    func readout(
        for key: PlayerTransportReadoutKey,
        refresh: Bool,
        capture: () -> PlayerTransportReadout
    ) -> PlayerTransportReadout {
        if !refresh, let entry, entry.key == key { return entry.readout }
        let readout = capture()
        entry = Entry(key: key, readout: readout)
        return readout
    }
}

/// Time and download-rate observation belongs to this row, not its controls parent.
struct PlayerTransportTimeRow: View {
    let player: PlayerViewModel
    let owner: String
    let gestureDisplay: PlayerGestureDisplay
    @AppStorage("show_network_speed") private var showNetworkSpeed = false
    @Environment(\.accessibilityEnabled) private var accessibilityEnabled
    @Environment(\.locale) private var locale
    @State private var readoutMemo = PlayerTransportReadoutMemo()

    var body: some View {
        let isSeeking = gestureDisplay.isSeeking
        let key = PlayerTransportReadoutKey(
            player: ObjectIdentifier(player),
            backend: ObjectIdentifier(player.backend),
            requestedOwner: owner,
            currentOwner: player.ownerKey,
            ownerLeaseGeneration: player.ownerLeaseGeneration,
            loadGeneration: player.loadGeneration,
            playerGeneration: player.playerGeneration,
            mode: player.mode,
            currentURL: player.currentURL,
            showsNetworkSpeed: showNetworkSpeed,
            localeIdentifier: locale.identifier,
            isSeeking: isSeeking
        )
        let readout = readoutMemo.readout(
            for: key,
            refresh: player.showControls || isSeeking || accessibilityEnabled
        ) {
            captureCurrentReadout(for: key)
        }
        readoutContent(readout)
    }

    @ViewBuilder
    private func readoutContent(_ readout: PlayerTransportReadout) -> some View {
        switch readout {
        case .finite(let elapsed, let duration, let network):
            HStack {
                Text(elapsed)
                    .monospacedDigit()
                Spacer()
                // Plain text, no capsule — chrome-bound like the times
                // around it, and off entirely via the Settings toggle.
                if let network {
                    Text(network)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
                Text(duration)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.8))
        case .live(let network):
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("LIVE")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.red)
                Spacer()
                if let network {
                    Text(network)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func captureCurrentReadout(for key: PlayerTransportReadoutKey) -> PlayerTransportReadout {
        if key.mode.isSeekable {
            let elapsed = key.isSeeking ? gestureDisplay.seekValue
                : (key.currentOwner == key.requestedOwner ? player.displayTime : 0)
            let elapsedText = FormatUtils.duration(Int(elapsed))
            let network = captureNetworkText(for: key)
            let duration = FormatUtils.duration(Int(player.duration))
            return .finite(elapsed: elapsedText, duration: duration, network: network)
        }
        return .live(network: captureNetworkText(for: key))
    }

    private func captureNetworkText(for key: PlayerTransportReadoutKey) -> String? {
        guard key.showsNetworkSpeed, key.currentOwner == key.requestedOwner else { return nil }
        let stats = player.stats
        return stats.networkSpeed > 0 ? stats.networkSpeedText : nil
    }
}
