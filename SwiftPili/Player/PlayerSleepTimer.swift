import Foundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

enum PlayerSleepTimerOption: Equatable, Hashable, Identifiable, Sendable {
    case off
    case endOfVideo
    case minutes(Int)

    static let minutePresets: [Int] = [15, 30, 60]

    var id: String {
        switch self {
        case .off: "off"
        case .endOfVideo: "endOfVideo"
        case .minutes(let minutes): "minutes-\(minutes)"
        }
    }

    static func options(allowsEndOfVideo: Bool) -> [PlayerSleepTimerOption] {
        var result: [PlayerSleepTimerOption] = [.off]
        if allowsEndOfVideo {
            result.append(.endOfVideo)
        }
        result.append(contentsOf: minutePresets.map(Self.minutes))
        return result
    }

    var label: String {
        switch self {
        case .off:
            return String(localized: "Off")
        case .endOfVideo:
            return String(localized: "End of Current Video")
        case .minutes(15):
            return String(localized: "15 Minutes")
        case .minutes(30):
            return String(localized: "30 Minutes")
        case .minutes(60):
            return String(localized: "60 Minutes")
        case .minutes(let minutes):
            return String(format: String(localized: "%lld Minutes"), Int64(minutes))
        }
    }
}

enum PlayerSleepTimerExpiryReason: Equatable, Sendable {
    case countdown
    case endOfVideo
}

enum PlayerSleepTimerPolicy {
    static func shouldCloseSessionOnExpiry(
        hasActiveMiniPlayer: Bool,
        applicationState: UIApplication.State,
        isPiPActive: Bool
    ) -> Bool {
        hasActiveMiniPlayer || applicationState != .active || isPiPActive
    }

    static func formattedRemainingTime(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

@MainActor
@Observable
final class PlayerSleepTimer {
    private(set) var option: PlayerSleepTimerOption = .off
    private(set) var remainingSeconds: Int?

    @ObservationIgnored private var deadline: ContinuousClock.Instant?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var timerGeneration: UInt64 = 0

    var isActive: Bool { option != .off }

    var menuBadge: String? {
        switch option {
        case .off:
            return nil
        case .endOfVideo:
            return String(localized: "End of Video")
        case .minutes:
            guard let remainingSeconds else { return nil }
            return PlayerSleepTimerPolicy.formattedRemainingTime(seconds: remainingSeconds)
        }
    }

    static func shouldCloseSessionOnExpiry(
        hasActiveMiniPlayer: Bool,
        applicationState: UIApplication.State,
        isPiPActive: Bool
    ) -> Bool {
        PlayerSleepTimerPolicy.shouldCloseSessionOnExpiry(
            hasActiveMiniPlayer: hasActiveMiniPlayer,
            applicationState: applicationState,
            isPiPActive: isPiPActive
        )
    }

    func select(
        _ newOption: PlayerSleepTimerOption,
        allowsEndOfVideo: Bool = true,
        now: ContinuousClock.Instant = .now,
        onCountdownExpired: @escaping @MainActor () -> Void
    ) {
        let resolvedOption: PlayerSleepTimerOption =
            (!allowsEndOfVideo && newOption == .endOfVideo) ? .off : newOption
        timerGeneration &+= 1
        let generation = timerGeneration
        countdownTask?.cancel()
        countdownTask = nil
        deadline = nil
        option = resolvedOption

        switch resolvedOption {
        case .off, .endOfVideo:
            remainingSeconds = nil
        case .minutes(let minutes):
            let totalSeconds = max(1, minutes * 60)
            remainingSeconds = totalSeconds
            deadline = now.advanced(by: .seconds(totalSeconds))
            countdownTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, self.timerGeneration == generation else {
                        return
                    }
                    if self.reconcile(now: .now, onCountdownExpired: onCountdownExpired) {
                        return
                    }
                }
            }
        }
    }

    @discardableResult
    func reconcile(
        now: ContinuousClock.Instant = .now,
        onCountdownExpired: @escaping @MainActor () -> Void
    ) -> Bool {
        guard case .minutes = option, let deadline else { return false }
        let remaining = Self.ceilSeconds(now.duration(to: deadline))
        if remaining <= 0 {
            cancel()
            onCountdownExpired()
            return true
        }
        if remainingSeconds != remaining {
            remainingSeconds = remaining
        }
        return false
    }

    func cancel() {
        timerGeneration &+= 1
        countdownTask?.cancel()
        countdownTask = nil
        deadline = nil
        if option != .off {
            option = .off
        }
        if remainingSeconds != nil {
            remainingSeconds = nil
        }
    }

    func clearEndOfVideoIfUnsupported() {
        if option == .endOfVideo {
            cancel()
        }
    }

    @discardableResult
    func consumeEndOfVideoIfArmed() -> Bool {
        guard option == .endOfVideo else { return false }
        cancel()
        return true
    }

    static func ceilSeconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        if seconds < 0 || (seconds == 0 && attoseconds <= 0) {
            return 0
        }
        let extra: Int64 = attoseconds > 0 ? 1 : 0
        return Int(clamping: seconds + extra)
    }
}

extension PlayerViewModel {
    var sleepTimerOption: PlayerSleepTimerOption {
        sleepTimer.option
    }

    var sleepTimerRemainingSeconds: Int? {
        sleepTimer.remainingSeconds
    }

    var sleepTimerMenuBadge: String? {
        sleepTimer.menuBadge
    }

    static func shouldCloseSessionOnSleepTimerExpiry(
        hasActiveMiniPlayer: Bool,
        applicationState: UIApplication.State,
        isPiPActive: Bool
    ) -> Bool {
        PlayerSleepTimer.shouldCloseSessionOnExpiry(
            hasActiveMiniPlayer: hasActiveMiniPlayer,
            applicationState: applicationState,
            isPiPActive: isPiPActive
        )
    }

    func setSleepTimer(_ option: PlayerSleepTimerOption) {
        sleepTimer.select(option, allowsEndOfVideo: mode != .live) { [weak self] in
            self?.handleSleepTimerExpired(reason: .countdown)
        }
        PlayerLog.log("[SleepTimer] set option=\(sleepTimerOption.id)")
    }

    func cancelSleepTimer() {
        sleepTimer.cancel()
    }

    func handleSleepTimerExpired(reason: PlayerSleepTimerExpiryReason) {
        sleepTimer.cancel()
        cancelEndedAutoAdvance()
        autonomousQueueAdvanceGeneration &+= 1
        autonomousQueueAdvanceTask?.cancel()
        autonomousQueueAdvanceTask = nil
        isAutonomousQueueAdvanceInFlight = false

        let hasMiniPlayer = miniPlayer.activeSession != nil
        let isPiP = backend.isPiPActive || backend.hasObservedPiPLease
        let closesSession = Self.shouldCloseSessionOnSleepTimerExpiry(
            hasActiveMiniPlayer: hasMiniPlayer,
            applicationState: UIApplication.shared.applicationState,
            isPiPActive: isPiP
        )
        PlayerLog.log(
            "[SleepTimer] expired reason=\(reason) closeSession=\(closesSession ? 1 : 0) " +
            "miniPlayer=\(hasMiniPlayer ? 1 : 0) pip=\(isPiP ? 1 : 0) " +
            "appState=\(Self.applicationStateLabel)"
        )
        if closesSession {
            if miniPlayer.activeSession != nil {
                dismissMiniPlayer()
            } else {
                if backend.isPiPActive || backend.hasObservedPiPLease {
                    backend.stopPiP()
                }
                stop(reason: .ownerExit)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            return
        }

        switch reason {
        case .countdown:
            pause()
            showNotice(String(localized: "Paused by sleep timer"))
        case .endOfVideo:
            if playbackTerminalState == .ended {
                settleTerminalPlaybackEndPresentation()
            }
        }
    }
}

struct PlayerSleepTimerSubmenu: View {
    let player: PlayerViewModel

    var body: some View {
        Menu {
            ForEach(PlayerSleepTimerOption.options(allowsEndOfVideo: player.mode != .live)) { option in
                Button {
                    player.setSleepTimer(option)
                } label: {
                    HStack {
                        Text(option.label)
                        if option == player.sleepTimerOption {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label {
                if let badge = player.sleepTimerMenuBadge {
                    Text("Sleep Timer") + Text(verbatim: " (\(badge))")
                } else {
                    Text("Sleep Timer")
                }
            } icon: {
                Image(systemName: player.sleepTimerOption == .off ? "moon.zzz" : "moon.zzz.fill")
            }
        }
        .accessibilityIdentifier("player.sleepTimer")
    }
}
