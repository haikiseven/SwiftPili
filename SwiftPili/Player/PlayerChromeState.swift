import Foundation
import Observation
import UIKit

/// UI chrome, layout framing, and ambient presentation state isolated from playback clock ticks.
@MainActor
@Observable
final class PlayerChromeState {
    var showControls = true
    var isFullscreen = false
    var isPortraitContent = false
    var inlineCondensed = false
    var portraitCondenseLocked = false
    var showStats = false

    var ambientModeEnabled = ExperimentalSettingsPolicy.isAllowed(.ambient)
    var ambientCoverURL: String?
    @ObservationIgnored
    var ambientOwnerLease: PlayerOwnerLease?
    var ambientStoryboard: [PlayerAmbientStoryboardFrame] = []
    @ObservationIgnored
    var ambientStoryboardOwnerLease: PlayerOwnerLease?
    @ObservationIgnored
    var ambientStoryboardLoadGeneration: Int?
    @ObservationIgnored
    var ambientStoryboardContent: PlayerAmbientStoryboardLoader.Content?
    @ObservationIgnored
    var ambientSelectionMediaTime: TimeInterval?
    @ObservationIgnored
    var ambientSelectionContent: PlayerAmbientStoryboardLoader.Content?
    var ambientSelectionSource: PlayerAmbientSource?
    var ambientVideoLoadedOwner: PlayerOwnerLease?
    var ambientLiveImage: UIImage?
    var ambientLiveFrameSerial: UInt64 = 0
    @ObservationIgnored
    var lastAmbientLiveSampleWall: TimeInterval = 0
    @ObservationIgnored
    let ambientStoryboardLoader = PlayerAmbientStoryboardLoader()
    @ObservationIgnored
    var ambientStoryboardRequest: PlayerAmbientStoryboardLoader.Request?

    @ObservationIgnored
    var hideControlsTask: Task<Void, Never>?
    var danmakuSettingsHold = false
    var fullscreenDanmakuComposerPresented = false
}
