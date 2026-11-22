import AVFoundation
import Foundation

/// Native handles stay bound to one physical graph for an entire maintenance operation.
/// Mutated exclusively on EngineAudioRenderer's serial hardware queue; `@unchecked Sendable`
/// preserves iOS 26 SDK compatibility where AVAudioEngine/AVAudioUnit* lack NS_SWIFT_SENDABLE.
struct AudioEqualizerNativeGraph: @unchecked Sendable {
    let engine: AVAudioEngine
    let equalizer: AVAudioUnitEQ
    let pitch: AVAudioUnitTimePitch?
    let stamp: AudioNativeOutputBinding.Stamp
}

/// Transfers an `AVAudioEngine` (and optional nodes to detach) across EngineAudioRenderer's
/// serial hardware queue without relying on iOS 27 SDK's `NS_SWIFT_SENDABLE` annotation.
struct AudioHardwareEngineTransfer: @unchecked Sendable {
    let engine: AVAudioEngine
    let nodes: [AVAudioNode]

    init(_ engine: AVAudioEngine, nodes: [AVAudioNode] = []) {
        self.engine = engine
        self.nodes = nodes
    }
}

enum AudioEqualizerNativeAction: Sendable {
    case pauseAndReset
    case resume(AudioMaintenancePermit, AudioMaintenancePermit.Ticket)
    case pause
}

struct AudioEqualizerNativeResult: Sendable {
    let running: Bool
    let performedReset: Bool
    let failure: String?
}

enum AudioEqualizerNativeExecution {
    /// Called only by EngineAudioRenderer's serial hardware queue. Pause establishes
    /// the documented no-flow boundary; a source gate acknowledgement alone does not.
    nonisolated static func perform(
        _ action: AudioEqualizerNativeAction, graph: AudioEqualizerNativeGraph
    ) -> AudioEqualizerNativeResult {
        graph.engine.mainMixerNode.outputVolume = 0
        switch action {
        case .pauseAndReset:
            graph.engine.pause()
            guard !graph.engine.isRunning else {
                return AudioEqualizerNativeResult(running: true, performedReset: false, failure: "Audio did not pause")
            }
            graph.equalizer.reset()
            graph.pitch?.reset()
            return AudioEqualizerNativeResult(running: false, performedReset: true, failure: nil)
        case .resume(let permit, let ticket):
            guard permit.permits(ticket) else {
                return AudioEqualizerNativeResult(running: graph.engine.isRunning, performedReset: false, failure: nil)
            }
            do {
                try graph.engine.start()
                return AudioEqualizerNativeResult(
                    running: graph.engine.isRunning, performedReset: false, failure: nil
                )
            } catch {
                return AudioEqualizerNativeResult(
                    running: graph.engine.isRunning, performedReset: false, failure: error.localizedDescription
                )
            }
        case .pause:
            graph.engine.pause()
            return AudioEqualizerNativeResult(
                running: graph.engine.isRunning, performedReset: false, failure: nil
            )
        }
    }
}

/// Latency zero from an active AudioUnit may mean unreported; bypass is known zero.
enum AudioProcessingLatency: Equatable, Sendable {
    case bypassed
    case unreported
    case reported(TimeInterval)

    var wallSeconds: TimeInterval {
        if case .reported(let value) = self { return value }
        return 0
    }
}
