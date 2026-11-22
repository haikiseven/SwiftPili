import Foundation

/// What a typed runtime fault says to the USER.
///
/// `MediaRuntimeFault` carries a subsystem, a stage, a classification and
/// diagnostics, and every one of them reached the log while the overlay showed
/// one hardcoded sentence: *"Video decoder failed. Tap Retry."* — no matter what
/// had actually failed. That is not a wording problem. A seek that positioned
/// correctly and then could not bank enough audio past the target reported a
/// broken video decoder to a user whose video decoder had just decoded two
/// 1920×1080 frames (backlog CB-23, D2); so does a live HLS map rotation, which
/// is a demux event with no decoder in it.
///
/// The repo's rule is to fix the producer rather than teach the consumer to
/// second-guess a state. Here the producer already knows — it types the fault
/// precisely — and the projection threw the information away. This is the
/// projection, as a table.
///
/// Stage outranks subsystem for exactly one stage, and the reason is what the
/// user can DO about it: a `.seekPriming` fault is the engine failing to start
/// at a position, and naming the decoder that was working fine sends the user
/// (and the bug report) to the wrong place.
enum MediaRuntimeFaultPresentation {
    static func message(for fault: MediaRuntimeFault) -> String {
        message(subsystem: fault.subsystem, stage: fault.stage)
    }

    /// Split from the fault so the table can be exercised over every
    /// (subsystem, stage) pair without building a fault for each one.
    static func message(
        subsystem: MediaRuntimeFaultSubsystem,
        stage: MediaRuntimeFaultStage
    ) -> String {
        if stage == .seekPriming {
            return String(localized: "Could not start playing from that position. Tap Retry.")
        }
        switch subsystem {
        case .videoDecoder:
            // The historical string, kept verbatim: it is correct for this
            // subsystem, and it is the one entry already in both catalogs.
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
