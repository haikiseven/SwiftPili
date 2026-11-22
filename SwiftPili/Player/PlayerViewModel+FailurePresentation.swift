import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func markTerminalOpenFailure(_ failure: LiveStreamSelectionError) {
        guard failure.isRetryable else {
            markUnavailable(
                .noPlayableStream,
                message: failure.localizedDescription,
                detail: "live-\(failure.classification.rawValue)"
            )
            return
        }
        terminalOpenFailure = true
        error = String(
            format: String(localized: "Playback error: %@"),
            failure.localizedDescription
        )
        isBuffering = false
        updateIsPlaying(transportRunning: false)
        pushNowPlayingPlayback()
        acknowledgeLifecycleReadiness(.terminalFailure)
    }

    func markUnavailable(
        _ reason: PlaybackUnavailability,
        message: String? = nil,
        detail: String? = nil
    ) {
        StartupTrace.abort(
            "unavailable-\(reason.rawValue)",
            token: PlayerStartupTraceScope.tokenForStream(
                mode: mode,
                retainedToken: startupTraceToken
            )
        )
        unavailability = reason
        error = message ?? reason.message
        terminalOpenFailure = true
        isBuffering = false
        updateIsPlaying(transportRunning: false)
        pushNowPlayingPlayback()
        acknowledgeLifecycleReadiness(.terminalFailure)
        PlayerLog.log(
            "[Player] ⛔️ unavailable (\(reason.rawValue))" +
                (detail.map { " — \($0)" } ?? "")
        )
    }

    func markTransientStreamUnreachable() {
        markUnavailable(.streamUnreachable, detail: "probe")
    }

    func markTerminalNoReachableStreamFailure() {
        StartupTrace.abort(
            "no-reachable-stream",
            token: PlayerStartupTraceScope.tokenForStream(
                mode: mode,
                retainedToken: startupTraceToken
            )
        )
        terminalOpenFailure = true
        unavailability = .noPlayableStream
        error = PlaybackUnavailability.noPlayableStream.message
        isBuffering = false
        updateIsPlaying(transportRunning: false)
        pushNowPlayingPlayback()
        acknowledgeLifecycleReadiness(.terminalFailure)
    }
}
