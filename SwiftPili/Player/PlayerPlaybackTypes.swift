import AVFoundation
import Foundation
import UIKit

enum PlayerMode: Sendable, Equatable {
    case vod
    case offline
    case live

    /// Timeline controls belong to finite media, regardless of whether its
    /// bytes come from a CDN or a validated download.
    var isSeekable: Bool {
        switch self {
        case .vod, .offline: true
        case .live: false
        }
    }

    var supportsPlaybackRate: Bool { isSeekable }
    var usesOnlineVODServices: Bool { self == .vod }
    /// Finite online and offline media share the playback watchdog; live playback is excluded.
    var usesPlaybackWatchdog: Bool { isSeekable }
}

/// StartupTrace measures cold UGC/PGC detail playback only.
enum PlayerStartupTraceScope {
    static func tokenForStream(
        mode: PlayerMode,
        retainedToken: StartupTrace.Token?
    ) -> StartupTrace.Token? {
        mode == .vod ? retainedToken : nil
    }

    static func tokenToAbortBeforeLoad(
        targetMode: PlayerMode,
        retainedToken: StartupTrace.Token?
    ) -> StartupTrace.Token? {
        targetMode == .vod ? nil : retainedToken
    }
}

struct PlayerEqualizerPresentationIdentity: Equatable {
    let owner: PlayerOwnerLease
    let source: DecoderRecoveryAdmission.Source
    let loadGeneration: Int
    let backend: ObjectIdentifier
}

/// What happens when playback reaches the end.
enum PlaybackOrder: String, CaseIterable, Sendable {
    case playNext = "next"
    case loopOne = "loop"
    case pauseAtEnd = "pause"

    var label: String {
        switch self {
        case .playNext: String(localized: "Play Next Part")
        case .loopOne: String(localized: "Loop Current")
        case .pauseAtEnd: String(localized: "Pause at End")
        }
    }

    var icon: String {
        switch self {
        case .playNext: "text.line.first.and.arrowtriangle.forward"
        case .loopOne: "repeat.1"
        case .pauseAtEnd: "stop.circle"
        }
    }
}

struct PlaybackStats: Equatable {
    var codec = ""
    var resolution = ""
    var bitrate = 0
    /// On-screen debug counters, fed by the traces' completion callbacks so a
    /// device test reads timings off the stats overlay instead of a tethered
    /// console. Pre-formatted; empty = no completed measurement this stream.
    var lastStartup = ""
    var lastSeek = ""
    var fps: Double = 0
    var quality = 0
    var qualityDesc = ""
    var audioCodec = ""
    var audioBitrate = 0
    /// Tier of the playing audio stream; `nil` for an unknown id.
    var audioTier: AudioQualityTier?
    /// The overlay's name for the audio track, e.g. `FLAC Hi-Res`.
    var audioTrackName: String {
        AudioStreamSelection.trackName(codecs: audioCodec, tier: audioTier)
    }
    var videoURL = ""
    var decoderType = ""
    var droppedFrames = 0
    /// The cumulative counter above never resets during a stream, so it can't say whether dropping is happening
    /// NOW — and at 2x a climbing total is by design (the pacer consumes the surplus frames the display can't
    /// show).
    var dropRate: Double = 0
    /// `nil` = no backend has measured one, which is the permanent answer on libVLC and the correct answer on
    /// any backend before its first sample.
    var bufferHealth: TimeInterval?
    var hasSeparateAudio = false
    var videoHost = ""
    var audioHost = ""
    var cdnSetting = ""
    /// Real download rate in bytes/sec — Δ(`networkBytesReceived`)/Δt, i.e. bytes received from the network for
    /// the playing stream (both tracks, and multi-connection helpers on Demand; store hits excluded), sampled
    /// once a second.
    var networkSpeed: Double = 0
    /// Live telemetry for experimental Demand VOD video enhancement (SR / FI).
    var videoEnhancement: VideoEnhancementTelemetry?

    var networkSpeedText: String {
        if networkSpeed >= 1_048_576 {
            return String(format: "%.1f MB/s", networkSpeed / 1_048_576)
        }
        if networkSpeed >= 1024 {
            return String(format: "%.0f KB/s", networkSpeed / 1024)
        }
        return String(format: "%.0f B/s", networkSpeed)
    }
}

enum NetworkType: String, CaseIterable {
    case wifi = "Wi-Fi"
    case cellular = "Cellular"
}
