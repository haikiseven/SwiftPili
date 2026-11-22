import Foundation
import Kingfisher
import MediaPlayer
import UIKit

/// The small set of media-player events the App adapter needs to understand.
/// Converting Apple's event object at the system boundary means the command
/// handlers never move an `MPRemoteCommandEvent` across an actor boundary.
enum NowPlayingRemoteEvent: Sendable, Equatable {
    case command
    case changePlaybackPosition(TimeInterval)
    case skipInterval(TimeInterval)
    case invalid

    init(event: MPRemoteCommandEvent) {
        if let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
           positionEvent.positionTime.isFinite,
           positionEvent.positionTime >= 0 {
            self = .changePlaybackPosition(positionEvent.positionTime)
        } else if let skipEvent = event as? MPSkipIntervalCommandEvent {
            let interval = skipEvent.interval
            self = interval.isFinite && interval > 0 ? .skipInterval(interval) : .invalid
        } else {
            self = .command
        }
    }
}

/// A command admitted by the App-owned system-media adapter. The owner lease
/// travels with the command so a queued MainActor delivery cannot mutate a
/// successor playback after an owner replacement.
enum NowPlayingAppCommand: Sendable, Equatable {
    case play(owner: PlayerOwnerLease)
    case pause(owner: PlayerOwnerLease)
    case toggle(owner: PlayerOwnerLease)
    case seek(owner: PlayerOwnerLease, position: TimeInterval)
    case skip(owner: PlayerOwnerLease, interval: TimeInterval)

    var owner: PlayerOwnerLease {
        switch self {
        case .play(let owner), .pause(let owner), .toggle(let owner),
             .seek(let owner, _), .skip(let owner, _):
            return owner
        }
    }
}

/// The smallest capability requirement that must survive the off-main command
/// hop. Every command requires an actionable item; position changes additionally
/// require the current item to remain seekable with a finite duration.
private enum NowPlayingCommandRequirement: Sendable {
    case actionable
    case playbackPosition
}

/// A current-owner capability snapshot. This value is deliberately immutable
/// and Sendable: MediaPlayer may invoke a command handler on a private queue,
/// while PVM publishes the next snapshot on MainActor.
struct NowPlayingCapabilitySnapshot: Sendable, Equatable {
    let owner: PlayerOwnerLease
    /// Changes whenever the adapter retires an item/owner. This is distinct
    /// from the screen lease: a queue-next/internal successor may keep the
    /// same owner lease while an already queued system command must still be
    /// rejected for the old item.
    let itemGeneration: UInt64
    let isActionable: Bool
    let supportsPlaybackPosition: Bool
}

/// Static metadata and dynamic playback values projected into Apple's
/// Now-Playing dictionary. Keeping this as a value type makes the projection
/// testable without touching MPNowPlayingInfoCenter's process singleton.
struct NowPlayingInfoProjection: Sendable, Equatable {
    let title: String
    let artist: String
    let isLive: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval?
    let rate: Float
    let isPlaying: Bool

    init(
        title: String,
        artist: String,
        mode: PlayerMode,
        elapsed: TimeInterval,
        duration: TimeInterval,
        rate: Float,
        isPlaying: Bool
    ) {
        self.title = title
        self.artist = artist
        self.isLive = mode == .live
        self.elapsed = Self.normalizedElapsed(elapsed)
        self.duration = Self.normalizedDuration(duration, isLive: isLive)
        self.rate = Self.normalizedRate(rate)
        self.isPlaying = isPlaying
    }

    /// The values which are safe and useful to hand to MediaPlayer. Artwork
    /// is supplied separately because MPMediaItemArtwork is not a value type.
    func dictionary(artwork: MPMediaItemArtwork? = nil) -> [String: Any] {
        var result: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0
        ]
        if let duration {
            result[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            result[MPMediaItemPropertyArtwork] = artwork
        }
        return result
    }

    private static func normalizedElapsed(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func normalizedDuration(
        _ value: TimeInterval,
        isLive: Bool
    ) -> TimeInterval? {
        guard !isLive, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func normalizedRate(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}

/// The current item plus playback projection retained by the adapter.
struct NowPlayingSnapshot: Sendable, Equatable {
    let owner: PlayerOwnerLease
    let itemGeneration: UInt64
    let title: String
    let artist: String
    let coverURL: String?
    let mode: PlayerMode
    let elapsed: TimeInterval
    let duration: TimeInterval
    let rate: Float
    let isPlaying: Bool
    let isActionable: Bool

    var projection: NowPlayingInfoProjection {
        NowPlayingInfoProjection(
            title: title,
            artist: artist,
            mode: mode,
            elapsed: elapsed,
            duration: duration,
            rate: rate,
            isPlaying: isPlaying
        )
    }

    var capability: NowPlayingCapabilitySnapshot {
        NowPlayingCapabilitySnapshot(
            owner: owner,
            itemGeneration: itemGeneration,
            isActionable: isActionable,
            supportsPlaybackPosition: isActionable
                && mode.isSeekable
                && duration.isFinite
                && duration > 0
        )
    }
}

/// Lock-protected box bridging MainActor capability updates and MediaPlayer's
/// off-main command callbacks.
private final class NowPlayingSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NowPlayingCapabilitySnapshot?

    func load() -> NowPlayingCapabilitySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ value: NowPlayingCapabilitySnapshot?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

/// App-owned adapter for `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`.
/// Demand and VLC both reach this object through `PlayerViewModel`; neither
/// backend registers system handlers or writes system metadata itself.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private let commandCenter: MPRemoteCommandCenter
    private let unsupportedCommands: [MPRemoteCommand]
    private let snapshotBox = NowPlayingSnapshotBox()

    private(set) var currentSnapshot: NowPlayingSnapshot?
    private(set) var currentCapabilitySnapshot: NowPlayingCapabilitySnapshot?
    private var currentArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var artworkRevision: UInt64 = 0
    private var itemGeneration: UInt64 = 0

    // The returned values from addTarget are opaque. Keep one slot per command
    // and remove exactly those values during owner replacement/deactivation.
    private var playTarget: Any?
    private var pauseTarget: Any?
    private var toggleTarget: Any?
    private var positionTarget: Any?
    private var skipForwardTarget: Any?
    private var skipBackwardTarget: Any?

    init(center: MPRemoteCommandCenter = .shared()) {
        commandCenter = center
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        unsupportedCommands = [
            center.stopCommand,
            center.enableLanguageOptionCommand,
            center.disableLanguageOptionCommand,
            center.changePlaybackRateCommand,
            center.changeRepeatModeCommand,
            center.changeShuffleModeCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.ratingCommand,
            center.likeCommand,
            center.dislikeCommand,
            center.bookmarkCommand
        ]
        // MPRemoteCommand.isEnabled defaults to true; fail closed before an item activates.
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        unsupportedCommands.forEach { $0.isEnabled = false }
    }

    /// Installs/replaces the current item and publishes its initial dynamic
    /// values. Repeating this for the same owner is idempotent: command targets
    /// are not stacked. A lower owner lease is stale and cannot overwrite the
    /// current card while an async feature-screen callback is unwinding.
    func activate(
        owner: PlayerOwnerLease,
        title: String,
        artist: String,
        coverURL: String?,
        mode: PlayerMode,
        elapsed: TimeInterval,
        duration: TimeInterval,
        rate: Float,
        isPlaying: Bool,
        isActionable: Bool = true
    ) {
        guard !owner.owner.isEmpty else { return }
        if let currentOwner = currentSnapshot?.owner,
           currentOwner != owner,
           owner.generation <= currentOwner.generation {
            return
        }

        let previous = currentSnapshot
        let ownerChanged = previous?.owner != owner
        let artworkChanged = ownerChanged || previous?.coverURL != coverURL
        if ownerChanged {
            itemGeneration &+= 1
            unregisterOwnedCommands()
        }

        currentSnapshot = NowPlayingSnapshot(
            owner: owner,
            itemGeneration: itemGeneration,
            title: title,
            artist: artist,
            coverURL: coverURL,
            mode: mode,
            elapsed: elapsed,
            duration: duration,
            rate: rate,
            isPlaying: isPlaying,
            isActionable: isActionable
        )
        updateCapabilitySnapshot()
        if ownerChanged || !hasOwnedTargets {
            registerOwnedCommands(for: owner)
        }
        updateCommandEnablement()
        if artworkChanged {
            prepareArtwork(for: currentSnapshot!)
        } else {
            publishCurrentSnapshot()
        }
    }

    /// Applies a dynamic transport edge only when the caller still owns the
    /// current card. Returns false for a stale owner or absent item.
    @discardableResult
    func updatePlayback(
        owner: PlayerOwnerLease,
        elapsed: TimeInterval,
        duration: TimeInterval,
        rate: Float,
        isPlaying: Bool,
        isActionable: Bool? = nil
    ) -> Bool {
        guard let currentSnapshot, currentSnapshot.owner == owner else {
            return false
        }
        self.currentSnapshot = NowPlayingSnapshot(
            owner: currentSnapshot.owner,
            itemGeneration: currentSnapshot.itemGeneration,
            title: currentSnapshot.title,
            artist: currentSnapshot.artist,
            coverURL: currentSnapshot.coverURL,
            mode: currentSnapshot.mode,
            elapsed: elapsed,
            duration: duration,
            rate: rate,
            isPlaying: isPlaying,
            isActionable: isActionable ?? currentSnapshot.isActionable
        )
        updateCapabilitySnapshot()
        updateCommandEnablement()
        publishCurrentSnapshot()
        return true
    }

    /// Clears only the card and handlers owned by the matching lease. A stale
    /// owner cannot clear a successor's metadata or capability snapshot.
    @discardableResult
    func deactivate(owner: PlayerOwnerLease) -> Bool {
        guard currentSnapshot?.owner == owner else { return false }
        artworkTask?.cancel()
        artworkTask = nil
        artworkRevision &+= 1
        currentArtwork = nil
        itemGeneration &+= 1
        currentSnapshot = nil
        updateCapabilitySnapshot()
        unregisterOwnedCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        return true
    }

    private var hasOwnedTargets: Bool {
        playTarget != nil && pauseTarget != nil && toggleTarget != nil && positionTarget != nil
            && skipForwardTarget != nil && skipBackwardTarget != nil
    }

    private func updateCapabilitySnapshot() {
        currentCapabilitySnapshot = currentSnapshot?.capability
        snapshotBox.store(currentCapabilitySnapshot)
    }

    private func registerOwnedCommands(for owner: PlayerOwnerLease) {
        let state = snapshotBox
        let itemGeneration = self.itemGeneration
        playTarget = commandCenter.playCommand.addTarget { @Sendable rawEvent in
            guard case .command = NowPlayingRemoteEvent(event: rawEvent) else { return .commandFailed }
            guard let snapshot = state.load(),
                  snapshot.owner == owner,
                  snapshot.itemGeneration == itemGeneration,
                  snapshot.isActionable else {
                return .noSuchContent
            }
            Self.enqueue(
                .play(owner: owner),
                expectedItemGeneration: itemGeneration,
                requirement: .actionable,
                state: state
            )
            return .success
        }
        pauseTarget = commandCenter.pauseCommand.addTarget { @Sendable rawEvent in
            guard case .command = NowPlayingRemoteEvent(event: rawEvent) else { return .commandFailed }
            guard let snapshot = state.load(),
                  snapshot.owner == owner,
                  snapshot.itemGeneration == itemGeneration,
                  snapshot.isActionable else {
                return .noSuchContent
            }
            Self.enqueue(
                .pause(owner: owner),
                expectedItemGeneration: itemGeneration,
                requirement: .actionable,
                state: state
            )
            return .success
        }
        toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { @Sendable rawEvent in
            guard case .command = NowPlayingRemoteEvent(event: rawEvent) else { return .commandFailed }
            guard let snapshot = state.load(),
                  snapshot.owner == owner,
                  snapshot.itemGeneration == itemGeneration,
                  snapshot.isActionable else {
                return .noSuchContent
            }
            Self.enqueue(
                .toggle(owner: owner),
                expectedItemGeneration: itemGeneration,
                requirement: .actionable,
                state: state
            )
            return .success
        }
        positionTarget = commandCenter.changePlaybackPositionCommand.addTarget { @Sendable rawEvent in
            guard case .changePlaybackPosition(let position) = NowPlayingRemoteEvent(event: rawEvent),
                  position.isFinite,
                  position >= 0 else {
                return .commandFailed
            }
            guard let snapshot = state.load(),
                  snapshot.owner == owner,
                  snapshot.itemGeneration == itemGeneration,
                  snapshot.isActionable else {
                return .noSuchContent
            }
            guard snapshot.supportsPlaybackPosition else {
                return .commandFailed
            }
            Self.enqueue(
                .seek(owner: owner, position: position),
                expectedItemGeneration: itemGeneration,
                requirement: .playbackPosition,
                state: state
            )
            return .success
        }
        skipForwardTarget = registerSkipCommand(
            commandCenter.skipForwardCommand,
            for: owner,
            itemGeneration: itemGeneration,
            isForward: true
        )
        skipBackwardTarget = registerSkipCommand(
            commandCenter.skipBackwardCommand,
            for: owner,
            itemGeneration: itemGeneration,
            isForward: false
        )
    }

    private func registerSkipCommand(
        _ command: MPRemoteCommand,
        for owner: PlayerOwnerLease,
        itemGeneration: UInt64,
        isForward: Bool
    ) -> Any {
        let state = snapshotBox
        return command.addTarget { @Sendable rawEvent in
            guard case .skipInterval(let interval) = NowPlayingRemoteEvent(event: rawEvent),
                  interval.isFinite,
                  interval > 0 else { return .commandFailed }
            guard let snapshot = state.load(),
                  snapshot.owner == owner,
                  snapshot.itemGeneration == itemGeneration,
                  snapshot.isActionable else { return .noSuchContent }
            guard snapshot.supportsPlaybackPosition else { return .commandFailed }
            Self.enqueue(
                .skip(owner: owner, interval: isForward ? interval : -interval),
                expectedItemGeneration: itemGeneration,
                requirement: .playbackPosition,
                state: state
            )
            return .success
        }
    }

    private func updateCommandEnablement() {
        unsupportedCommands.forEach { $0.isEnabled = false }
        let actionable = currentCapabilitySnapshot?.isActionable == true
        commandCenter.playCommand.isEnabled = actionable
        commandCenter.pauseCommand.isEnabled = actionable
        commandCenter.togglePlayPauseCommand.isEnabled = actionable
        commandCenter.changePlaybackPositionCommand.isEnabled =
            currentCapabilitySnapshot?.supportsPlaybackPosition == true
        commandCenter.skipForwardCommand.isEnabled =
            currentCapabilitySnapshot?.supportsPlaybackPosition == true
        commandCenter.skipBackwardCommand.isEnabled =
            currentCapabilitySnapshot?.supportsPlaybackPosition == true
    }

    private func unregisterOwnedCommands() {
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false

        if let playTarget {
            commandCenter.playCommand.removeTarget(playTarget)
        }
        if let pauseTarget {
            commandCenter.pauseCommand.removeTarget(pauseTarget)
        }
        if let toggleTarget {
            commandCenter.togglePlayPauseCommand.removeTarget(toggleTarget)
        }
        if let positionTarget {
            commandCenter.changePlaybackPositionCommand.removeTarget(positionTarget)
        }
        if let skipForwardTarget {
            commandCenter.skipForwardCommand.removeTarget(skipForwardTarget)
        }
        if let skipBackwardTarget {
            commandCenter.skipBackwardCommand.removeTarget(skipBackwardTarget)
        }
        playTarget = nil
        pauseTarget = nil
        toggleTarget = nil
        positionTarget = nil
        skipForwardTarget = nil
        skipBackwardTarget = nil
    }

    private func publishCurrentSnapshot() {
        guard let currentSnapshot else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo =
            currentSnapshot.projection.dictionary(artwork: currentArtwork)
    }

    private func prepareArtwork(for snapshot: NowPlayingSnapshot) {
        artworkTask?.cancel()
        artworkTask = nil
        currentArtwork = nil
        artworkRevision &+= 1
        let revision = artworkRevision
        publishCurrentSnapshot()

        guard var urlString = snapshot.coverURL, !urlString.isEmpty else { return }
        if urlString.hasPrefix("//") { urlString = "https:" + urlString }
        urlString = urlString.replacingOccurrences(of: "http://", with: "https://")
        guard let url = URL(string: urlString) else { return }

        let owner = snapshot.owner
        artworkTask = Task { @MainActor [weak self] in
            guard let image = await Self.loadArtwork(from: url), !Task.isCancelled else { return }
            guard let self,
                  self.artworkRevision == revision,
                  self.currentSnapshot?.owner == owner else {
                return
            }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            self.currentArtwork = artwork
            self.publishCurrentSnapshot()
        }
    }

    private nonisolated static func enqueue(
        _ command: NowPlayingAppCommand,
        expectedItemGeneration: UInt64,
        requirement: NowPlayingCommandRequirement,
        state: NowPlayingSnapshotBox
    ) {
        Task { @MainActor in
            guard let current = state.load(),
                  current.owner == command.owner,
                  current.itemGeneration == expectedItemGeneration,
                  current.isActionable else { return }
            if case .playbackPosition = requirement,
               !current.supportsPlaybackPosition {
                return
            }
            Self.dispatchToPlayerViewModel(command)
        }
    }

    private static func dispatchToPlayerViewModel(_ command: NowPlayingAppCommand) {
        let vm = PlayerViewModel.shared
        guard vm.isCurrentOwner(command.owner) else { return }
        switch command {
        case .play:
            vm.play()
        case .pause:
            vm.pause()
        case .toggle:
            vm.togglePlayPause()
        case .seek(_, let position):
            guard vm.mode.isSeekable else { return }
            let execution = vm.beginBackgroundPlaybackRestoration(reason: "remote-seek", explicit: true)
            vm.seek(to: position) { [weak vm] settlement in
                vm?.finishBackgroundSeek(execution, settlement: settlement)
            }
        case .skip(_, let interval):
            let duration = vm.duration
            let position = vm.backend.currentTime
            guard vm.mode.isSeekable,
                  duration.isFinite, duration > 0,
                  position.isFinite, position >= 0,
                  interval.isFinite, interval != 0 else { return }
            let target = position + interval
            guard target.isFinite else { return }
            // Resolve from the actual transport at execution, not the static
            // system snapshot. Existing seek owns end reserve and pause intent.
            let execution = vm.beginBackgroundPlaybackRestoration(reason: "remote-skip", explicit: true)
            vm.seek(to: min(duration, max(0, target))) { [weak vm] settlement in
                vm?.finishBackgroundSeek(execution, settlement: settlement)
            }
        }
    }

    private static func loadArtwork(from url: URL) async -> UIImage? {
        guard let result = try? await KingfisherManager.shared.retrieveImage(with: url) else {
            return nil
        }
        return result.image
    }
}
