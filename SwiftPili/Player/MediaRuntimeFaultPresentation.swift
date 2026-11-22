import Foundation

enum MediaRuntimeFaultPresentation {
    static func message(for fault: MediaRuntimeFault) -> String {
        message(subsystem: fault.subsystem, stage: fault.stage)
    }

    static func message(
        subsystem: MediaRuntimeFaultSubsystem,
        stage: MediaRuntimeFaultStage
    ) -> String {
        if stage == .seekPriming {
            return String(localized: "Could not start playing from that position. Tap Retry.")
        }
        switch subsystem {
        case .videoDecoder:
            return String(localized: "Video decoder failed. Tap Retry.")
        case .audioDecoder:
            return String(localized: "Audio decoder failed. Tap Retry.")
        case .demux:
            return String(localized: "This video stream could not be read. Tap Retry.")
        case .videoRenderer:
            return String(localized: "Video output failed. Tap Retry.")
        case .audioRenderer:
            return String(localized: "Audio output failed. Tap Retry.")
        }
    }
}
