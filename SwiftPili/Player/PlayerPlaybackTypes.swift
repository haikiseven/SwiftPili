import AVFoundation
import Foundation
import UIKit

enum PlayerMode: Sendable, Equatable {
    case vod
    case offline
    case live

    var isSeekable: Bool {
        switch self {
        case .vod, .offline: true
        case .live: false
        }
    }

    var supportsPlaybackRate: Bool { isSeekable }
    var usesOnlineVODServices: Bool { self == .vod }
    var usesPlaybackWatchdog: Bool { isSeekable }
}

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
    var lastStartup = ""
    var lastSeek = ""
    var fps: Double = 0
    var quality = 0
    var qualityDesc = ""
    var audioCodec = ""
    var audioBitrate = 0
    var audioTier: AudioQualityTier?
    var audioTrackName: String {
        AudioStreamSelection.trackName(codecs: audioCodec, tier: audioTier)
    }
    var videoURL = ""
    var decoderType = ""
    var droppedFrames = 0
    var dropRate: Double = 0
    var bufferHealth: TimeInterval?
    var hasSeparateAudio = false
    var videoHost = ""
    var audioHost = ""
    var cdnSetting = ""
    var networkSpeed: Double = 0
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
