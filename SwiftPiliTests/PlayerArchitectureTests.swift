import CoreVideo
import Foundation
import Metal
import Observation
import os
import Testing
import UIKit
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

    @Test("PlayerSessionState hasRenderedFirstFrame mutations isolate from PlaybackClockState and PlayerChromeState")
    func sessionFirstFrameMutationsIsolateFromClockAndChrome() {
        let session = PlayerSessionState()
        let clock = PlaybackClockState()
        let chrome = PlayerChromeState()

        #expect(!session.hasRenderedFirstFrame)

        let sessionInvalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = session.hasRenderedFirstFrame
        } onChange: {
            sessionInvalidations.withLock { $0 += 1 }
        }

        let clockInvalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = clock.mediaTime
            _ = clock.isBuffering
        } onChange: {
            clockInvalidations.withLock { $0 += 1 }
        }

        let chromeInvalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = chrome.showControls
            _ = chrome.isFullscreen
        } onChange: {
            chromeInvalidations.withLock { $0 += 1 }
        }

        session.hasRenderedFirstFrame = true

        #expect(session.hasRenderedFirstFrame)
        #expect(sessionInvalidations.withLock { $0 } == 1)
        #expect(clockInvalidations.withLock { $0 } == 0)
        #expect(chromeInvalidations.withLock { $0 } == 0)
    }

    @Test("PlayerRouteOwnershipCoordinator stores outgoing stills directly and PlayerTeardownReason preserves presentation only on internal reload")
    func routeOwnershipOutgoingStillsAndTeardownPreservation() {
        let coordinator = PlayerRouteOwnershipCoordinator()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }

        coordinator.outgoingRouteStills["vod-100"] = image
        coordinator.departedRouteStillOwners.append("vod-100")

        #expect(coordinator.outgoingRouteStills["vod-100"] != nil)
        #expect(coordinator.departedRouteStillOwners == ["vod-100"])

        coordinator.outgoingRouteStills.removeValue(forKey: "vod-100")
        coordinator.departedRouteStillOwners.removeAll()
        #expect(coordinator.outgoingRouteStills.isEmpty)
        #expect(coordinator.departedRouteStillOwners.isEmpty)

        #expect(PlayerTeardownReason.internalReload.preservesPresentation)
        #expect(!PlayerTeardownReason.ownerExit.preservesPresentation)
        #expect(!PlayerTeardownReason.newContentOwnership.preservesPresentation)
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

    // MARK: - Frame Interpolation Target-FPS Planning

    @Test("Exact 30 fps and 29.97 fps streams targeting 60 fps use low-latency 2x LLFI")
    func exactTwoXInterpolationUsesLowLatencyFastPath() {
        for sourceFPS in [30.0, 30_000.0 / 1001.0] {
            let interval = 1.0 / sourceFPS
            let outcome = VideoFrameInterpolationPlan.plan(
                previousPTS: 1.0,
                currentPTS: 1.0 + interval,
                interval: interval,
                cadenceInterval: interval,
                isCadenceStable: true,
                gridNextPTS: nil,
                rate: .fps60,
                supportsArbitraryPhases: true
            )
            guard case let .plan(plan) = outcome else {
                Issue.record("Expected exact 2x plan for \(sourceFPS) fps, got \(outcome)")
                continue
            }
            #expect(plan.phases == [0.5])
            #expect(plan.pts.count == 1)
            #expect(plan.allowsLowLatency)
            #expect(plan.emitsOriginal)
            #expect(plan.nextGridPTS == nil)
        }
    }

    @Test("Stable 30 fps stream with a 19/600s quantized pair stays on 2x LLFI and never bypasses")
    func quantizedTickUnderStable30FPSStaysOnLLFI() {
        var estimator = VideoFrameCadenceEstimator()
        var pts: TimeInterval = 0
        for _ in 0..<8 {
            estimator.observe(pts: pts)
            pts += 20.0 / 600.0
        }
        let prevPTS = pts
        let quantizedDelta: TimeInterval = 19.0 / 600.0
        let currPTS = prevPTS + quantizedDelta
        estimator.observe(pts: prevPTS)
        estimator.observe(pts: currPTS)

        #expect(estimator.isConstantRate)
        let outcome = VideoFrameInterpolationPlan.plan(
            previousPTS: prevPTS,
            currentPTS: currPTS,
            interval: quantizedDelta,
            cadenceInterval: estimator.medianInterval,
            isCadenceStable: estimator.isConstantRate,
            gridNextPTS: nil,
            rate: .fps60,
            supportsArbitraryPhases: true
        )
        guard case let .plan(plan) = outcome else {
            Issue.record("Expected 2x LLFI plan for quantized 19/600 tick, got \(outcome)")
            return
        }
        #expect(plan.phases == [0.5])
        #expect(plan.allowsLowLatency)
        #expect(plan.emitsOriginal)
        #expect(plan.nextGridPTS == nil)
    }

    @Test("Non-integer and VFR cadences targeting 60 fps use arbitrary-phase CFR resampling with monotonic PTS")
    func nonIntegerAndVFRCadencesUseCFRResamplingTo60FPS() {
        let scenarios: [(name: String, timestamps: [TimeInterval])] = [
            ("31.0 fps", (0...120).map { Double($0) / 31.0 }),
            ("30.6 fps", (0...120).map { Double($0) / 30.6 }),
            ("24.0 fps", (0...120).map { Double($0) / 24.0 }),
            ("25.0 fps", (0...120).map { Double($0) / 25.0 }),
            ("40.0 fps", (0...120).map { Double($0) / 40.0 }),
            ("50.0 fps", (0...120).map { Double($0) / 50.0 }),
            ("VFR 28-34 fps", {
                var pts: [TimeInterval] = [0]
                for index in 0..<120 {
                    let fps = 31.0 + 3.0 * sin(Double(index) * 0.7)
                    pts.append(pts[index] + 1.0 / fps)
                }
                return pts
            }()),
        ]

        for scenario in scenarios {
            var estimator = VideoFrameCadenceEstimator()
            estimator.observe(pts: scenario.timestamps[0])
            var gridNextPTS: TimeInterval?
            var lastEmittedPTS = scenario.timestamps[0]
            var emittedCount = 0

            for index in 1..<scenario.timestamps.count {
                let prevPTS = scenario.timestamps[index - 1]
                let currPTS = scenario.timestamps[index]
                estimator.observe(pts: currPTS)

                let outcome = VideoFrameInterpolationPlan.plan(
                    previousPTS: prevPTS,
                    currentPTS: currPTS,
                    interval: currPTS - prevPTS,
                    cadenceInterval: estimator.medianInterval,
                    isCadenceStable: estimator.isConstantRate,
                    gridNextPTS: gridNextPTS,
                    rate: .fps60,
                    supportsArbitraryPhases: true
                )
                guard case let .plan(plan) = outcome else {
                    Issue.record("[\(scenario.name)] unexpected bypass at frame \(index): \(outcome)")
                    break
                }
                #expect(!plan.allowsLowLatency, "[\(scenario.name)] frame \(index) must not route to LLFI")
                #expect(plan.isCFRResampling, "[\(scenario.name)] frame \(index) must be CFR resampling")
                #expect(plan.phases.count == plan.pts.count)

                for phase in plan.phases {
                    #expect(phase > 0.001 && phase < 0.999, "[\(scenario.name)] phase \(phase) out of bounds")
                }
                for point in plan.pts {
                    #expect(point > lastEmittedPTS, "[\(scenario.name)] non-monotonic midpoint PTS at frame \(index)")
                    #expect(point > prevPTS && point < currPTS)
                    lastEmittedPTS = point
                    emittedCount += 1
                }
                if plan.emitsOriginal {
                    #expect(currPTS > lastEmittedPTS, "[\(scenario.name)] non-monotonic original PTS at frame \(index)")
                    lastEmittedPTS = currPTS
                    emittedCount += 1
                }
                gridNextPTS = plan.nextGridPTS
            }

            let totalDuration = scenario.timestamps.last! - scenario.timestamps.first!
            let measuredFPS = Double(emittedCount) / totalDuration
            #expect(
                abs(measuredFPS - 60.0) <= 1.5,
                "[\(scenario.name)] measured output FPS \(measuredFPS) not within ±1.5 fps of 60.0"
            )
        }
    }

    @Test("59.94 fps and 60 fps streams targeting 60 fps bypass with Target frame rate reached")
    func nativeSixtyFPSBypassesAsTargetReached() {
        for sourceFPS in [60_000.0 / 1001.0, 60.0] {
            let interval = 1.0 / sourceFPS
            let outcome = VideoFrameInterpolationPlan.plan(
                previousPTS: 0,
                currentPTS: interval,
                interval: interval,
                cadenceInterval: interval,
                isCadenceStable: true,
                gridNextPTS: nil,
                rate: .fps60,
                supportsArbitraryPhases: true
            )
            guard case let .bypass(reason) = outcome else {
                Issue.record("Expected bypass for \(sourceFPS) fps targeting 60 fps, got \(outcome)")
                continue
            }
            #expect(reason == "Target frame rate reached")
        }
    }

    @Test("60fps-container 30fps-content cadence is detected from PTS deltas and accepted by timing")
    func sixtyFPSContainerThirtyFPSContentDetectedAndAccepted() {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        guard let buffer = pixelBuffer else { return }

        let declaredDuration: TimeInterval = 1.0 / 60.0
        let actualInterval: TimeInterval = 1.0 / 30.0
        var estimator = VideoFrameCadenceEstimator()
        estimator.observe(pts: 0.0)
        estimator.observe(pts: actualInterval)
        estimator.observe(pts: 2.0 * actualInterval)

        let median = estimator.medianInterval
        #expect(median != nil)
        if let median {
            #expect(abs(median - actualInterval) < 1e-6)
        }

        let current = MediaVideoFrame(pts: actualInterval, duration: declaredDuration, pixelBuffer: buffer)
        let timing = VideoFrameInterpolationTiming(
            previousPTS: 0.0,
            previousDuration: declaredDuration,
            current: current,
            expectedInterval: estimator.medianInterval
        )
        #expect(timing != nil)
        if let timing {
            #expect(abs(timing.delta - actualInterval) < 1e-6)
        }
        #expect(
            VideoFrameInterpolationPlan.streamEligibilityBypassReason(
                sourceInterval: estimator.estimatedInterval(fallbackDuration: declaredDuration) ?? 0,
                rate: .fps60,
                supportsArbitraryPhases: true
            ) == nil
        )
    }

    @Test("Dyadic-only device on 35 fps targeting 60 fps reports Ratio unsupported rather than Target FPS reached")
    func dyadicOnlyUnsupportedRatioIsNeverReportedAsTargetReached() {
        let interval = 1.0 / 35.0
        let outcome = VideoFrameInterpolationPlan.plan(
            previousPTS: 0,
            currentPTS: interval,
            interval: interval,
            cadenceInterval: interval,
            isCadenceStable: true,
            gridNextPTS: nil,
            rate: .fps60,
            supportsArbitraryPhases: false
        )
        guard case let .bypass(reason) = outcome else {
            Issue.record("Expected dyadic-only bypass for 35 fps -> 60 fps, got \(outcome)")
            return
        }
        #expect(reason == "Interpolation ratio unsupported")
        #expect(
            VideoEnhancementBypassDisplay.shortLabel(for: reason)
                != VideoEnhancementBypassDisplay.shortLabel(for: "Target frame rate reached")
        )
        #expect(
            VideoEnhancementBypassDisplay.shortLabel(for: reason)
                != VideoEnhancementBypassDisplay.shortLabel(for: "Unsupported")
        )
    }

    @Test("VideoEnhancementTelemetryWindow accurately measures 60 fps when CFR skips originals")
    func telemetryWindowReportsTrueOutputFPSWhenCFRSkipsOriginals() {
        var window = VideoEnhancementTelemetryWindow()
        window.span = .seconds(1)
        let start = ContinuousClock.now

        // Seed window start at t=0, then record 50 source frames across 1.0s (50 fps -> 60 fps CFR:
        // 40 frames emit only 1 midpoint with emittedOriginal == false, 10 frames emit midpoint + original).
        window.record(.init(
            at: start,
            upscaled: false,
            midpoints: 1,
            missReason: nil,
            inputWidth: 1920,
            inputHeight: 1080,
            outputWidth: 1920,
            outputHeight: 1080,
            emittedOriginal: false,
            interpolationStepActive: true
        ))
        for index in 1...50 {
            let emitsOriginal = index.isMultiple(of: 5)
            window.record(.init(
                at: start.advanced(by: .milliseconds(index * 20)),
                upscaled: false,
                midpoints: 1,
                missReason: nil,
                inputWidth: 1920,
                inputHeight: 1080,
                outputWidth: 1920,
                outputHeight: 1080,
                emittedOriginal: emitsOriginal,
                interpolationStepActive: true
            ))
        }

        var config = VideoEnhancementConfiguration()
        config.frameInterpolationEnabled = true
        config.interpolationRate = .fps60

        let summary = window.summarize(
            latest: VideoEnhancementTelemetry(),
            configuration: config,
            interpolationLabel: "VT FI",
            now: start.advanced(by: .seconds(1))
        )
        #expect(summary != nil)
        if let summary {
            #expect(abs(summary.inputFPS - 50.0) < 0.05)
            #expect(abs(summary.outputFPS - 60.0) < 0.05)
            #expect(summary.interpolationShare == 1.0)
            #expect(summary.isActive)
        }
    }

    @Test("30 fps video at 2.0x playback speed targeting 60 fps bypasses as Target frame rate reached")
    func doubleSpeedThirtyFPSBypassesUpTo60FPS() {
        let interval = 1.0 / 30.0
        #expect(
            VideoFrameInterpolationPlan.streamEligibilityBypassReason(
                sourceInterval: interval,
                rate: .fps60,
                playbackRate: 2.0,
                supportsArbitraryPhases: true
            ) == "Target frame rate reached"
        )
        let outcome = VideoFrameInterpolationPlan.plan(
            previousPTS: 0,
            currentPTS: interval,
            interval: interval,
            cadenceInterval: interval,
            isCadenceStable: true,
            gridNextPTS: nil,
            rate: .fps60,
            playbackRate: 2.0,
            supportsArbitraryPhases: true
        )
        guard case let .bypass(reason) = outcome else {
            Issue.record("Expected bypass for 30 fps at 2.0x targeting 60 fps, got \(outcome)")
            return
        }
        #expect(reason == "Target frame rate reached")
    }

    @Test("30 fps video at 1.5x playback speed targeting 60 fps uses 25ms media CFR grid for ~60 fps wall-clock output")
    func onePointFiveSpeedThirtyFPSResamplesTo60FPSWallClock() {
        let playbackRate = 1.5
        let timestamps = (0...120).map { Double($0) / 30.0 }
        var estimator = VideoFrameCadenceEstimator()
        estimator.observe(pts: timestamps[0])
        var gridNextPTS: TimeInterval?
        var lastEmittedPTS = timestamps[0]
        var emittedCount = 0

        for index in 1..<timestamps.count {
            let prevPTS = timestamps[index - 1]
            let currPTS = timestamps[index]
            estimator.observe(pts: currPTS)

            let outcome = VideoFrameInterpolationPlan.plan(
                previousPTS: prevPTS,
                currentPTS: currPTS,
                interval: currPTS - prevPTS,
                cadenceInterval: estimator.medianInterval,
                isCadenceStable: estimator.isConstantRate,
                gridNextPTS: gridNextPTS,
                rate: .fps60,
                playbackRate: playbackRate,
                supportsArbitraryPhases: true
            )
            guard case let .plan(plan) = outcome else {
                Issue.record("Unexpected bypass at frame \(index) for 30 fps @ 1.5x -> 60 fps: \(outcome)")
                return
            }
            #expect(!plan.allowsLowLatency)
            #expect(plan.isCFRResampling)
            #expect(abs(plan.outputFrameDuration - 0.025) < 1e-6)
            #expect(abs(plan.targetOutputFPS - 60.0) < 1e-6)

            for phase in plan.phases {
                #expect(phase > 0.001 && phase < 0.999)
            }
            for point in plan.pts {
                #expect(point > lastEmittedPTS)
                #expect(point > prevPTS && point < currPTS)
                lastEmittedPTS = point
                emittedCount += 1
            }
            if plan.emitsOriginal {
                #expect(currPTS > lastEmittedPTS)
                lastEmittedPTS = currPTS
                emittedCount += 1
            }
            gridNextPTS = plan.nextGridPTS
        }

        let mediaDuration = timestamps.last! - timestamps.first!
        let mediaOutputFPS = Double(emittedCount) / mediaDuration
        let wallClockOutputFPS = mediaOutputFPS * playbackRate
        #expect(abs(mediaOutputFPS - 40.0) <= 1.0)
        #expect(abs(wallClockOutputFPS - 60.0) <= 1.5)
    }

    @Test("VideoEnhancementTelemetryWindow reflects partial midpoint drops in interpolationShare")
    func telemetryWindowDetectsPartialMidpointDrops() {
        var window = VideoEnhancementTelemetryWindow()
        window.span = .seconds(1)
        let start = ContinuousClock.now

        window.record(.init(
            at: start,
            upscaled: false,
            midpoints: 1,
            expectedMidpoints: 3,
            missReason: "Interpolation deadline",
            inputWidth: 1920,
            inputHeight: 1080,
            outputWidth: 1920,
            outputHeight: 1080
        ))
        for index in 1...30 {
            window.record(.init(
                at: start.advanced(by: .milliseconds(index * 33)),
                upscaled: false,
                midpoints: 1,
                expectedMidpoints: 3,
                missReason: "Interpolation deadline",
                inputWidth: 1920,
                inputHeight: 1080,
                outputWidth: 1920,
                outputHeight: 1080
            ))
        }

        var config = VideoEnhancementConfiguration()
        config.frameInterpolationEnabled = true
        config.interpolationRate = .fps120

        let summary = window.summarize(
            latest: VideoEnhancementTelemetry(),
            configuration: config,
            interpolationLabel: "VT FI",
            now: start.advanced(by: .seconds(1))
        )
        #expect(summary != nil)
        if let summary {
            #expect(summary.isActive)
            #expect(summary.interpolationShare != nil)
            if let share = summary.interpolationShare {
                #expect(share < 0.5)
                #expect(abs(share - (1.0 / 3.0)) < 0.02)
            }
            #expect(summary.partialReason == "Interpolation deadline")
        }
    }

    @Test("VideoSuperResolutionSharpness strength ordering and persistence round-trip")
    func superResolutionSharpnessStrengthAndPersistence() {
        #expect(VideoEnhancementConfiguration().superResolutionSharpness == .standard)
        #expect(VideoSuperResolutionSharpness.off.rcasStrength == 0)
        #expect(VideoSuperResolutionSharpness.off.rcasStrength < VideoSuperResolutionSharpness.light.rcasStrength)
        #expect(VideoSuperResolutionSharpness.light.rcasStrength < VideoSuperResolutionSharpness.standard.rcasStrength)
        #expect(VideoSuperResolutionSharpness.standard.rcasStrength < VideoSuperResolutionSharpness.strong.rcasStrength)
        #expect(VideoSuperResolutionSharpness.strong.rcasStrength <= 1.0)

        let key = "experimental_video_enhancement_super_resolution_sharpness"
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(VideoEnhancementPreferences.superResolutionSharpness == .standard)
        for level in VideoSuperResolutionSharpness.allCases {
            VideoEnhancementPreferences.superResolutionSharpness = level
            #expect(VideoEnhancementPreferences.superResolutionSharpness == level)
        }
    }

    @Test("O(1) VideoFrameCadenceEstimator ring buffer wraps cleanly, distinguishes jittered CFR from VFR, and resets on discontinuities")
    func cadenceEstimatorRingBufferWrapVFRAndDiscontinuityReset() {
        var estimator = VideoFrameCadenceEstimator()
        #expect(estimator.sampleCount == 0)
        #expect(estimator.medianInterval == nil)
        #expect(estimator.isConstantRate)

        // Fill >16 samples at 24 fps to verify wrap-around cap at 16 samples.
        var pts: TimeInterval = 0
        estimator.observe(pts: pts)
        for _ in 0..<20 {
            pts += 1.0 / 24.0
            estimator.observe(pts: pts)
        }
        #expect(estimator.sampleCount == 16)
        #expect(estimator.isConstantRate)
        if let median = estimator.medianInterval {
            #expect(abs(median - (1.0 / 24.0)) < 1e-6)
        } else {
            Issue.record("Expected non-nil medianInterval after 20 samples")
        }

        // Feed 16 more samples at 1ms-quantized 30 fps (0.033s / 0.033s / 0.034s -> ~3.0% IQR/median <= 8%)
        // so the ring buffer wraps around completely and evicts all 24 fps samples.
        for index in 0..<16 {
            pts += (index % 3 == 2) ? 0.034 : 0.033
            estimator.observe(pts: pts)
        }
        #expect(estimator.sampleCount == 16)
        #expect(estimator.isConstantRate)
        if let median = estimator.medianInterval {
            #expect(abs(median - (1.0 / 30.0)) < 0.002)
        } else {
            Issue.record("Expected non-nil medianInterval after wrap-around")
        }

        // Feed VFR spread (alternating 1/20s and 1/50s -> wide IQR >> 8%) to verify isConstantRate flips false.
        for index in 0..<16 {
            pts += index.isMultiple(of: 2) ? (1.0 / 20.0) : (1.0 / 50.0)
            estimator.observe(pts: pts)
        }
        #expect(estimator.sampleCount == 16)
        #expect(!estimator.isConstantRate)

        // Negative discontinuity (backward seek) clears accumulated samples and tracks new cadence.
        pts -= 2.0
        estimator.observe(pts: pts)
        #expect(estimator.sampleCount == 0)
        #expect(estimator.medianInterval == nil)
        #expect(estimator.isConstantRate)

        pts += 1.0 / 30.0
        estimator.observe(pts: pts)
        #expect(estimator.sampleCount == 1)
        if let median = estimator.medianInterval {
            #expect(abs(median - (1.0 / 30.0)) < 1e-6)
        } else {
            Issue.record("Expected sample after backward seek recovery")
        }

        // Large forward discontinuity (>0.5s gap) clears samples without polluting cadence.
        pts += 1.25
        estimator.observe(pts: pts)
        #expect(estimator.sampleCount == 0)
        #expect(estimator.medianInterval == nil)
        #expect(estimator.isConstantRate)

        // Explicit reset clears both sample history and lastObservedPTS.
        pts += 1.0 / 25.0
        estimator.observe(pts: pts)
        #expect(estimator.sampleCount == 1)
        estimator.reset()
        #expect(estimator.sampleCount == 0)
        #expect(estimator.medianInterval == nil)
        #expect(estimator.isConstantRate)
        #expect(estimator.estimatedInterval(fallbackDuration: 1.0 / 30.0) == 1.0 / 30.0)
    }

    @Test("VideoEnhancementGuardrails pauses on serious/critical thermal without mutating config and classifies SDR 8-bit vs HDR")
    func guardrailsThermalPauseResumeAndSDR8BitClassification() {
        func makeBuffer(format: OSType, transfer: CFString? = nil) -> CVPixelBuffer? {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, format, nil, &buffer)
            guard status == kCVReturnSuccess, let buffer else { return nil }
            if let transfer {
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
            }
            return buffer
        }

        guard let nv12Video = makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              let nv12Full = makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
              let bgra = makeBuffer(format: kCVPixelFormatType_32BGRA),
              let sdr709 = makeBuffer(
                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                transfer: kCVImageBufferTransferFunction_ITU_R_709_2
              ),
              let pq8Bit = makeBuffer(
                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
              ),
              let hlg8Bit = makeBuffer(
                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG
              ),
              let linear8Bit = makeBuffer(
                format: kCVPixelFormatType_32BGRA,
                transfer: kCVImageBufferTransferFunction_Linear
              ),
              let p010 = makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) else {
            Issue.record("Failed to allocate test CVPixelBuffers")
            return
        }

        // SDR 8-bit format + transfer function checks
        #expect(VideoEnhancementGuardrails.isSDR8Bit(nv12Video))
        #expect(VideoEnhancementGuardrails.isSDR8Bit(nv12Full))
        #expect(VideoEnhancementGuardrails.isSDR8Bit(bgra))
        #expect(VideoEnhancementGuardrails.isSDR8Bit(sdr709))
        #expect(!VideoEnhancementGuardrails.isSDR8Bit(pq8Bit))
        #expect(!VideoEnhancementGuardrails.isSDR8Bit(hlg8Bit))
        #expect(!VideoEnhancementGuardrails.isSDR8Bit(linear8Bit))
        #expect(!VideoEnhancementGuardrails.isSDR8Bit(p010))

        // Hard thermal guardrail: allow .nominal and .fair, pause on .serious and .critical,
        // and resume cleanly with zero config mutation.
        var config = VideoEnhancementConfiguration()
        config.superResolutionMode = .metalFXSpatial
        config.superResolutionTargetResolution = .p1440
        config.frameInterpolationEnabled = true
        config.interpolationRate = .fps60
        let snapshot = config

        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: config, pixelBuffer: nv12Video, thermalState: .nominal, memoryPressure: false
        ) == nil)
        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: config, pixelBuffer: nv12Video, thermalState: .fair, memoryPressure: false
        ) == nil)
        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: config, pixelBuffer: nv12Video, thermalState: .serious, memoryPressure: false
        ) == "Thermal throttling")
        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: config, pixelBuffer: nv12Video, thermalState: .critical, memoryPressure: false
        ) == "Thermal throttling")
        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: config, pixelBuffer: nv12Video, thermalState: .fair, memoryPressure: false
        ) == nil)
        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: config, pixelBuffer: nv12Video, thermalState: .nominal, memoryPressure: false
        ) == nil)
        #expect(config == snapshot)

        // Explicit 1440p target on 1080p stream resolves cleanly without any degradation step-down.
        let outcome = VideoSuperResolutionTargetResolution.resolveMetalFXOutput(
            inputWidth: 1920,
            inputHeight: 1080,
            targetShortEdge: config.superResolutionTargetResolution.shortEdge ?? 0
        )
        #expect(outcome == .output(VideoSuperResolutionDimensions(width: 2560, height: 1440)))

        // Memory pressure, HDR, and live stream hard bypass reasons
        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: config, pixelBuffer: nv12Video, thermalState: .nominal, memoryPressure: true
        ) == "Memory pressure")
        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: config, pixelBuffer: pq8Bit, thermalState: .nominal, memoryPressure: false
        ) == "HDR / 10-bit")
        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: config, pixelBuffer: hlg8Bit, thermalState: .nominal, memoryPressure: false
        ) == "HDR / 10-bit")

        var liveConfig = config
        liveConfig.isLiveStream = true
        #expect(VideoEnhancementGuardrails.commonBypassReason(
            configuration: liveConfig, pixelBuffer: nv12Video, thermalState: .nominal, memoryPressure: false
        ) == "VOD only")
    }

    @Test("VideoEnhancementMetalContext.shared loads precompiled default.metallib and builds all enhancement compute pipelines")
    func metalContextLoadsDefaultMetallibAndBuildsAllPipelines() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        let context = VideoEnhancementMetalContext.shared
        let resources = try context.resources()
        #expect(!resources.library.functionNames.isEmpty)

        let expectedKernels: [VideoEnhancementMetalContext.Kernel] = [
            .nv12ToBGRA,
            .nv12RangeConvertY,
            .nv12RangeConvertCbCr,
            .rcasSharpen,
            .rcasToNV12,
            .nv12StageCopyY,
            .nv12StageCopyCbCr,
            .visionInterpolationPrepare,
            .visionInterpolationValidate,
            .visionInterpolationSynthesize,
        ]
        for kernel in expectedKernels {
            let pipeline = try context.pipeline(for: kernel)
            #expect(pipeline.maxTotalThreadsPerThreadgroup > 0, "Invalid pipeline for \(kernel.rawValue)")
            // Second lookup hits cache cleanly.
            let cached = try context.pipeline(for: kernel)
            #expect(cached.maxTotalThreadsPerThreadgroup == pipeline.maxTotalThreadsPerThreadgroup)
        }
    }

    @Test("MetalNV12PixelConverter and NV12 GPU staging copy produce matching pixel data on synthetic IOSurface CVPixelBuffers")
    nonisolated func nv12PixelConverterAndStagingCopyMatchExpectedPixels() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        func makeIOSurfaceBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &buffer
            )
            return status == kCVReturnSuccess ? buffer : nil
        }

        let width = 16
        let height = 16
        guard let src420v = makeIOSurfaceBuffer(
            width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ), let dstBGRA = makeIOSurfaceBuffer(
            width: width, height: height, format: kCVPixelFormatType_32BGRA
        ), let dst420f = makeIOSurfaceBuffer(
            width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ), let dst420vStaged = makeIOSurfaceBuffer(
            width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ) else {
            Issue.record("Failed to allocate IOSurface-backed test CVPixelBuffers")
            return
        }

        CVBufferSetAttachment(
            src420v, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate
        )

        // Populate synthetic 420v buffer with distinct luma values (video-range black=16, mid=126, white=235)
        // and neutral chroma (Cb=128, Cr=128) so RGB output is deterministically grayscale.
        #expect(CVPixelBufferLockBaseAddress(src420v, []) == kCVReturnSuccess)
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(src420v, 0)?.assumingMemoryBound(to: UInt8.self),
           let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(src420v, 1)?.assumingMemoryBound(to: UInt8.self) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(src420v, 0)
            let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(src420v, 1)
            for row in 0..<height {
                let luma: UInt8 = row < 4 ? 16 : (row < 12 ? 126 : 235)
                for col in 0..<width {
                    yBase[row * yStride + col] = luma
                }
            }
            for row in 0..<(height / 2) {
                for col in 0..<(width / 2) {
                    cbcrBase[row * cbcrStride + col * 2] = 128
                    cbcrBase[row * cbcrStride + col * 2 + 1] = 128
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(src420v, [])

        // 1) MetalNV12PixelConverter: 420v -> 32BGRA
        let converter = MetalNV12PixelConverter()
        let convertedBGRA = await converter.convert(from: src420v, to: dstBGRA)
        #expect(convertedBGRA)

        #expect(CVPixelBufferLockBaseAddress(dstBGRA, .readOnly) == kCVReturnSuccess)
        if let bgraBase = CVPixelBufferGetBaseAddress(dstBGRA)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRow(dstBGRA)
            for (row, expected) in [(1, 0), (8, 128), (14, 255)] {
                let offset = row * stride + 8 * 4
                let b = Int(bgraBase[offset])
                let g = Int(bgraBase[offset + 1])
                let r = Int(bgraBase[offset + 2])
                let a = Int(bgraBase[offset + 3])
                #expect(abs(r - expected) <= 2, "Row \(row) R=\(r), expected ~\(expected)")
                #expect(abs(g - expected) <= 2, "Row \(row) G=\(g), expected ~\(expected)")
                #expect(abs(b - expected) <= 2, "Row \(row) B=\(b), expected ~\(expected)")
                #expect(a == 255)
            }
        }
        CVPixelBufferUnlockBaseAddress(dstBGRA, .readOnly)

        // 2) MetalNV12PixelConverter: 420v -> 420f range conversion (16 -> 0, 126 -> ~128, 235 -> 255)
        let convertedFull = await converter.convert(from: src420v, to: dst420f)
        #expect(convertedFull)

        #expect(CVPixelBufferLockBaseAddress(dst420f, .readOnly) == kCVReturnSuccess)
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(dst420f, 0)?.assumingMemoryBound(to: UInt8.self),
           let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(dst420f, 1)?.assumingMemoryBound(to: UInt8.self) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(dst420f, 0)
            let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(dst420f, 1)
            #expect(Int(yBase[1 * yStride + 4]) <= 1)
            #expect(abs(Int(yBase[8 * yStride + 4]) - 128) <= 2)
            #expect(Int(yBase[14 * yStride + 4]) >= 254)
            #expect(abs(Int(cbcrBase[2 * cbcrStride + 4]) - 128) <= 1)
            #expect(abs(Int(cbcrBase[2 * cbcrStride + 5]) - 128) <= 1)
        }
        CVPixelBufferUnlockBaseAddress(dst420f, .readOnly)

        // 3) NV12 GPU staging copy (`VTNV12StagingCopy.copyAsync` on device, `nv12StageCopyY`/`nv12StageCopyCbCr` on all targets)
        // Populate varied non-neutral CbCr values before staging so chroma plane copy is verified byte-for-byte.
        #expect(CVPixelBufferLockBaseAddress(src420v, []) == kCVReturnSuccess)
        if let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(src420v, 1)?.assumingMemoryBound(to: UInt8.self) {
            let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(src420v, 1)
            for row in 0..<(height / 2) {
                for col in 0..<(width / 2) {
                    cbcrBase[row * cbcrStride + col * 2] = UInt8(64 + row * 12 + col * 4)
                    cbcrBase[row * cbcrStride + col * 2 + 1] = UInt8(200 - row * 8 - col * 3)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(src420v, [])

        #if !targetEnvironment(simulator)
        try await VTNV12StagingCopy.copyAsync(from: src420v, to: dst420vStaged)
        #else
        let metal = VideoEnhancementMetalContext.shared
        let resources = try metal.resources()
        let yPipe = try metal.pipeline(for: .nv12StageCopyY)
        let cbcrPipe = try metal.pipeline(for: .nv12StageCopyCbCr)
        guard let cmd = resources.commandQueue.makeCommandBuffer(),
              let srcY = metal.makeTexture(buffer: src420v, format: .r8Unorm, width: width, height: height, plane: 0),
              let srcCbCr = metal.makeTexture(
                buffer: src420v, format: .rg8Unorm, width: width / 2, height: height / 2, plane: 1
              ),
              let dstY = metal.makeTexture(
                buffer: dst420vStaged, format: .r8Unorm, width: width, height: height, plane: 0, usage: .shaderWrite
              ),
              let dstCbCr = metal.makeTexture(
                buffer: dst420vStaged, format: .rg8Unorm, width: width / 2, height: height / 2, plane: 1,
                usage: .shaderWrite
              ),
              let compute = cmd.makeComputeCommandEncoder() else {
            Issue.record("Failed to set up Metal NV12 stage copy encoder")
            return
        }
        var yParams = VideoEnhancementNV12StageCopyParams(
            activeWidth: UInt32(width), activeHeight: UInt32(height), padLeft: 0, padTop: 0
        )
        compute.setComputePipelineState(yPipe)
        compute.setTexture(srcY.texture, index: 0)
        compute.setTexture(dstY.texture, index: 1)
        compute.setBytes(&yParams, length: MemoryLayout<VideoEnhancementNV12StageCopyParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(encoder: compute, pipeline: yPipe, width: width, height: height)

        var cbcrParams = VideoEnhancementNV12StageCopyParams(
            activeWidth: UInt32(width / 2), activeHeight: UInt32(height / 2), padLeft: 0, padTop: 0
        )
        compute.setComputePipelineState(cbcrPipe)
        compute.setTexture(srcCbCr.texture, index: 0)
        compute.setTexture(dstCbCr.texture, index: 1)
        compute.setBytes(&cbcrParams, length: MemoryLayout<VideoEnhancementNV12StageCopyParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: compute, pipeline: cbcrPipe, width: width / 2, height: height / 2
        )
        compute.endEncoding()
        let retained = [srcY.bridge, srcCbCr.bridge, dstY.bridge, dstCbCr.bridge]
        let ok = await VideoEnhancementMetalContext.commitAndWait(cmd)
        withExtendedLifetime(retained) {}
        #expect(ok)
        #endif

        #expect(CVPixelBufferLockBaseAddress(dst420vStaged, .readOnly) == kCVReturnSuccess)
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(dst420vStaged, 0)?.assumingMemoryBound(to: UInt8.self),
           let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(dst420vStaged, 1)?.assumingMemoryBound(to: UInt8.self) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(dst420vStaged, 0)
            let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(dst420vStaged, 1)
            for row in 0..<height {
                let expectedLuma: UInt8 = row < 4 ? 16 : (row < 12 ? 126 : 235)
                for col in 0..<width {
                    #expect(yBase[row * yStride + col] == expectedLuma)
                }
            }
            for row in 0..<(height / 2) {
                for col in 0..<(width / 2) {
                    #expect(cbcrBase[row * cbcrStride + col * 2] == UInt8(64 + row * 12 + col * 4))
                    #expect(cbcrBase[row * cbcrStride + col * 2 + 1] == UInt8(200 - row * 8 - col * 3))
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(dst420vStaged, .readOnly)
    }

    @Test("VTSRNegotiation.resolveOutputDimensions uses explicit attrs or falls back to even-aligned input*scale")
    func vtsrNegotiationResolveOutputDimensions() {
        let explicit = VTSRNegotiation.resolveOutputDimensions(
            inputWidth: 1920,
            inputHeight: 1080,
            scale: 2.0,
            destinationAttributes: [
                kCVPixelBufferWidthKey as String: 3840,
                kCVPixelBufferHeightKey as String: 2160,
            ]
        )
        #expect(explicit?.width == 3840)
        #expect(explicit?.height == 2160)

        let omitted = VTSRNegotiation.resolveOutputDimensions(
            inputWidth: 1920,
            inputHeight: 1080,
            scale: 2.0,
            destinationAttributes: [:]
        )
        #expect(omitted?.width == 3840)
        #expect(omitted?.height == 2160)

        let evenAligned = VTSRNegotiation.resolveOutputDimensions(
            inputWidth: 854,
            inputHeight: 480,
            scale: 1.5,
            destinationAttributes: [:]
        )
        let evenWidth = evenAligned?.width ?? 1
        let evenHeight = evenAligned?.height ?? 1
        #expect(evenWidth == 1282)
        #expect(evenHeight == 720)
        #expect(evenWidth.isMultiple(of: 2))
        #expect(evenHeight.isMultiple(of: 2))

        let nonEnlarging = VTSRNegotiation.resolveOutputDimensions(
            inputWidth: 1920,
            inputHeight: 1080,
            scale: 2.0,
            destinationAttributes: [
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080,
            ]
        )
        #expect(nonEnlarging == nil)
    }

    @Test("VTSRNegotiation.selectFormat picks direct 420v or falls back cleanly to 32BGRA / 420v")
    func vtsrNegotiationSelectFormat() {
        let nv12Video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let nv12Full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let bgra = kCVPixelFormatType_32BGRA

        let direct = VTSRNegotiation.selectFormat(
            preferred: VTSRNegotiation.sourceFormatPriority(for: nv12Video),
            nativeSupported: [nv12Video, bgra],
            attributeFormats: [nv12Video, bgra]
        )
        #expect(direct == nv12Video)

        let bgraFallback = VTSRNegotiation.selectFormat(
            preferred: VTSRNegotiation.sourceFormatPriority(for: nv12Video),
            nativeSupported: [bgra],
            attributeFormats: [bgra]
        )
        #expect(bgraFallback == bgra)

        let fullToVideoFallback = VTSRNegotiation.selectFormat(
            preferred: VTSRNegotiation.sourceFormatPriority(for: nv12Full),
            nativeSupported: [nv12Video],
            attributeFormats: []
        )
        #expect(fullToVideoFallback == nv12Video)

        let destBgra = VTSRNegotiation.selectFormat(
            preferred: VTSRNegotiation.destinationFormatPriority(for: nv12Video),
            nativeSupported: [],
            attributeFormats: [bgra]
        )
        #expect(destBgra == bgra)
    }

    @Test("VideoEnhancementPoolLimits.computeSizing scales lead and pools across 30/60/120 fps and memory pressure")
    func videoEnhancementPoolLimitsComputeSizingAcrossRatesAndMemoryPressure() {
        defer { VideoEnhancementPoolLimits.reset() }

        // 30 fps SR-only
        let sr30 = VideoEnhancementPoolLimits.computeSizing(
            sourceFPS: 30, outputFPS: 30, maxPhasesPerPair: 0, underMemoryPressure: false
        )
        #expect(sr30.lead == 0.24)
        #expect(sr30.superResolutionFrames >= Int(ceil((sr30.lead + 0.10) * 30)))
        #expect(sr30.interpolationFrames(phaseCount: 1) >= Int(ceil((sr30.lead + 0.10) * 30)))

        // 30 -> 60 fps SR+FI
        let srFi60 = VideoEnhancementPoolLimits.computeSizing(
            sourceFPS: 30, outputFPS: 60, maxPhasesPerPair: 1, underMemoryPressure: false
        )
        #expect(srFi60.lead == 0.24)
        #expect(srFi60.superResolutionFrames >= Int(ceil((srFi60.lead + 0.10) * 60)) + 1)
        #expect(srFi60.interpolationFrames(phaseCount: 1) >= Int(ceil((srFi60.lead + 0.10) * 30)))

        // 30 -> 120 fps SR+FI (3 phases per source pair)
        let srFi120 = VideoEnhancementPoolLimits.computeSizing(
            sourceFPS: 30, outputFPS: 120, maxPhasesPerPair: 3, underMemoryPressure: false
        )
        #expect(srFi120.lead == 0.20)
        #expect(srFi120.superResolutionFrames >= Int(ceil((srFi120.lead + 0.10) * 120)) + 3)
        #expect(srFi120.interpolationFrames(phaseCount: 3) >= 3 * Int(ceil((srFi120.lead + 0.10) * 30)))

        // Memory pressure reduces lead and both pool caps
        let pressure60 = VideoEnhancementPoolLimits.computeSizing(
            sourceFPS: 30, outputFPS: 60, maxPhasesPerPair: 1, underMemoryPressure: true
        )
        #expect(pressure60.lead == 0.14)
        #expect(pressure60.lead < srFi60.lead)
        #expect(pressure60.superResolutionFrames < srFi60.superResolutionFrames)
        #expect(pressure60.interpolationFrames(phaseCount: 1) < srFi60.interpolationFrames(phaseCount: 1))

        let pressure120 = VideoEnhancementPoolLimits.computeSizing(
            sourceFPS: 30, outputFPS: 120, maxPhasesPerPair: 3, underMemoryPressure: true
        )
        #expect(pressure120.lead == 0.14)
        #expect(pressure120.superResolutionFrames < srFi120.superResolutionFrames)
        #expect(pressure120.interpolationFrames(phaseCount: 3) < srFi120.interpolationFrames(phaseCount: 3))

        // Shared configure / reset cycle
        VideoEnhancementPoolLimits.configure(
            sourceFPS: 30, outputFPS: 120, maxPhasesPerPair: 3, underMemoryPressure: false
        )
        #expect(VideoEnhancementPoolLimits.currentLead == srFi120.lead)
        #expect(VideoEnhancementPoolLimits.superResolutionFrames == srFi120.superResolutionFrames)
        #expect(VideoEnhancementPoolLimits.interpolationFrames(phaseCount: 3) == srFi120.interpolationFrames(phaseCount: 3))

        VideoEnhancementPoolLimits.reset()
        #expect(VideoEnhancementPoolLimits.currentLead == VideoEnhancementPoolLimits.defaultLead)
    }

    @Test("VideoFramePostProcessor.notifyWhenIdle fires cleanly on worker completion, teardown, and respects clearIdleCallback")
    func videoFramePostProcessorNotifyWhenIdleFiresOnCompletionAndTearDown() async {
        var rawBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &rawBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = rawBuffer else {
            Issue.record("Failed to allocate test CVPixelBuffer")
            return
        }

        let processor = VideoFramePostProcessor()
        defer { processor.tearDown() }

        // 1) Fires immediately when already idle
        let immediateCount = OSAllocatedUnfairLock(initialState: 0)
        processor.notifyWhenIdle { immediateCount.withLock { $0 += 1 } }
        #expect(immediateCount.withLock { $0 } == 1)

        let prevFrame = MediaVideoFrame(pts: 1.0, duration: 1.0 / 30.0, pixelBuffer: pixelBuffer)
        let currFrame = MediaVideoFrame(pts: 1.0 + 1.0 / 30.0, duration: 1.0 / 30.0, pixelBuffer: pixelBuffer)
        let admission = VideoEnhancementAdmission(
            configuration: VideoEnhancementConfiguration.disabled,
            superResolution: nil,
            superResolutionBypassReason: "Off",
            interpolationPlan: nil,
            interpolationBypassReason: "Off",
            activeOriginalDuration: nil
        )
        let deadlines = VideoEnhancementDeadlines(
            original: ContinuousClock.now.advanced(by: .seconds(1)),
            midpoint: nil
        )

        // 2) Fires exactly once when an in-flight job completes
        let completionCount = OSAllocatedUnfairLock(initialState: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            processor.submit(currFrame, previous: prevFrame, admission: admission, deadlines: deadlines) { _ in }
            #expect(processor.isBusy)
            processor.notifyWhenIdle {
                completionCount.withLock { $0 += 1 }
                continuation.resume()
            }
            #expect(completionCount.withLock { $0 } == 0)
        }
        #expect(completionCount.withLock { $0 } == 1)
        #expect(!processor.isBusy)

        // 3) Fires once on tearDown() while busy and does not double-fire
        let tearDownCount = OSAllocatedUnfairLock(initialState: 0)
        processor.submit(currFrame, previous: prevFrame, admission: admission, deadlines: deadlines) { _ in }
        #expect(processor.isBusy)
        processor.notifyWhenIdle { tearDownCount.withLock { $0 += 1 } }
        #expect(tearDownCount.withLock { $0 } == 0)
        processor.tearDown()
        #expect(!processor.isBusy)
        #expect(tearDownCount.withLock { $0 } == 1)
        processor.tearDown()
        #expect(tearDownCount.withLock { $0 } == 1)

        // 4) clearIdleCallback() prevents notification on subsequent tearDown()
        let clearedCount = OSAllocatedUnfairLock(initialState: 0)
        processor.submit(currFrame, previous: prevFrame, admission: admission, deadlines: deadlines) { _ in }
        #expect(processor.isBusy)
        processor.notifyWhenIdle { clearedCount.withLock { $0 += 1 } }
        processor.clearIdleCallback()
        processor.tearDown()
        #expect(clearedCount.withLock { $0 } == 0)
    }

    @Test("MetalFX NV12 selection, ScaledVideoOutputMetadata YCbCr matrix stamping, prewarmPlan, and rcasToNV12 kernel")
    nonisolated func metalFXNV12MetadataPrewarmPlanAndRCASToNV12Kernel() async throws {
        // 1) MetalFX even-dimension NV12 output selection
        #expect(MetalFXSuperResolutionBackend.prefersNV12Output(width: 2560, height: 1440))
        #expect(MetalFXSuperResolutionBackend.prefersNV12Output(width: 3840, height: 2160))
        #expect(!MetalFXSuperResolutionBackend.prefersNV12Output(width: 1921, height: 1080))
        #expect(!MetalFXSuperResolutionBackend.prefersNV12Output(width: 1920, height: 1081))
        #expect(!MetalFXSuperResolutionBackend.prefersNV12Output(width: 0, height: 1080))

        func makeBuffer(width: Int, height: Int, format: OSType, ioSurface: Bool = false) -> CVPixelBuffer? {
            var attrs: [String: Any] = [:]
            if ioSurface {
                attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
                attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, format,
                attrs.isEmpty ? nil : attrs as CFDictionary, &buffer
            )
            return status == kCVReturnSuccess ? buffer : nil
        }

        // 2) ScaledVideoOutputMetadata YCbCr matrix stamping & non-overwrite guarantee
        guard let buf709 = makeBuffer(width: 16, height: 16, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              let buf601 = makeBuffer(width: 16, height: 16, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              let buf2020 = makeBuffer(width: 16, height: 16, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else {
            Issue.record("Failed to allocate test CVPixelBuffers for YCbCr matrix check")
            return
        }

        ScaledVideoOutputMetadata.ensureYCbCrMatrixAttachment(on: buf709, colorMatrixIndex: 0)
        ScaledVideoOutputMetadata.ensureYCbCrMatrixAttachment(on: buf601, colorMatrixIndex: 1)
        ScaledVideoOutputMetadata.ensureYCbCrMatrixAttachment(on: buf2020, colorMatrixIndex: 2)
        if let m709 = CVBufferCopyAttachment(buf709, kCVImageBufferYCbCrMatrixKey, nil) {
            #expect(CFEqual(m709, kCVImageBufferYCbCrMatrix_ITU_R_709_2))
        } else {
            Issue.record("Expected BT.709 YCbCr matrix attachment")
        }
        if let m601 = CVBufferCopyAttachment(buf601, kCVImageBufferYCbCrMatrixKey, nil) {
            #expect(CFEqual(m601, kCVImageBufferYCbCrMatrix_ITU_R_601_4))
        } else {
            Issue.record("Expected BT.601 YCbCr matrix attachment")
        }
        if let m2020 = CVBufferCopyAttachment(buf2020, kCVImageBufferYCbCrMatrixKey, nil) {
            #expect(CFEqual(m2020, kCVImageBufferYCbCrMatrix_ITU_R_2020))
        } else {
            Issue.record("Expected BT.2020 YCbCr matrix attachment")
        }
        // Must preserve an existing attachment rather than overwriting it.
        ScaledVideoOutputMetadata.ensureYCbCrMatrixAttachment(on: buf601, colorMatrixIndex: 0)
        if let preserved = CVBufferCopyAttachment(buf601, kCVImageBufferYCbCrMatrixKey, nil) {
            #expect(CFEqual(preserved, kCVImageBufferYCbCrMatrix_ITU_R_601_4))
        } else {
            Issue.record("Expected existing BT.601 attachment to be preserved")
        }

        // 3) VideoFrameInterpolationPlan.prewarmPlan behavior
        let frame30Seek = MediaVideoFrame(pts: 10.0, duration: 1.0 / 30.0, pixelBuffer: buf709)
        if let warm60 = VideoFrameInterpolationPlan.prewarmPlan(
            for: frame30Seek, rate: .fps60, playbackRate: 1.0, supportsArbitraryPhases: true
        ) {
            #expect(abs(warm60.currentPTS - 10.0) < 1e-6)
            #expect(abs(warm60.previousPTS - (10.0 - 1.0 / 30.0)) < 1e-6)
            #expect(warm60.plan.allowsLowLatency)
            #expect(warm60.plan.phases == [0.5])
        } else {
            Issue.record("Expected prewarmPlan for 30 -> 60 fps")
        }

        let frame24Start = MediaVideoFrame(pts: 0.0, duration: 1.0 / 24.0, pixelBuffer: buf709)
        if let warm24 = VideoFrameInterpolationPlan.prewarmPlan(
            for: frame24Start, rate: .fps60, playbackRate: 1.0, supportsArbitraryPhases: true
        ) {
            #expect(abs(warm24.previousPTS - 0.0) < 1e-6)
            #expect(abs(warm24.currentPTS - 1.0 / 24.0) < 1e-6)
            #expect(!warm24.plan.allowsLowLatency)
            #expect(!warm24.plan.phases.isEmpty)
        } else {
            Issue.record("Expected prewarmPlan for 24 -> 60 fps")
        }

        let frame60 = MediaVideoFrame(pts: 2.0, duration: 1.0 / 60.0, pixelBuffer: buf709)
        #expect(VideoFrameInterpolationPlan.prewarmPlan(
            for: frame60, rate: .fps60, playbackRate: 1.0, supportsArbitraryPhases: true
        ) == nil)

        // 4) Fused rcasToNV12 Metal kernel numerical verification
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let width = 16
        let height = 16
        guard let srcBGRA = makeBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA, ioSurface: true),
              let dst420v = makeBuffer(
                width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, ioSurface: true
              ) else {
            Issue.record("Failed to allocate IOSurface test buffers for rcasToNV12")
            return
        }

        #expect(CVPixelBufferLockBaseAddress(srcBGRA, []) == kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(srcBGRA)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRow(srcBGRA)
            for row in 0..<height {
                let b: UInt8 = row < 4 ? 0 : (row < 8 ? 255 : 0)
                let g: UInt8 = row < 4 ? 0 : (row < 8 ? 255 : 0)
                let r: UInt8 = row < 4 ? 0 : 255
                for col in 0..<width {
                    let offset = row * stride + col * 4
                    base[offset] = b
                    base[offset + 1] = g
                    base[offset + 2] = r
                    base[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(srcBGRA, [])

        let metal = VideoEnhancementMetalContext.shared
        let resources = try metal.resources()
        let pipeline = try metal.pipeline(for: .rcasToNV12)
        for strength: Float in [0.0, 0.65] {
            guard let cmd = resources.commandQueue.makeCommandBuffer(),
                  let inTex = metal.makeTexture(
                    buffer: srcBGRA, format: .bgra8Unorm, width: width, height: height, plane: 0
                  ),
                  let outY = metal.makeTexture(
                    buffer: dst420v, format: .r8Unorm, width: width, height: height, plane: 0, usage: .shaderWrite
                  ),
                  let outCbCr = metal.makeTexture(
                    buffer: dst420v, format: .rg8Unorm, width: width / 2, height: height / 2,
                    plane: 1, usage: .shaderWrite
                  ),
                  let compute = cmd.makeComputeCommandEncoder() else {
                Issue.record("Failed to set up rcasToNV12 compute encoder")
                return
            }
            var params = VideoEnhancementRCASNV12Params(
                strength: strength, colorMatrix: 0, tapStep: 1, splitCompare: 0
            )
            compute.setComputePipelineState(pipeline)
            compute.setTexture(inTex.texture, index: 0)
            compute.setTexture(outY.texture, index: 1)
            compute.setTexture(outCbCr.texture, index: 2)
            compute.setTexture(inTex.texture, index: 3)
            compute.setBytes(&params, length: MemoryLayout<VideoEnhancementRCASNV12Params>.size, index: 0)
            VideoEnhancementMetalContext.dispatchThreads(
                encoder: compute, pipeline: pipeline, width: width / 2, height: height / 2
            )
            compute.endEncoding()
            let retained = [inTex.bridge, outY.bridge, outCbCr.bridge]
            let ok = await VideoEnhancementMetalContext.commitAndWait(cmd)
            withExtendedLifetime(retained) {}
            #expect(ok)

            #expect(CVPixelBufferLockBaseAddress(dst420v, .readOnly) == kCVReturnSuccess)
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(dst420v, 0)?.assumingMemoryBound(to: UInt8.self),
               let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(dst420v, 1)?.assumingMemoryBound(to: UInt8.self) {
                let yStride = CVPixelBufferGetBytesPerRowOfPlane(dst420v, 0)
                let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(dst420v, 1)
                // Black (row 1): Y=16, Cb=128, Cr=128
                #expect(abs(Int(yBase[1 * yStride + 4]) - 16) <= 1)
                #expect(abs(Int(cbcrBase[0 * cbcrStride + 4]) - 128) <= 1)
                #expect(abs(Int(cbcrBase[0 * cbcrStride + 5]) - 128) <= 1)
                // White (row 5): Y=235, Cb=128, Cr=128
                #expect(abs(Int(yBase[5 * yStride + 4]) - 235) <= 1)
                #expect(abs(Int(cbcrBase[2 * cbcrStride + 4]) - 128) <= 1)
                #expect(abs(Int(cbcrBase[2 * cbcrStride + 5]) - 128) <= 1)
                // BT.709 Pure Red (row 12): Y≈63, Cb≈102, Cr≈240
                #expect(abs(Int(yBase[12 * yStride + 4]) - 63) <= 2)
                #expect(abs(Int(cbcrBase[6 * cbcrStride + 4]) - 102) <= 2)
                #expect(abs(Int(cbcrBase[6 * cbcrStride + 5]) - 240) <= 2)
            }
            CVPixelBufferUnlockBaseAddress(dst420v, .readOnly)
        }

        // 5) Verify 12-tap shared-neighborhood rcasToNV12 matches rcasSharpen (evaluateRCAS)
        // on every pixel (including corners, edges, and 2x2 block boundaries) at strength = 0.65.
        guard let edgeSrcBGRA = makeBuffer(
            width: width, height: height, format: kCVPixelFormatType_32BGRA, ioSurface: true
        ), let refSharpBGRA = makeBuffer(
            width: width, height: height, format: kCVPixelFormatType_32BGRA, ioSurface: true
        ), let edgeDst420v = makeBuffer(
            width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, ioSurface: true
        ) else {
            Issue.record("Failed to allocate edge-comparison test buffers for rcasToNV12")
            return
        }

        #expect(CVPixelBufferLockBaseAddress(edgeSrcBGRA, []) == kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(edgeSrcBGRA)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRow(edgeSrcBGRA)
            for row in 0..<height {
                for col in 0..<width {
                    let bright = ((row / 2 + col / 2).isMultiple(of: 2)) || (row == 0 && col == 0)
                        || (row == height - 1 && col == width - 1) || (row == 3 && col == 7)
                    let offset = row * stride + col * 4
                    base[offset] = bright ? UInt8((col * 17) & 0xFF) : UInt8((row * 13) & 0x7F)
                    base[offset + 1] = bright ? 220 : 35
                    base[offset + 2] = bright ? UInt8(255 - ((row * 11) & 0x7F)) : UInt8((col * 9) & 0x7F)
                    base[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(edgeSrcBGRA, [])

        let sharpenPipeline = try metal.pipeline(for: .rcasSharpen)
        guard let edgeCmd = resources.commandQueue.makeCommandBuffer(),
              let edgeInTex = metal.makeTexture(
                buffer: edgeSrcBGRA, format: .bgra8Unorm, width: width, height: height, plane: 0
              ),
              let refOutTex = metal.makeTexture(
                buffer: refSharpBGRA, format: .bgra8Unorm, width: width, height: height,
                plane: 0, usage: .shaderWrite
              ),
              let edgeOutY = metal.makeTexture(
                buffer: edgeDst420v, format: .r8Unorm, width: width, height: height,
                plane: 0, usage: .shaderWrite
              ),
              let edgeOutCbCr = metal.makeTexture(
                buffer: edgeDst420v, format: .rg8Unorm, width: width / 2, height: height / 2,
                plane: 1, usage: .shaderWrite
              ),
              let encoder = edgeCmd.makeComputeCommandEncoder() else {
            Issue.record("Failed to set up rcasSharpen vs rcasToNV12 comparison encoder")
            return
        }
        var sharpParams = VideoEnhancementRCASParams(strength: 0.80, tapStep: 1, splitCompare: 0)
        encoder.setComputePipelineState(sharpenPipeline)
        encoder.setTexture(edgeInTex.texture, index: 0)
        encoder.setTexture(refOutTex.texture, index: 1)
        encoder.setTexture(edgeInTex.texture, index: 2)
        encoder.setBytes(&sharpParams, length: MemoryLayout<VideoEnhancementRCASParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: encoder, pipeline: sharpenPipeline, width: width, height: height
        )

        var nv12Params = VideoEnhancementRCASNV12Params(strength: 0.80, colorMatrix: 0, tapStep: 1, splitCompare: 0)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(edgeInTex.texture, index: 0)
        encoder.setTexture(edgeOutY.texture, index: 1)
        encoder.setTexture(edgeOutCbCr.texture, index: 2)
        encoder.setTexture(edgeInTex.texture, index: 3)
        encoder.setBytes(&nv12Params, length: MemoryLayout<VideoEnhancementRCASNV12Params>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: encoder, pipeline: pipeline, width: width / 2, height: height / 2
        )
        encoder.endEncoding()
        let edgeRetained = [edgeInTex.bridge, refOutTex.bridge, edgeOutY.bridge, edgeOutCbCr.bridge]
        let edgeOK = await VideoEnhancementMetalContext.commitAndWait(edgeCmd)
        withExtendedLifetime(edgeRetained) {}
        #expect(edgeOK)

        #expect(CVPixelBufferLockBaseAddress(refSharpBGRA, .readOnly) == kCVReturnSuccess)
        #expect(CVPixelBufferLockBaseAddress(edgeDst420v, .readOnly) == kCVReturnSuccess)
        if let refBase = CVPixelBufferGetBaseAddress(refSharpBGRA)?.assumingMemoryBound(to: UInt8.self),
           let yBase = CVPixelBufferGetBaseAddressOfPlane(edgeDst420v, 0)?.assumingMemoryBound(to: UInt8.self),
           let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(edgeDst420v, 1)?.assumingMemoryBound(to: UInt8.self) {
            let refStride = CVPixelBufferGetBytesPerRow(refSharpBGRA)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(edgeDst420v, 0)
            let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(edgeDst420v, 1)
            let yScale: Double = 219.0 / 255.0
            let yOffset: Double = 16.0 / 255.0
            let cScale: Double = 224.0 / 255.0
            let cOffset: Double = 128.0 / 255.0

            for row in 0..<height {
                for col in 0..<width {
                    let refOff = row * refStride + col * 4
                    let b = Double(refBase[refOff]) / 255.0
                    let g = Double(refBase[refOff + 1]) / 255.0
                    let r = Double(refBase[refOff + 2]) / 255.0
                    let yExpected = Int(((0.2126 * r + 0.7152 * g + 0.0722 * b) * yScale + yOffset) * 255.0 + 0.5)
                    let yActual = Int(yBase[row * yStride + col])
                    #expect(abs(yActual - yExpected) <= 1)
                }
            }
            for cy in 0..<(height / 2) {
                for cx in 0..<(width / 2) {
                    var sumR = 0.0
                    var sumG = 0.0
                    var sumB = 0.0
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let refOff = (cy * 2 + dy) * refStride + (cx * 2 + dx) * 4
                            sumB += Double(refBase[refOff]) / 255.0
                            sumG += Double(refBase[refOff + 1]) / 255.0
                            sumR += Double(refBase[refOff + 2]) / 255.0
                        }
                    }
                    let avgR = sumR * 0.25
                    let avgG = sumG * 0.25
                    let avgB = sumB * 0.25
                    let yAvg = 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB
                    let cbExpected = Int((min(max(((avgB - yAvg) / 1.8556) * cScale + cOffset, 0.0), 1.0)) * 255.0 + 0.5)
                    let crExpected = Int((min(max(((avgR - yAvg) / 1.5748) * cScale + cOffset, 0.0), 1.0)) * 255.0 + 0.5)
                    let cbActual = Int(cbcrBase[cy * cbcrStride + cx * 2])
                    let crActual = Int(cbcrBase[cy * cbcrStride + cx * 2 + 1])
                    #expect(abs(cbActual - cbExpected) <= 2)
                    #expect(abs(crActual - crExpected) <= 2)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(edgeDst420v, .readOnly)
        CVPixelBufferUnlockBaseAddress(refSharpBGRA, .readOnly)
    }

    @Test("VTInterpolationFormatNegotiation selects zero-copy 420v or falls back cleanly to 32BGRA / 420v for FRC")
    func vtInterpolationFormatNegotiationSelectsCompatiblePairs() {
        let nv12Video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let nv12Full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let bgra = kCVPixelFormatType_32BGRA

        // 1) Preserves zero-copy 420v -> 420v when supported
        let direct420v = VTInterpolationFormatNegotiation.selectFormatPair(
            inputFormat: nv12Video,
            nativeSupported: [bgra, nv12Video],
            sourceAttributeFormats: [bgra, nv12Video],
            destinationAttributeFormats: [bgra, nv12Video]
        )
        #expect(direct420v == VTInterpolationFormatNegotiation.FormatPair(source: nv12Video, destination: nv12Video))

        // 2) Falls back to 32BGRA -> 32BGRA when FRC only supports 32BGRA
        let bgraOnly = VTInterpolationFormatNegotiation.selectFormatPair(
            inputFormat: nv12Video,
            nativeSupported: [bgra],
            sourceAttributeFormats: [bgra],
            destinationAttributeFormats: [bgra]
        )
        #expect(bgraOnly == VTInterpolationFormatNegotiation.FormatPair(source: bgra, destination: bgra))

        // 3) Converts 420f -> 420v when FRC only supports 420v
        let fullToVideo = VTInterpolationFormatNegotiation.selectFormatPair(
            inputFormat: nv12Full,
            nativeSupported: [nv12Video],
            sourceAttributeFormats: [nv12Video],
            destinationAttributeFormats: [nv12Video]
        )
        #expect(fullToVideo == VTInterpolationFormatNegotiation.FormatPair(source: nv12Video, destination: nv12Video))

        // 4) Converts 420f -> 32BGRA when FRC only supports 32BGRA
        let fullToBGRA = VTInterpolationFormatNegotiation.selectFormatPair(
            inputFormat: nv12Full,
            nativeSupported: [bgra],
            sourceAttributeFormats: [],
            destinationAttributeFormats: []
        )
        #expect(fullToBGRA == VTInterpolationFormatNegotiation.FormatPair(source: bgra, destination: bgra))

        // 5) Supports asymmetric source/destination attributes when destination differs from source
        let asymmetric = VTInterpolationFormatNegotiation.selectFormatPair(
            inputFormat: nv12Video,
            nativeSupported: [nv12Video],
            sourceAttributeFormats: [nv12Video],
            destinationAttributeFormats: [bgra]
        )
        #expect(asymmetric == VTInterpolationFormatNegotiation.FormatPair(source: nv12Video, destination: bgra))

        // 6) Rejects unstageable 32BGRA input when FRC only supports NV12
        let unstageable = VTInterpolationFormatNegotiation.selectFormatPair(
            inputFormat: bgra,
            nativeSupported: [nv12Video],
            sourceAttributeFormats: [nv12Video],
            destinationAttributeFormats: [nv12Video]
        )
        #expect(unstageable == nil)

        // 7) Staging capability matrix
        #expect(VTInterpolationFormatNegotiation.canStage(inputFormat: nv12Video, targetFormat: nv12Video))
        #expect(VTInterpolationFormatNegotiation.canStage(inputFormat: nv12Video, targetFormat: bgra))
        #expect(VTInterpolationFormatNegotiation.canStage(inputFormat: nv12Full, targetFormat: nv12Video))
        #expect(VTInterpolationFormatNegotiation.canStage(inputFormat: nv12Full, targetFormat: bgra))
        #expect(VTInterpolationFormatNegotiation.canStage(inputFormat: bgra, targetFormat: bgra))
        #expect(!VTInterpolationFormatNegotiation.canStage(inputFormat: bgra, targetFormat: nv12Video))
        #expect(!VTInterpolationFormatNegotiation.canStage(inputFormat: bgra, targetFormat: nv12Full))
    }

    @Test("LLFI-only consolidation, widened 30.x/VFR dyadic headroom, preference migration, and shader-only config diff")
    func llfiConsolidationWidenedHeadroomAndMigration() {
        // Legacy persisted FPS values migrate cleanly to the nearest hardware-fast LLFI mode.
        #expect(VideoInterpolationRate(persistedValue: 0) == .doubleRate)
        #expect(VideoInterpolationRate(persistedValue: 48) == .fps60)
        #expect(VideoInterpolationRate(persistedValue: 60) == .fps60)
        #expect(VideoInterpolationRate(persistedValue: 72) == .fps60)
        #expect(VideoInterpolationRate(persistedValue: 90) == .fps120)
        #expect(VideoInterpolationRate(persistedValue: 100) == .fps120)
        #expect(VideoInterpolationRate(persistedValue: 120) == .fps120)

        // Legacy VideoToolbox ML SR preference migrates cleanly to MetalFX Spatial.
        #expect(VideoSuperResolutionMode(persistedValue: "off") == .off)
        #expect(VideoSuperResolutionMode(persistedValue: "videotoolbox_ml") == .metalFXSpatial)
        #expect(VideoSuperResolutionMode(persistedValue: "videoToolboxML") == .metalFXSpatial)
        #expect(VideoSuperResolutionMode(persistedValue: "metalfx_spatial") == .metalFXSpatial)

        // Default planner is locked to dyadic LLFI (2x / 4x) with widened headroom for 30.x / VFR streams.
        #expect(!VideoFrameInterpolationPlan.supportsArbitraryPhases)
        for sourceFPS in [24.0, 25.0, 30.0, 30.6, 31.0, 32.5] {
            let interval = 1.0 / sourceFPS
            let outcome = VideoFrameInterpolationPlan.plan(
                previousPTS: 1.0,
                currentPTS: 1.0 + interval,
                interval: interval,
                cadenceInterval: interval,
                isCadenceStable: true,
                gridNextPTS: nil,
                rate: .fps60
            )
            guard case let .plan(plan) = outcome else {
                Issue.record("Expected 2x LLFI plan for \(sourceFPS) fps -> .fps60, got \(outcome)")
                continue
            }
            #expect(plan.allowsLowLatency)
            #expect(plan.phases == [0.5])
            #expect(plan.emitsOriginal)
            #expect(plan.nextGridPTS == nil)
        }

        // Under .fps120: <= 32.5 fps uses 4x LLFI, 35-65 fps uses 2x LLFI.
        for sourceFPS in [24.0, 30.0, 32.5] {
            let interval = 1.0 / sourceFPS
            guard case let .plan(plan) = VideoFrameInterpolationPlan.plan(
                previousPTS: 1.0,
                currentPTS: 1.0 + interval,
                interval: interval,
                cadenceInterval: interval,
                rate: .fps120
            ) else {
                Issue.record("Expected 4x LLFI plan for \(sourceFPS) fps -> .fps120")
                continue
            }
            #expect(plan.allowsLowLatency)
            #expect(plan.phases == [0.25, 0.5, 0.75])
        }
        for sourceFPS in [35.0, 48.0, 60.0, 65.0] {
            let interval = 1.0 / sourceFPS
            guard case let .plan(plan) = VideoFrameInterpolationPlan.plan(
                previousPTS: 1.0,
                currentPTS: 1.0 + interval,
                interval: interval,
                cadenceInterval: interval,
                rate: .fps120
            ) else {
                Issue.record("Expected 2x LLFI plan for \(sourceFPS) fps -> .fps120")
                continue
            }
            #expect(plan.allowsLowLatency)
            #expect(plan.phases == [0.5])
        }

        // Scale-aware RCAS tap step selection.
        #expect(MetalFXSuperResolutionBackend.rcasTapStep(
            inputWidth: 1920, inputHeight: 1080, outputWidth: 2560, outputHeight: 1440
        ) == 1)
        #expect(MetalFXSuperResolutionBackend.rcasTapStep(
            inputWidth: 1280, inputHeight: 720, outputWidth: 1920, outputHeight: 1080
        ) == 1)
        #expect(MetalFXSuperResolutionBackend.rcasTapStep(
            inputWidth: 1920, inputHeight: 1080, outputWidth: 3840, outputHeight: 2160
        ) == 2)
        #expect(MetalFXSuperResolutionBackend.rcasTapStep(
            inputWidth: 1280, inputHeight: 720, outputWidth: 2560, outputHeight: 1440
        ) == 2)

        // Shader-uniform-only config diff avoids pipeline flushes when toggling sharpness or split compare.
        var base = VideoEnhancementConfiguration(superResolutionMode: .metalFXSpatial)
        var toggledSplit = base
        toggledSplit.superResolutionSplitCompare = true
        toggledSplit.superResolutionSharpness = .strong
        #expect(toggledSplit.isShaderUniformOnlyChange(from: base))
        base.superResolutionTargetResolution = .p2160
        #expect(!toggledSplit.isShaderUniformOnlyChange(from: base))
    }

    @Test("RCAS enhances edge contrast without [mn5, mx5] erasure, matches tapStep=2 parity, and renders split-screen compare")
    nonisolated func rcasRealSharpeningAdaptiveTapStepAndSplitCompare() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        func makeIOSurfaceBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &buffer
            )
            return status == kCVReturnSuccess ? buffer : nil
        }

        let width = 32
        let height = 16
        guard let stepSrc = makeIOSurfaceBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA),
              let origDark = makeIOSurfaceBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA),
              let sharpBGRA = makeIOSurfaceBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA),
              let sharpNV12 = makeIOSurfaceBuffer(
                width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
              ),
              let splitNV12 = makeIOSurfaceBuffer(
                width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
              ) else {
            Issue.record("Failed to allocate IOSurface test buffers for RCAS edge/split tests")
            return
        }

        // Fill a vertical step edge (left half gray=51 ~0.20, right half gray=204 ~0.80).
        #expect(CVPixelBufferLockBaseAddress(stepSrc, []) == kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(stepSrc)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRow(stepSrc)
            for row in 0..<height {
                for col in 0..<width {
                    let v: UInt8 = col < (width / 2) ? 51 : 204
                    let off = row * stride + col * 4
                    base[off] = v
                    base[off + 1] = v
                    base[off + 2] = v
                    base[off + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(stepSrc, [])

        // Uniform dark original (gray=30) for split-screen A/B comparison test.
        #expect(CVPixelBufferLockBaseAddress(origDark, []) == kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(origDark)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRow(origDark)
            for row in 0..<height {
                for col in 0..<width {
                    let off = row * stride + col * 4
                    base[off] = 30
                    base[off + 1] = 30
                    base[off + 2] = 30
                    base[off + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(origDark, [])

        let metal = VideoEnhancementMetalContext.shared
        let resources = try metal.resources()
        let rcasPipeline = try metal.pipeline(for: .rcasSharpen)
        let rcasNV12Pipeline = try metal.pipeline(for: .rcasToNV12)

        guard let cmd = resources.commandQueue.makeCommandBuffer(),
              let stepTex = metal.makeTexture(
                buffer: stepSrc, format: .bgra8Unorm, width: width, height: height, plane: 0
              ),
              let origTex = metal.makeTexture(
                buffer: origDark, format: .bgra8Unorm, width: width, height: height, plane: 0
              ),
              let sharpBGRATex = metal.makeTexture(
                buffer: sharpBGRA, format: .bgra8Unorm, width: width, height: height,
                plane: 0, usage: .shaderWrite
              ),
              let sharpYTex = metal.makeTexture(
                buffer: sharpNV12, format: .r8Unorm, width: width, height: height,
                plane: 0, usage: .shaderWrite
              ),
              let sharpCbCrTex = metal.makeTexture(
                buffer: sharpNV12, format: .rg8Unorm, width: width / 2, height: height / 2,
                plane: 1, usage: .shaderWrite
              ),
              let splitYTex = metal.makeTexture(
                buffer: splitNV12, format: .r8Unorm, width: width, height: height,
                plane: 0, usage: .shaderWrite
              ),
              let splitCbCrTex = metal.makeTexture(
                buffer: splitNV12, format: .rg8Unorm, width: width / 2, height: height / 2,
                plane: 1, usage: .shaderWrite
              ),
              let enc = cmd.makeComputeCommandEncoder() else {
            Issue.record("Failed to create Metal resources for RCAS edge/split test")
            return
        }

        // 1) Verify tapStep=2 rcasSharpen & rcasToNV12 both sharpen local edge extrema beyond [51, 204].
        var pBGRA = VideoEnhancementRCASParams(strength: 0.80, tapStep: 2, splitCompare: 0)
        enc.setComputePipelineState(rcasPipeline)
        enc.setTexture(stepTex.texture, index: 0)
        enc.setTexture(sharpBGRATex.texture, index: 1)
        enc.setTexture(stepTex.texture, index: 2)
        enc.setBytes(&pBGRA, length: MemoryLayout<VideoEnhancementRCASParams>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(encoder: enc, pipeline: rcasPipeline, width: width, height: height)

        var pNV12 = VideoEnhancementRCASNV12Params(strength: 0.80, colorMatrix: 0, tapStep: 2, splitCompare: 0)
        enc.setComputePipelineState(rcasNV12Pipeline)
        enc.setTexture(stepTex.texture, index: 0)
        enc.setTexture(sharpYTex.texture, index: 1)
        enc.setTexture(sharpCbCrTex.texture, index: 2)
        enc.setTexture(stepTex.texture, index: 3)
        enc.setBytes(&pNV12, length: MemoryLayout<VideoEnhancementRCASNV12Params>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: enc, pipeline: rcasNV12Pipeline, width: width / 2, height: height / 2
        )

        // 2) Verify split-screen compare renders origDark on left, stepSrc (204) on right, bright divider at center.
        var pSplit = VideoEnhancementRCASNV12Params(strength: 0.0, colorMatrix: 0, tapStep: 1, splitCompare: 1)
        enc.setComputePipelineState(rcasNV12Pipeline)
        enc.setTexture(stepTex.texture, index: 0)
        enc.setTexture(splitYTex.texture, index: 1)
        enc.setTexture(splitCbCrTex.texture, index: 2)
        enc.setTexture(origTex.texture, index: 3)
        enc.setBytes(&pSplit, length: MemoryLayout<VideoEnhancementRCASNV12Params>.size, index: 0)
        VideoEnhancementMetalContext.dispatchThreads(
            encoder: enc, pipeline: rcasNV12Pipeline, width: width / 2, height: height / 2
        )
        enc.endEncoding()

        let retained = [
            stepTex.bridge, origTex.bridge, sharpBGRATex.bridge,
            sharpYTex.bridge, sharpCbCrTex.bridge, splitYTex.bridge, splitCbCrTex.bridge,
        ]
        let ok = await VideoEnhancementMetalContext.commitAndWait(cmd)
        withExtendedLifetime(retained) {}
        #expect(ok)

        #expect(CVPixelBufferLockBaseAddress(sharpBGRA, .readOnly) == kCVReturnSuccess)
        #expect(CVPixelBufferLockBaseAddress(sharpNV12, .readOnly) == kCVReturnSuccess)
        #expect(CVPixelBufferLockBaseAddress(splitNV12, .readOnly) == kCVReturnSuccess)
        if let bgraBase = CVPixelBufferGetBaseAddress(sharpBGRA)?.assumingMemoryBound(to: UInt8.self),
           let ySharpBase = CVPixelBufferGetBaseAddressOfPlane(sharpNV12, 0)?.assumingMemoryBound(to: UInt8.self),
           let ySplitBase = CVPixelBufferGetBaseAddressOfPlane(splitNV12, 0)?.assumingMemoryBound(to: UInt8.self) {
            let bgraStride = CVPixelBufferGetBytesPerRow(sharpBGRA)
            let ySharpStride = CVPixelBufferGetBytesPerRowOfPlane(sharpNV12, 0)
            let ySplitStride = CVPixelBufferGetBytesPerRowOfPlane(splitNV12, 0)

            let row = height / 2
            let darkEdgeCol = width / 2 - 1 // input 51, neighbor +2 is 204
            let brightEdgeCol = width / 2   // input 204, neighbor -2 is 51
            let darkOut = Int(bgraBase[row * bgraStride + darkEdgeCol * 4])
            let brightOut = Int(bgraBase[row * bgraStride + brightEdgeCol * 4])
            // Must sharpen strictly past [51, 204] instead of being clamped away!
            #expect(darkOut < 46, "Expected RCAS dark-edge darkening < 46, got \(darkOut)")
            #expect(brightOut > 209, "Expected RCAS bright-edge boost > 209, got \(brightOut)")

            // Verify tapStep=2 rcasToNV12 matches rcasSharpen on those edge pixels.
            let yScale = 219.0 / 255.0
            let yOffset = 16.0 / 255.0
            let expectedDarkY = Int((Double(darkOut) / 255.0 * yScale + yOffset) * 255.0 + 0.5)
            let expectedBrightY = Int((Double(brightOut) / 255.0 * yScale + yOffset) * 255.0 + 0.5)
            #expect(abs(Int(ySharpBase[row * ySharpStride + darkEdgeCol]) - expectedDarkY) <= 1)
            #expect(abs(Int(ySharpBase[row * ySharpStride + brightEdgeCol]) - expectedBrightY) <= 1)

            // Verify split-screen compare: left side = origDark (gray 30 -> Y≈42),
            // right side = stepSrc (gray 204 -> Y≈191), center = bright white divider (>215).
            let leftY = Int(ySplitBase[row * ySplitStride + 4])
            let centerY = Int(ySplitBase[row * ySplitStride + (width / 2)])
            let rightY = Int(ySplitBase[row * ySplitStride + (width - 4)])
            #expect(abs(leftY - 42) <= 2, "Expected left split original Y≈42, got \(leftY)")
            #expect(abs(rightY - 191) <= 2, "Expected right split enhanced Y≈191, got \(rightY)")
            #expect(centerY > 215, "Expected bright split divider Y>215, got \(centerY)")
        }
        CVPixelBufferUnlockBaseAddress(splitNV12, .readOnly)
        CVPixelBufferUnlockBaseAddress(sharpNV12, .readOnly)
        CVPixelBufferUnlockBaseAddress(sharpBGRA, .readOnly)
    }

    @Test("SampleBufferVideoRenderer hold view and PlayerContainerView recovery cover stay transparent for ambient glow")
    @MainActor
    func rendererHoldViewAndRecoveryCoverPreserveAmbientTransparency() {
        let renderer = SampleBufferVideoRenderer()
        defer { renderer.invalidate() }

        let hostView = renderer.hostViewController.view!
        #expect(hostView.backgroundColor == .clear)
        #expect(!hostView.isOpaque)

        let displayView = hostView.subviews.first { $0 is SampleBufferDisplayView } as? SampleBufferDisplayView
        let holdView = hostView.subviews.first { $0 is PresentationImageHoldView } as? PresentationImageHoldView
        #expect(displayView != nil)
        #expect(holdView != nil)
        if let displayView {
            #expect(displayView.backgroundColor == .clear)
            #expect(!displayView.isOpaque)
            #expect(displayView.sampleBufferLayer.backgroundColor?.alpha == 0)
        }
        if let holdView {
            #expect(holdView.backgroundColor == .clear)
            #expect(!holdView.isOpaque)
            #expect(holdView.sampleBufferLayer.backgroundColor?.alpha == 0)
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 225))
        window.isHidden = false
        let container = PlayerContainerView(frame: window.bounds)
        window.addSubview(container)
        container.attach(hostedVC: renderer.hostViewController, generation: 1)
        container.syncHostedSurfaceLayoutIfNeeded()
        defer {
            container.attach(hostedVC: nil, generation: -1)
            container.removeFromSuperview()
            window.isHidden = true
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        let mount = container.installRecoveryCover(image, identity: 1)
        #expect(mount == .mounted)
        let cover = container.subviews.compactMap { $0 as? UIImageView }.first
        #expect(cover != nil)
        if let cover {
            #expect(cover.backgroundColor == .clear)
            #expect(!cover.isOpaque)
        }
    }
}
