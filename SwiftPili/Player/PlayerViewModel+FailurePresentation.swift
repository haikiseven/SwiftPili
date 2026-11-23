import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    struct TerminalFailurePayload {
        let message: String
        var unavailability: PlaybackUnavailability? = nil
        var retireStreamRecoveryReason: String? = "terminal-failure"
        var startupTraceAbortLabel: String? = nil
        var logMessage: String? = nil
    }

    func settleTerminalFailure(_ payload: TerminalFailurePayload) {
        if let abortLabel = payload.startupTraceAbortLabel {
            StartupTrace.abort(
                abortLabel,
                token: PlayerStartupTraceScope.tokenForStream(
                    mode: mode,
                    retainedToken: startupTraceToken
                )
            )
        }
        if let retireReason = payload.retireStreamRecoveryReason {
            retireStreamRecovery(reason: retireReason)
        }
        retireCDNSwitch()
        if let reason = payload.unavailability {
            unavailability = reason
        }
        terminalOpenFailure = true
        playbackTerminalState = .terminalFailure
        error = payload.message
        isBuffering = false
        activeSeekToken?.settle(.failed)
        activeSeekToken = nil
        playbackTerminalSettlement.suppressingPauseProjection {
            backend.pause()
            updateIsPlaying(transportRunning: false)
        }
        pushNowPlayingPlayback()
        acknowledgeLifecycleReadiness(.terminalFailure)
        finishNonLifecycleRecoveryIfNeeded(outcome: .backendError)
        standDownLifecycleForTerminalPlayback()
        if let logMessage = payload.logMessage {
            PlayerLog.log(logMessage)
        }
    }

    func markTerminalOpenFailure(_ failure: LiveStreamSelectionError) {
        guard failure.isRetryable else {
            markUnavailable(
                .noPlayableStream,
                message: failure.localizedDescription,
                detail: "live-\(failure.classification.rawValue)"
            )
            return
        }
        settleTerminalFailure(TerminalFailurePayload(
            message: String(
                format: String(localized: "Playback error: %@"),
                failure.localizedDescription
            )
        ))
    }

    func markUnavailable(
        _ reason: PlaybackUnavailability,
        message: String? = nil,
        detail: String? = nil
    ) {
        settleTerminalFailure(TerminalFailurePayload(
            message: message ?? reason.message,
            unavailability: reason,
            startupTraceAbortLabel: "unavailable-\(reason.rawValue)",
            logMessage: "[Player] ⛔️ unavailable (\(reason.rawValue))"
                + (detail.map { " — \($0)" } ?? "")
        ))
    }

    func markTransientStreamUnreachable() {
        markUnavailable(.streamUnreachable, detail: "probe")
    }

    func markTerminalNoReachableStreamFailure() {
        settleTerminalFailure(TerminalFailurePayload(
            message: PlaybackUnavailability.noPlayableStream.message,
            unavailability: .noPlayableStream,
            startupTraceAbortLabel: "no-reachable-stream"
        ))
    }
}
