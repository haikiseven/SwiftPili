import AudioToolbox
import Foundation

/// The per-codec half of `AudioToolboxAudioDecoder`: how the compressed
/// input is described to `AudioConverterNew`, and nothing else.
///
/// Built from what the demuxer states about the track — its sample-entry
/// fourcc and codec-config payload — the audio analogue of the video seam's
/// `MediaVideoFormat.codecConfig(codec:config:)`.
enum AudioToolboxInput: Equatable, Sendable {
    /// `asc` is kept for the open log only.
    case aac(PathACodecConfig.AACConfiguration, asc: Data, cookie: Data?)
    /// `cookie` is the whole `dfLa` box (`FLACStreamInfo.magicCookie`).
    case flac(FLACStreamInfo, cookie: Data)

    /// `nil` codec is AAC: every caller before FLAC opened without one.
    static func resolve(codec: String?, formatHint: Data?) throws -> AudioToolboxInput {
        switch codec?.lowercased() {
        case nil, "mp4a":
            return try aac(formatHint: formatHint)
        case "flac":
            return try flac(formatHint: formatHint)
        case .some:
            throw MediaEngineError.notImplemented("audio codec \(codec ?? "?")")
        }
    }

    private static func aac(formatHint: Data?) throws -> AudioToolboxInput {
        guard let hint = formatHint, !hint.isEmpty else {
            throw MediaEngineError.notImplemented("AAC decoder needs esds/ASC formatHint (D3)")
        }
        guard let asc = PathACodecConfig.aacAudioSpecificConfig(fromESDSOrASC: hint),
              asc.count >= 2
        else {
            throw MediaEngineError.decodeFailed("AAC ASC not found in formatHint (\(hint.count)B)")
        }
        guard let config = PathACodecConfig.aacConfiguration(fromESDSOrASC: hint) else {
            throw MediaEngineError.decodeFailed("AAC ASC fields are invalid")
        }
        guard config.isAAC else {
            throw MediaEngineError.notImplemented(
                "unsupported AAC core object type=\(config.coreAudioObjectType)"
            )
        }
        // Magic cookie = ES_Descriptor (esds), NOT the bare ASC (device D3:
        // 2-byte ASC as cookie → AudioConverter `!dat` bad-data). Best-effort:
        // AAC-LC decodes from the ASBD alone if the converter still rejects it.
        return .aac(config, asc: asc, cookie: PathACodecConfig.aacMagicCookie(fromESDS: hint))
    }

    private static func flac(formatHint: Data?) throws -> AudioToolboxInput {
        guard let hint = formatHint, !hint.isEmpty else {
            throw MediaEngineError.notImplemented("FLAC decoder needs a dfLa formatHint")
        }
        let info = try FLACStreamInfo.parse(dfLa: hint)
        guard sourceBitDepthFlag(bitsPerSample: info.bitsPerSample) != nil else {
            throw MediaEngineError.notImplemented(
                "FLAC \(info.bitsPerSample)-bit source; AudioToolbox describes 16/20/24/32"
            )
        }
        guard let cookie = FLACStreamInfo.magicCookie(dfLa: hint) else {
            throw MediaEngineError.decodeFailed("FLAC dfLa payload \(hint.count)B cannot be boxed")
        }
        return .flac(info, cookie: cookie)
    }

    /// `kAudioFormatFLAC` "uses flags to indicate the bit depth of the source
    /// material" — the Apple Lossless source-depth flags.
    static func sourceBitDepthFlag(bitsPerSample: Int) -> AudioFormatFlags? {
        switch bitsPerSample {
        case 16: return AudioFormatFlags(kAppleLosslessFormatFlag_16BitSourceData)
        case 20: return AudioFormatFlags(kAppleLosslessFormatFlag_20BitSourceData)
        case 24: return AudioFormatFlags(kAppleLosslessFormatFlag_24BitSourceData)
        case 32: return AudioFormatFlags(kAppleLosslessFormatFlag_32BitSourceData)
        default: return nil
        }
    }

    var logLabel: String {
        switch self {
        case .aac: return "AAC"
        case .flac: return "FLAC"
        }
    }

    /// The rate the decoder produces PCM at. AAC: the ASC's output rate (the
    /// SBR extension rate where signalled). FLAC: STREAMINFO — never the
    /// sample entry's 16.16 field, which cannot hold rates above 65535 Hz.
    var decodedSampleRate: Double {
        switch self {
        case .aac(let config, _, _): return config.outputSampleRate
        case .flac(let info, _): return Double(info.sampleRate)
        }
    }

    /// Decoded channel count of the compressed stream.
    var channels: UInt32 {
        switch self {
        case .aac(let config, _, _): return config.channels
        case .flac(let info, _): return info.channels
        }
    }

    /// Channels to ask the converter to OUTPUT.
    ///
    /// AAC asks for the ENGINE's channel count, not the stream's. This used
    /// to be `config.channels`, so a non-stereo track produced non-stereo PCM
    /// — and every renderer pulls with the engine format (48kHz/2ch), while
    /// `AudioTimelineBuffer.pull` requires an exact channel match. The PCM was
    /// decoded, banked and counted, and then never pulled: 0 frames forever.
    /// Since the media clock's only writer is DRAINED audio, the clock never
    /// left 0, the video slave was never released, and the session sat in
    /// `buffering` with a full 8.4s video runway and 12.1s of data — healthy
    /// on every compressed-side metric, with nothing ever presented.
    ///
    /// CoreAudio's AAC decoder knows the stream's channel layout from the
    /// magic cookie, so asking it for stereo lets IT do the mix — which is the
    /// only correct place for one, because AAC's native channel order
    /// (C,L,R,Ls,Rs,LFE) is not the WAVE order a hand-rolled downmix would
    /// assume. `negotiatedOutputChannels` stays the source of truth: if the
    /// converter declines, the mismatch is caught rather than assumed.
    ///
    /// FLAC asks for its OWN channel count, so the decoder's channel contract
    /// is applied to what the stream really is: mono comes back mono and is
    /// duplicated in software, bit-exact; stereo passes through; anything
    /// else fails closed at open instead of being mixed by a converter step
    /// nothing here has verified.
    var requestedOutputChannels: UInt32 {
        switch self {
        case .aac: return AudioToolboxAudioDecoder.engineChannelCount
        case .flac(let info, _): return info.channels
        }
    }

    /// Compressed frames one packet can carry — the decode request size.
    var compressedFramesPerPacket: Int {
        switch self {
        case .aac(let config, _, _): return config.frameLength
        case .flac(let info, _): return info.maximumBlockSize
        }
    }

    /// PCM frames one packet decodes to at the decoder's native rate.
    var nativeFramesPerPacket: Int {
        switch self {
        case .aac(let config, _, _): return config.nativeFramesPerAccessUnit
        case .flac(let info, _): return info.maximumBlockSize
        }
    }

    var magicCookie: Data? {
        switch self {
        case .aac(_, _, let cookie): return cookie
        case .flac(_, let cookie): return cookie
        }
    }

    /// Input: the compressed stream described the way CoreAudio and the
    /// CONTAINER both describe it — at the decoded rate, with the decoded
    /// quantum.
    ///
    /// AAC: this stream's audio samples are stamped `durTicks=2048
    /// ts=48000`, i.e. 2048 frames at 48 kHz, not 1024 at 24 kHz.
    /// `nativeFramesPerAccessUnit` had exactly one call site before this (the
    /// output capacity in `decode`); the description of the input was still
    /// the core quantum, so the two halves of the same fact disagreed. The
    /// format ID branches on the PARSED configuration rather than the declared
    /// AOT, so an implicitly-signalled SBR stream (AOT 2 carrying a sync
    /// extension, `PathACodecConfig.swift`) is described the same way as an
    /// explicit one. That case is the less exercised of the two — the device
    /// evidence is an explicit `aot=5` stream.
    ///
    /// FLAC: STREAMINFO's rate and channels, its source bit depth as the
    /// format flag, and its maximum block size as frames per packet.
    var inputDescription: AudioStreamBasicDescription {
        switch self {
        case .aac(let config, _, _):
            let inputFormatID: AudioFormatID
            if config.psPresent {
                inputFormatID = kAudioFormatMPEG4AAC_HE_V2
            } else if config.sbrPresent {
                inputFormatID = kAudioFormatMPEG4AAC_HE
            } else {
                inputFormatID = kAudioFormatMPEG4AAC
            }
            return AudioStreamBasicDescription(
                mSampleRate: config.outputSampleRate,
                mFormatID: inputFormatID,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: UInt32(config.nativeFramesPerAccessUnit),
                mBytesPerFrame: 0,
                mChannelsPerFrame: config.channels,
                mBitsPerChannel: 0,
                mReserved: 0
            )
        case .flac(let info, _):
            return AudioStreamBasicDescription(
                mSampleRate: Double(info.sampleRate),
                mFormatID: kAudioFormatFLAC,
                mFormatFlags: Self.sourceBitDepthFlag(bitsPerSample: info.bitsPerSample) ?? 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: UInt32(info.maximumBlockSize),
                mBytesPerFrame: 0,
                mChannelsPerFrame: info.channels,
                mBitsPerChannel: 0,
                mReserved: 0
            )
        }
    }
}
