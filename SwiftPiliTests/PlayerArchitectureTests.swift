import Foundation
import Observation
import os
import Testing
@testable import SwiftPili

@Suite("PlayerArchitecture")
@MainActor
struct PlayerArchitectureTests {
    @Test("PlaybackClockState mutations do not trigger Observation notifications on PlayerChromeState")
    func clockMutationsDoNotInvalidateChromeObservers() {
        let clock = PlaybackClockState()
        let chrome = PlayerChromeState()

        let chromeInvalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = chrome.showControls
            _ = chrome.isFullscreen
            _ = chrome.showStats
            _ = chrome.ambientModeEnabled
        } onChange: {
            chromeInvalidations.withLock { $0 += 1 }
        }

        let clockInvalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = clock.mediaTime
            _ = clock.bufferedTime
            _ = clock.duration
            _ = clock.isBuffering
        } onChange: {
            clockInvalidations.withLock { $0 += 1 }
        }

        // High-frequency clock/buffer mutations must notify clock observers only.
        clock.mediaTime = 12.5
        clock.duration = 120.0
        clock.isBuffering = true
        clock.bufferedTime = 45.0
        clock.mutateBufferedTime {
            clock.bufferedTimeProjection.ingest(range: BufferedDisplayRange(start: 12.5, end: 52.0))
        }

        #expect(clockInvalidations.withLock { $0 } == 1)
        #expect(chromeInvalidations.withLock { $0 } == 0)
        #expect(clock.mediaTime == 12.5)
        #expect(clock.mediaTimeMovedAt > 0)
        #expect(clock.publishedBufferedRange == BufferedDisplayRange(start: 12.5, end: 52.0))

        // Mutating chrome now triggers the chrome observer as expected.
        chrome.showControls = false
        #expect(chromeInvalidations.withLock { $0 } == 1)
    }

    @Test("PlayerChromeState mutations do not trigger Observation notifications on PlaybackClockState")
    func chromeMutationsDoNotInvalidateClockObservers() {
        let clock = PlaybackClockState()
        let chrome = PlayerChromeState()

        let clockInvalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = clock.mediaTime
            _ = clock.bufferedTime
            _ = clock.publishedBufferedRange
        } onChange: {
            clockInvalidations.withLock { $0 += 1 }
        }

        chrome.showControls = false
        chrome.isFullscreen = true
        chrome.isPortraitContent = true
        chrome.inlineCondensed = true
        chrome.showStats = true

        #expect(clockInvalidations.withLock { $0 } == 0)
    }

    @Test("PlayerRouteOwnershipCoordinator transfers activeSceneID cleanly across multi-window handoffs")
    func multiWindowRouteOwnershipSceneHandoff() {
        let coordinator = PlayerRouteOwnershipCoordinator()
        let windowA = UUID()
        let windowB = UUID()

        // Window A claims playback ownership.
        let claimA = coordinator.claimOwnership(owner: "vod-100", sceneID: windowA)
        #expect(coordinator.activeSceneID == windowA)
        #expect(coordinator.ownerKey == "vod-100")
        #expect(coordinator.currentOwnerLease == claimA.lease)
        #expect(!claimA.didTransferScene)
        #expect(claimA.previousSceneID == nil)
        #expect(coordinator.isCurrentOwner(claimA.lease, in: windowA))
        #expect(!coordinator.isCurrentOwner(claimA.lease, in: windowB))
        #expect(coordinator.ownsScene(windowA))
        #expect(!coordinator.ownsScene(windowB))

        // Window B claims playback — activeSceneID transfers and Window A yields cleanly.
        let claimB = coordinator.claimOwnership(owner: "vod-200", sceneID: windowB)
        #expect(coordinator.activeSceneID == windowB)
        #expect(coordinator.ownerKey == "vod-200")
        #expect(claimB.didTransferScene)
        #expect(claimB.previousSceneID == windowA)
        #expect(claimB.previousOwner == "vod-100")
        #expect(!coordinator.isCurrentOwner(claimA.lease, in: windowA))
        #expect(!coordinator.ownsScene(windowA))
        #expect(coordinator.isCurrentOwner(claimB.lease, in: windowB))
        #expect(coordinator.ownsScene(windowB))

        // Window A releasing ownership after handoff cannot clear Window B's active lease.
        coordinator.releaseOwnership(matchingSceneID: windowA)
        #expect(coordinator.activeSceneID == windowB)
        #expect(coordinator.currentOwnerLease == claimB.lease)

        // Window B releasing ownership clears both ownerKey and activeSceneID.
        coordinator.releaseOwnership(matchingSceneID: windowB)
        #expect(coordinator.activeSceneID == nil)
        #expect(coordinator.ownerKey.isEmpty)
        #expect(coordinator.currentOwnerLease == nil)
    }

    @Test("PlayerRouteOwnershipCoordinator binds an unbound lease to the first presenting window scene")
    func bindActiveSceneIfUnbound() {
        let coordinator = PlayerRouteOwnershipCoordinator()
        let windowA = UUID()
        let windowB = UUID()

        let claim = coordinator.claimOwnership(owner: "live-42", sceneID: nil)
        #expect(coordinator.activeSceneID == nil)
        #expect(coordinator.isCurrentOwner(claim.lease, in: windowA))

        coordinator.bindActiveSceneIfUnbound(windowA)
        #expect(coordinator.activeSceneID == windowA)
        #expect(coordinator.isCurrentOwner(claim.lease, in: windowA))
        #expect(!coordinator.isCurrentOwner(claim.lease, in: windowB))

        // Subsequent bind attempts from another window do not overwrite the bound scene.
        coordinator.bindActiveSceneIfUnbound(windowB)
        #expect(coordinator.activeSceneID == windowA)
    }

    @Test("FullscreenLoginHandoff isolates scene-targeted arm, release, and consume across windows")
    func fullscreenLoginHandoffSceneIsolation() {
        let handoff = FullscreenLoginHandoff()
        let windowA = UUID()
        let windowB = UUID()

        // Arming for Window A does not mark ready until fullscreen dismissal releases.
        handoff.arm(sceneID: windowA)
        #expect(!handoff.isReady)
        #expect(handoff.targetSceneID == nil)
        #expect(!handoff.consume(for: windowA))

        // Releasing publishes readiness targeted specifically at Window A.
        handoff.release()
        #expect(handoff.isReady)
        #expect(handoff.targetSceneID == windowA)

        // Window B and untargeted consumers cannot steal Window A's handoff.
        #expect(!handoff.consume(for: windowB))
        #expect(!handoff.consume())
        #expect(handoff.isReady)
        #expect(handoff.targetSceneID == windowA)

        // Window A consumes its own handoff exactly once.
        #expect(handoff.consume(for: windowA))
        #expect(!handoff.isReady)
        #expect(handoff.targetSceneID == nil)
        #expect(!handoff.consume(for: windowA))
    }

    @Test("FullscreenLoginHandoff preserves backward-compatible untargeted arm/consume and cancel")
    func fullscreenLoginHandoffBackwardCompatibilityAndCancel() {
        let handoff = FullscreenLoginHandoff()
        let windowA = UUID()

        // Cancelling before release prevents becoming ready.
        handoff.arm(sceneID: windowA)
        handoff.cancel()
        handoff.release()
        #expect(!handoff.isReady)
        #expect(!handoff.consume(for: windowA))

        // Legacy no-argument arm() / consume() continues to work.
        handoff.arm()
        handoff.release()
        #expect(handoff.isReady)
        #expect(handoff.targetSceneID == nil)
        #expect(handoff.consume())
        #expect(!handoff.isReady)

        // Untargeted arm() can also be consumed by a scene-aware RootView.
        handoff.arm()
        handoff.release()
        #expect(handoff.consume(for: windowA))
        #expect(!handoff.isReady)
    }
}
