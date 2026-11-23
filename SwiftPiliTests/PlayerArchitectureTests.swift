import CoreVideo
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

    @Test("VideoSuperResolutionTargetResolution.degradedForPerformance preserves 1440p and steps down >1440p")
    func targetResolutionDegradedForPerformancePreserves1440p() {
        #expect(VideoSuperResolutionTargetResolution.p2160.degradedForPerformance == .p1440)
        #expect(VideoSuperResolutionTargetResolution.custom(1800).degradedForPerformance == .p1440)
        #expect(VideoSuperResolutionTargetResolution.p1440.degradedForPerformance == .p1440)
        #expect(VideoSuperResolutionTargetResolution.p1080.degradedForPerformance == .p1080)
        #expect(VideoSuperResolutionTargetResolution.auto.degradedForPerformance == .auto)

        // Under `.fair` thermal (`reducedScale`), 1440p on a 1080p stream must keep upscaling
        // instead of collapsing to 1080p and self-disabling.
        var requested = VideoEnhancementConfiguration()
        requested.superResolutionMode = .metalFXSpatial
        requested.superResolutionTargetResolution = .p1440
        let degraded = VideoEnhancementDegradationLevel.reducedScale.apply(to: requested, metalFXAvailable: true)
        #expect(degraded.superResolutionTargetResolution == .p1440)
        let outcome = VideoSuperResolutionTargetResolution.resolveMetalFXOutput(
            inputWidth: 1920,
            inputHeight: 1080,
            targetShortEdge: degraded.superResolutionTargetResolution.shortEdge ?? 0
        )
        #expect(outcome == .output(VideoSuperResolutionDimensions(width: 2560, height: 1440)))
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
