import AVFoundation
import Foundation

struct AudioEqualizerNativeGraph: @unchecked Sendable {
    let engine: AVAudioEngine
    let equalizer: AVAudioUnitEQ
    let pitch: AVAudioUnitTimePitch?
    let stamp: AudioNativeOutputBinding.Stamp
}

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

enum AudioProcessingLatency: Equatable, Sendable {
    case bypassed
    case unreported
    case reported(TimeInterval)

    var wallSeconds: TimeInterval {
        if case .reported(let value) = self { return value }
        return 0
    }
}
