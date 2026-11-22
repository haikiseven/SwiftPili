import AudioToolbox
import Foundation

enum AudioToolboxInput: Equatable, Sendable {
    case aac(PathACodecConfig.AACConfiguration, asc: Data, cookie: Data?)
    case flac(FLACStreamInfo, cookie: Data)

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

    var decodedSampleRate: Double {
        switch self {
        case .aac(let config, _, _): return config.outputSampleRate
        case .flac(let info, _): return Double(info.sampleRate)
        }
    }

    var channels: UInt32 {
        switch self {
        case .aac(let config, _, _): return config.channels
        case .flac(let info, _): return info.channels
        }
    }

    var requestedOutputChannels: UInt32 {
        switch self {
        case .aac: return AudioToolboxAudioDecoder.engineChannelCount
        case .flac(let info, _): return info.channels
        }
    }

    var compressedFramesPerPacket: Int {
        switch self {
        case .aac(let config, _, _): return config.frameLength
        case .flac(let info, _): return info.maximumBlockSize
        }
    }

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
