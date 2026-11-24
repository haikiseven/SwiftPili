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
}
