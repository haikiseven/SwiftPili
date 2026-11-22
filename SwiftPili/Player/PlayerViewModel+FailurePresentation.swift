import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    /// Surface a Demand live selection refusal with the retryability its CLASSIFICATION earns.
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

    /// The reason still decides retryability and the symbol — only the words change, so there is still exactly
    /// one place that decides whether Retry appears.
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
        // Deliberately NOT `playbackIntent = .pausedByUser`.
        updateIsPlaying(transportRunning: false)
        pushNowPlayingPlayback()
        acknowledgeLifecycleReadiness(.terminalFailure)
        PlayerLog.log(
            "[Player] ⛔️ unavailable (\(reason.rawValue))" +
                (detail.map { " — \($0)" } ?? "")
        )
    }

    /// Every candidate host failed its probe. Distinct from
    /// `markTerminalNoReachableStreamFailure` because this one IS retryable —
    /// see `PlaybackUnavailability.streamUnreachable`.
    func markTransientStreamUnreachable() {
        markUnavailable(.streamUnreachable, detail: "probe")
    }

    func markTerminalNoReachableStreamFailure() {
        // Terminal before any stream opened: no stop() will close the trace
        // session, and both call sites are generation-guarded, so the active
        // session (if any) is this load's own.
        StartupTrace.abort(
            "no-reachable-stream",
            token: PlayerStartupTraceScope.tokenForStream(
                mode: mode,
                retainedToken: startupTraceToken
            )
        )
        terminalOpenFailure = true
        // A load that produced no openable stream is not a transient failure to
        // retry: the playurl response has already been walked, DASH and durl
        // both, and nothing in it was usable.
        unavailability = .noPlayableStream
        error = PlaybackUnavailability.noPlayableStream.message
        isBuffering = false
        updateIsPlaying(transportRunning: false)
        pushNowPlayingPlayback()
        acknowledgeLifecycleReadiness(.terminalFailure)
    }
}
