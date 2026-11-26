import Foundation
import Testing
@testable import SwiftPili

@Suite("Track2FrameInterpolationBackend")
@MainActor
struct Track2FrameInterpolationBackendTests {
    @Test("VideoFrameInterpolationBackend raw values, persistedValue parsing, and UserDefaults persistence round-trip")
    func backendPersistenceRoundTrip() {
        #expect(VideoFrameInterpolationBackend.allCases == [.auto, .videoToolbox, .visionOpticalFlow])
        #expect(VideoFrameInterpolationBackend.auto.rawValue == "auto")
        #expect(VideoFrameInterpolationBackend.videoToolbox.rawValue == "videotoolbox")
        #expect(VideoFrameInterpolationBackend.visionOpticalFlow.rawValue == "vision_optical_flow")

        #expect(VideoFrameInterpolationBackend(persistedValue: "auto") == .auto)
        #expect(VideoFrameInterpolationBackend(persistedValue: "videotoolbox") == .videoToolbox)
        #expect(VideoFrameInterpolationBackend(persistedValue: "videoToolbox") == .videoToolbox)
        #expect(VideoFrameInterpolationBackend(persistedValue: "vision_optical_flow") == .visionOpticalFlow)
        #expect(VideoFrameInterpolationBackend(persistedValue: "visionOpticalFlow") == .visionOpticalFlow)
        #expect(VideoFrameInterpolationBackend(persistedValue: "vision") == .visionOpticalFlow)
        #expect(VideoFrameInterpolationBackend(persistedValue: "unknown_engine") == nil)

        let key = VideoEnhancementPreferences.frameInterpolationBackendKey
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            InterpolationBackendPreferencesStore.shared.reloadFromDefaults()
        }

        defaults.removeObject(forKey: key)
        #expect(VideoEnhancementPreferences.frameInterpolationBackend == .auto)

        for backend in VideoFrameInterpolationBackend.allCases {
            VideoEnhancementPreferences.frameInterpolationBackend = backend
            #expect(VideoEnhancementPreferences.frameInterpolationBackend == backend)
            #expect(defaults.string(forKey: key) == backend.rawValue)
        }

        defaults.set("corrupt_backend_value", forKey: key)
        #expect(VideoEnhancementPreferences.frameInterpolationBackend == .auto)
    }

    @Test("VideoEnhancementConfiguration Codable round-trip and backward-compatible default to .auto when key absent")
    func configurationCodableBackwardCompatibility() throws {
        let legacyJSON = """
        {
            "superResolutionMode": "metalFXSpatial",
            "frameInterpolationEnabled": true,
            "interpolationRate": 60,
            "superResolutionScale": 2,
            "superResolutionTargetResolution": 1440,
            "superResolutionSharpness": "strong",
            "superResolutionSplitCompare": true,
            "maxInputResolution": "1440p",
            "isLiveStream": false,
            "limitToScreenResolution": false
        }
        """
        let decodedLegacy = try JSONDecoder().decode(
            VideoEnhancementConfiguration.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decodedLegacy.superResolutionMode == .metalFXSpatial)
        #expect(decodedLegacy.frameInterpolationEnabled)
        #expect(decodedLegacy.frameInterpolationBackend == .auto)
        #expect(decodedLegacy.interpolationRate == .fps60)
        #expect(decodedLegacy.superResolutionTargetResolution == .p1440)
        #expect(decodedLegacy.superResolutionSharpness == .strong)
        #expect(decodedLegacy.superResolutionSplitCompare)
        #expect(decodedLegacy.maxInputResolution == .p1440)
        #expect(!decodedLegacy.limitToScreenResolution)

        let unknownBackendJSON = """
        {
            "frameInterpolationEnabled": true,
            "frameInterpolationBackend": "future_neural_v9"
        }
        """
        let decodedUnknown = try JSONDecoder().decode(
            VideoEnhancementConfiguration.self,
            from: Data(unknownBackendJSON.utf8)
        )
        #expect(decodedUnknown.frameInterpolationEnabled)
        #expect(decodedUnknown.frameInterpolationBackend == .auto)

        for backend in VideoFrameInterpolationBackend.allCases {
            let config = VideoEnhancementConfiguration(
                superResolutionMode: .metalFXSpatial,
                frameInterpolationEnabled: true,
                frameInterpolationBackend: backend,
                interpolationRate: .fps120,
                superResolutionTargetResolution: .custom(1620),
                superResolutionSharpness: .light
            )
            let data = try JSONEncoder().encode(config)
            let roundTripped = try JSONDecoder().decode(VideoEnhancementConfiguration.self, from: data)
            #expect(roundTripped == config)
            #expect(roundTripped.frameInterpolationBackend == backend)
        }
    }

    @Test("Backend resolution and selectable options handle iOS 26 VT supported vs pre-iOS-26 graceful fallback")
    func backendResolutionAndCapabilityMatrix() {
        // iOS 26+ hardware where VTFrameProcessor LLFI is supported.
        #expect(VideoFrameInterpolationBackend.auto.resolved(vtSupported: true) == .videoToolbox)
        #expect(VideoFrameInterpolationBackend.videoToolbox.resolved(vtSupported: true) == .videoToolbox)
        #expect(VideoFrameInterpolationBackend.visionOpticalFlow.resolved(vtSupported: true) == .visionOpticalFlow)
        #expect(
            VideoEnhancementConfiguration.selectableFrameInterpolationBackends(vtSupported: true)
                == [.auto, .videoToolbox, .visionOpticalFlow]
        )
        #expect(VideoFrameInterpolationBackend.videoToolbox.isSelectable(vtSupported: true))
        #expect(VideoFrameInterpolationBackend.visionOpticalFlow.isSelectable(vtSupported: true))

        // Pre-iOS-26 / unsupported hardware: .auto and .videoToolbox gracefully fall back to .visionOpticalFlow.
        #expect(VideoFrameInterpolationBackend.auto.resolved(vtSupported: false) == .visionOpticalFlow)
        #expect(VideoFrameInterpolationBackend.videoToolbox.resolved(vtSupported: false) == .visionOpticalFlow)
        #expect(VideoFrameInterpolationBackend.visionOpticalFlow.resolved(vtSupported: false) == .visionOpticalFlow)
        #expect(
            VideoEnhancementConfiguration.selectableFrameInterpolationBackends(vtSupported: false)
                == [.auto, .visionOpticalFlow]
        )
        #expect(!VideoFrameInterpolationBackend.videoToolbox.isSelectable(vtSupported: false))
        #expect(VideoFrameInterpolationBackend.auto.isSelectable(vtSupported: false))
        #expect(VideoFrameInterpolationBackend.visionOpticalFlow.isSelectable(vtSupported: false))

        let vtCapabilities = VideoEnhancementCapabilities(
            metalFXSpatial: .supported,
            frameInterpolation: .supported
        )
        #expect(vtCapabilities.supportsVideoToolboxFrameInterpolation)
        #expect(vtCapabilities.selectableFrameInterpolationBackends == [.auto, .videoToolbox, .visionOpticalFlow])

        let visionCapabilities = VideoEnhancementCapabilities(
            metalFXSpatial: .supported,
            frameInterpolation: .supportedVisionFallback
        )
        #expect(!visionCapabilities.supportsVideoToolboxFrameInterpolation)
        #expect(visionCapabilities.selectableFrameInterpolationBackends == [.auto, .visionOpticalFlow])

        var config = VideoEnhancementConfiguration(
            frameInterpolationEnabled: true,
            frameInterpolationBackend: .videoToolbox
        )
        #expect(config.resolvedFrameInterpolationBackend(vtSupported: true) == .videoToolbox)
        #expect(config.resolvedFrameInterpolationBackend(vtSupported: false) == .visionOpticalFlow)

        config.frameInterpolationBackend = .visionOpticalFlow
        #expect(config.resolvedFrameInterpolationBackend(vtSupported: true) == .visionOpticalFlow)
        #expect(config.resolvedFrameInterpolationBackend(vtSupported: false) == .visionOpticalFlow)
    }

    @Test("Configuration diffing distinguishes shader-only, backend alias, live hot-swap, and full reset")
    func configurationLiveHotSwapDiffing() {
        let base = VideoEnhancementConfiguration(
            superResolutionMode: .metalFXSpatial,
            frameInterpolationEnabled: true,
            frameInterpolationBackend: .auto,
            interpolationRate: .fps60
        )

        // Identical config -> unchanged.
        #expect(base.changeKind(from: base, vtSupported: true) == .unchanged)

        // Sharpness / split compare -> shaderUniformOnly.
        var shaderOnly = base
        shaderOnly.superResolutionSharpness = .strong
        shaderOnly.superResolutionSplitCompare = true
        #expect(shaderOnly.isShaderUniformOnlyChange(from: base))
        #expect(!shaderOnly.isFrameInterpolationBackendOnlyChange(from: base))
        #expect(shaderOnly.changeKind(from: base, vtSupported: true) == .shaderUniformOnly)

        // Switching Auto -> iOS 26 System on iOS 26 resolves to the same VT backend -> alias only (zero reset).
        var explicitVT = base
        explicitVT.frameInterpolationBackend = .videoToolbox
        #expect(!explicitVT.isShaderUniformOnlyChange(from: base))
        #expect(explicitVT.isFrameInterpolationBackendOnlyChange(from: base))
        #expect(explicitVT.changeKind(from: base, vtSupported: true) == .interpolationBackendAliasOnly)

        // Switching Auto (VT) -> Optical Flow on iOS 26 -> live hot-swap retiring only VT!
        var explicitVision = base
        explicitVision.frameInterpolationBackend = .visionOpticalFlow
        #expect(!explicitVision.isShaderUniformOnlyChange(from: base))
        #expect(explicitVision.isFrameInterpolationBackendOnlyChange(from: base))
        #expect(
            explicitVision.changeKind(from: base, vtSupported: true)
                == .interpolationBackendHotSwap(outgoing: .videoToolbox, incoming: .visionOpticalFlow)
        )

        // Switching Optical Flow -> iOS 26 System on iOS 26 -> live hot-swap retiring only Vision!
        #expect(
            explicitVT.changeKind(from: explicitVision, vtSupported: true)
                == .interpolationBackendHotSwap(outgoing: .visionOpticalFlow, incoming: .videoToolbox)
        )

        // On pre-iOS-26 hardware (vtSupported == false), Auto / VT / Vision all resolve to Vision -> alias only.
        #expect(explicitVision.changeKind(from: base, vtSupported: false) == .interpolationBackendAliasOnly)
        #expect(explicitVT.changeKind(from: explicitVision, vtSupported: false) == .interpolationBackendAliasOnly)

        // Changing backend while frame interpolation is disabled must NOT flush active MetalFX SR.
        let srOnlyAuto = VideoEnhancementConfiguration(
            superResolutionMode: .metalFXSpatial,
            frameInterpolationEnabled: false,
            frameInterpolationBackend: .auto
        )
        var srOnlyVision = srOnlyAuto
        srOnlyVision.frameInterpolationBackend = .visionOpticalFlow
        #expect(srOnlyVision.changeKind(from: srOnlyAuto, vtSupported: true) == .interpolationBackendAliasOnly)

        // Changing backend together with interpolationRate or toggling FI -> fullPipelineReset.
        var backendAndRate = explicitVision
        backendAndRate.interpolationRate = .fps120
        #expect(backendAndRate.changeKind(from: base, vtSupported: true) == .fullPipelineReset)

        var toggledOff = explicitVision
        toggledOff.frameInterpolationEnabled = false
        #expect(toggledOff.changeKind(from: base, vtSupported: true) == .fullPipelineReset)
    }

    @Test("Backend-aware interpolation planner enables arbitrary CFR phases for Vision Flow even on iOS 26+")
    func backendAwareArbitraryPhasePlanning() {
        #expect(!VideoFrameInterpolationPlan.supportsArbitraryPhases(for: .videoToolbox, vtSupported: true))
        #expect(!VideoFrameInterpolationPlan.supportsArbitraryPhases(for: .auto, vtSupported: true))
        #expect(VideoFrameInterpolationPlan.supportsArbitraryPhases(for: .visionOpticalFlow, vtSupported: true))
        #expect(VideoFrameInterpolationPlan.supportsArbitraryPhases(for: .auto, vtSupported: false))
        #expect(VideoFrameInterpolationPlan.supportsArbitraryPhases(for: .videoToolbox, vtSupported: false))

        let interval24 = 1.0 / 24.0

        // Under VT System on iOS 26: 24 fps targeting 60 fps stays on dyadic 2x LLFI ([0.5]).
        let vtOutcome = VideoFrameInterpolationPlan.plan(
            previousPTS: 1.0,
            currentPTS: 1.0 + interval24,
            interval: interval24,
            cadenceInterval: interval24,
            isCadenceStable: true,
            gridNextPTS: nil,
            rate: .fps60,
            playbackRate: 1.0,
            supportsArbitraryPhases: VideoFrameInterpolationPlan.supportsArbitraryPhases(
                for: .videoToolbox,
                vtSupported: true
            )
        )
        guard case let .plan(vtPlan) = vtOutcome else {
            Issue.record("Expected dyadic LLFI plan for 24 fps -> 60 fps under VT System")
            return
        }
        #expect(vtPlan.allowsLowLatency)
        #expect(vtPlan.phases == [0.5])
        #expect(!vtPlan.isCFRResampling)

        // Under explicit Vision Optical Flow on iOS 26: 24 fps targeting 60 fps uses arbitrary-phase CFR grid.
        let visionOutcome = VideoFrameInterpolationPlan.plan(
            previousPTS: 1.0,
            currentPTS: 1.0 + interval24,
            interval: interval24,
            cadenceInterval: interval24,
            isCadenceStable: true,
            gridNextPTS: nil,
            rate: .fps60,
            playbackRate: 1.0,
            supportsArbitraryPhases: VideoFrameInterpolationPlan.supportsArbitraryPhases(
                for: .visionOpticalFlow,
                vtSupported: true
            )
        )
        guard case let .plan(visionPlan) = visionOutcome else {
            Issue.record("Expected CFR grid plan for 24 fps -> 60 fps under Vision Flow")
            return
        }
        #expect(!visionPlan.allowsLowLatency)
        #expect(visionPlan.isCFRResampling)
        #expect(abs(visionPlan.targetOutputFPS - 60.0) < 1e-6)
    }

    @Test("Telemetry and PlayerStatsOverlay format active FRC backend labels accurately")
    func telemetryAndStatsOverlayFormatting() {
        #expect(VideoFrameInterpolationBackend.videoToolbox.telemetryLabel == "VT System")
        #expect(VideoFrameInterpolationBackend.visionOpticalFlow.telemetryLabel == "Vision Flow")

        let vtTelemetry = VideoEnhancementTelemetry(
            activeModeLabel: "MetalFX SR + VT System",
            inputWidth: 1920,
            inputHeight: 1080,
            outputWidth: 2560,
            outputHeight: 1440,
            inputFPS: 30,
            outputFPS: 60,
            smoothedProcessingMs: 3.4,
            isActive: true,
            activeFrameInterpolationBackendLabel: "VT System"
        )
        #expect(vtTelemetry.resolvedFrameInterpolationBackendLabel == "VT System")
        #expect(vtTelemetry.formattedSummary.contains("VT System"))
        #expect(vtTelemetry.compactSummary.contains("VT System"))

        let visionTelemetry = VideoEnhancementTelemetry(
            activeModeLabel: "Vision Flow",
            inputWidth: 1280,
            inputHeight: 720,
            outputWidth: 1280,
            outputHeight: 720,
            inputFPS: 24,
            outputFPS: 60,
            smoothedProcessingMs: 8.2,
            isActive: true,
            activeFrameInterpolationBackendLabel: "Vision Flow"
        )
        #expect(visionTelemetry.resolvedFrameInterpolationBackendLabel == "Vision Flow")
        #expect(visionTelemetry.formattedSummary.contains("Vision Flow"))
        #expect(visionTelemetry.compactSummary.contains("Vision Flow"))

        // Backward-compatible inference when only activeModeLabel is populated (e.g., snapshots).
        let legacyVT = VideoEnhancementTelemetry(activeModeLabel: "MetalFX SR + VT FI", isActive: true)
        #expect(legacyVT.resolvedFrameInterpolationBackendLabel == "VT System")
        let legacyVision = VideoEnhancementTelemetry(activeModeLabel: "Vision FI", isActive: true)
        #expect(legacyVision.resolvedFrameInterpolationBackendLabel == "Vision Flow")
        let srOnly = VideoEnhancementTelemetry(activeModeLabel: "MetalFX SR", isActive: true)
        #expect(srOnly.resolvedFrameInterpolationBackendLabel == nil)

        // PlayerStatsOverlay engine display row formatting.
        let config60 = VideoEnhancementConfiguration(
            frameInterpolationEnabled: true,
            frameInterpolationBackend: .videoToolbox,
            interpolationRate: .fps60
        )
        let configDouble = VideoEnhancementConfiguration(
            frameInterpolationEnabled: true,
            frameInterpolationBackend: .visionOpticalFlow,
            interpolationRate: .doubleRate
        )
        let config120 = VideoEnhancementConfiguration(
            frameInterpolationEnabled: true,
            frameInterpolationBackend: .videoToolbox,
            interpolationRate: .fps120
        )
        let configDisabled = VideoEnhancementConfiguration(
            superResolutionMode: .metalFXSpatial,
            frameInterpolationEnabled: false
        )

        #expect(
            PlayerStatsOverlay.interpolationEngineSummary(for: vtTelemetry, configuration: config60)
                == "VT System (60 fps)"
        )
        #expect(
            PlayerStatsOverlay.interpolationEngineSummary(for: visionTelemetry, configuration: configDouble)
                == "Vision Flow (2×)"
        )
        #expect(
            PlayerStatsOverlay.interpolationEngineSummary(for: vtTelemetry, configuration: config120)
                == "VT System (120 fps)"
        )
        #expect(
            PlayerStatsOverlay.interpolationEngineSummary(for: vtTelemetry, configuration: nil)
                == "VT System"
        )
        #expect(
            PlayerStatsOverlay.interpolationEngineSummary(for: visionTelemetry, configuration: nil)
                == "Vision Flow"
        )
        #expect(
            PlayerStatsOverlay.interpolationEngineSummary(for: srOnly, configuration: configDisabled)
                == nil
        )
    }

    @Test("VideoFramePostProcessor exposes active backend label and handles live updateConfiguration transitions")
    func postProcessorRuntimeTelemetryAndUpdateConfiguration() {
        let processor = VideoFramePostProcessor()
        defer { processor.tearDown() }

        #expect(processor.telemetry.activeFrameInterpolationBackendLabel == nil)

        let fiAuto = VideoEnhancementConfiguration(
            frameInterpolationEnabled: true,
            frameInterpolationBackend: .auto,
            interpolationRate: .fps60
        )
        let initialChange = processor.updateConfiguration(fiAuto)
        #expect(initialChange == .fullPipelineReset)
        let expectedAutoLabel = fiAuto.resolvedFrameInterpolationBackend.telemetryLabel
        #expect(processor.activeFrameInterpolationBackendLabel == expectedAutoLabel)
        #expect(processor.interpolationLabel == expectedAutoLabel)
        #expect(processor.telemetry.activeFrameInterpolationBackendLabel == expectedAutoLabel)

        // Switching to explicit Vision Optical Flow updates runtime label cleanly.
        var fiVision = fiAuto
        fiVision.frameInterpolationBackend = .visionOpticalFlow
        let switchChange = processor.updateConfiguration(fiVision)
        if VideoEnhancementCapabilities.supportsVideoToolboxFrameInterpolation {
            #expect(switchChange == .interpolationBackendHotSwap(outgoing: .videoToolbox, incoming: .visionOpticalFlow))
        } else {
            #expect(switchChange == .interpolationBackendAliasOnly)
        }
        #expect(processor.resolvedFrameInterpolationBackend == .visionOpticalFlow)
        #expect(processor.activeFrameInterpolationBackendLabel == "Vision Flow")
        #expect(processor.telemetry.activeFrameInterpolationBackendLabel == "Vision Flow")

        // Turning FI off clears activeFrameInterpolationBackendLabel from telemetry.
        var fiOff = fiVision
        fiOff.frameInterpolationEnabled = false
        #expect(processor.updateConfiguration(fiOff) == .fullPipelineReset)
        #expect(processor.telemetry.activeFrameInterpolationBackendLabel == nil)
    }
}
