import Foundation

/// Resolves the optional diagnostic override for the Demand bring-up stack.
///
/// A1d fMP4 is the safe default for Bilibili's bare `.m4s` resources. A1c
/// AVAsset remains available only as an explicit progressive-fixture rollback.
/// Unknown values stay on A1d instead of silently selecting the device-rejected
/// AVAsset path.
enum DemandBringUpDemuxSelection: Equatable, Sendable {
    case fmp4
    case avAsset

    static func resolve(_ rawOverride: String?) -> Self {
        let normalized = rawOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "avasset":
            return .avAsset
        case "fmp4", "http_fmp4", "patha_fmp4", nil, "":
            return .fmp4
        default:
            return .fmp4
        }
    }
}

/// App-owned construction and launch configuration for Demand sessions.
@MainActor
enum DemandMediaEngineAssembly {
    private static var demuxSelection: DemandBringUpDemuxSelection {
        let environment = ProcessInfo.processInfo.environment
        let override = ExperimentalSettingsPolicy.diagnosticsEnabled
            ? environment["PATHA_DEMUX"] ?? environment["vod_patha_demux"] : nil
        return DemandBringUpDemuxSelection.resolve(override)
    }

    static var supportsLibavformatLive: Bool {
        demuxSelection == .fmp4 && DemandLibavformatDemuxer.isAvailable
    }

    /// Product-default Demand stack, also selectable through launch overrides.
    ///
    /// Default vertical (A1d + A2-α + A3b hardware opt-in):
    /// - demux: `PathAAdaptiveDemuxer` for progressive fMP4 and typed live sources
    /// - decode: VideoToolbox + AAC
    /// - video: `SampleBufferVideoRenderer` dual-clock slave
    /// - audio: `EngineAudioRenderer`
    ///
    /// `PATHA_DEMUX=avasset` is an explicit diagnostic rollback for progressive
    /// fixtures. It is not selected by an absent or unknown override because
    /// device testing rejects bare bilivideo `.m4s` with `AVError -11828`.
    /// This is the shared player's default engine in Debug and Release.
    static func makeDemandBringUp() -> MediaEngineSession {
        let audio = EngineAudioRenderer()
        audio.preferHardwareGraph = true
        audio.fillPeriod = 0.02
        switch demuxSelection {
        case .fmp4:
            PlayerLog.log(
                "[PathA] makeDemandBringUp demux=adaptive " +
                "decode=VT+AAC display=A2-α"
            )
            return MediaEngineSession(
                demux: PathAAdaptiveDemuxer(),
                videoDecoder: VideoToolboxDecoder(),
                videoDecoderFactory: { VideoToolboxDecoder() },
                audioDecoder: AudioToolboxAudioDecoder(),
                videoRender: MediaVideoRendererFactory.makeDemandRenderer(),
                audioRender: audio,
                seekFastPreroll: SeekFastPrerollSwitch.isEnabled(environment: ProcessInfo.processInfo.environment),
                videoPrerollClassifierFactory: { codec, config in
                    VideoSampleDependencyClassifier(codec: codec, config: config)
                },
                diagnostics: PlayerLogMediaEngineDiagnostics(),
                tracing: StartupTraceMediaEngineTracing()
            )
        case .avAsset:
            PlayerLog.log(
                "[PathA] makeDemandBringUp demux=AVAsset(A1c explicit rollback) " +
                "decode=PassThrough display=A2-α (progressive fixtures only)"
            )
            return MediaEngineSession(
                demux: AVAssetMediaDemuxer(),
                videoDecoder: PassThroughVideoDecoder(),
                videoDecoderFactory: { PassThroughVideoDecoder() },
                audioDecoder: PassThroughAudioDecoder(),
                videoRender: MediaVideoRendererFactory.makeDemandRenderer(),
                audioRender: audio,
                seekFastPreroll: SeekFastPrerollSwitch.isEnabled(environment: ProcessInfo.processInfo.environment),
                videoPrerollClassifierFactory: { codec, config in
                    VideoSampleDependencyClassifier(codec: codec, config: config)
                },
                diagnostics: PlayerLogMediaEngineDiagnostics(),
                tracing: StartupTraceMediaEngineTracing()
            )
        }
    }

    /// Fail-closed construction without native demux, decoder or renderer work.
    static func makeUnavailableSession() -> MediaEngineSession {
        MediaEngineSession(
            demux: StubMediaDemuxer(),
            videoDecoder: StubVideoDecoder(),
            audioDecoder: StubAudioDecoder(),
            videoRender: PlaceholderVideoRenderer(),
            audioRender: PlaceholderAudioRenderer(),
            seekFastPreroll: SeekFastPrerollSwitch.isEnabled(environment: ProcessInfo.processInfo.environment),
            videoPrerollClassifierFactory: { codec, config in
                VideoSampleDependencyClassifier(codec: codec, config: config)
            },
            diagnostics: PlayerLogMediaEngineDiagnostics(),
            tracing: StartupTraceMediaEngineTracing()
        )
    }
}
