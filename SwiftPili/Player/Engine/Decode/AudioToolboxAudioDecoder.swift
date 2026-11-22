import AudioToolbox
import Foundation

/// Path A D3: AudioToolbox AAC (`mp4a`)/FLAC (`fLaC`) → interleaved Float32 PCM
/// for `EngineAudioRenderer`. Only the input description is codec-specific;
/// fail-closed negotiation, mono duplication, `PCMLinearResampler`, the `'nodt'`
/// callback and `pendingAccessUnits` are shared. Each decode accepts one packet.
/// AAC `formatHint` is AudioSpecificConfig or the fMP4 `esds` payload from
/// `PathAFMP4Demuxer.formatConfig(for: .audio)`; packets are raw AAC access units.
/// FLAC uses the `dfLa` hint and one FLAC frame per packet (one ISO MP4 sample).

/// "No input available right now" — NOT end of stream.
///
/// `AudioConverterFillComplexBuffer`'s input callback has exactly one way to
/// say "zero packets": `ioNumDataPackets = 0`. Paired with `noErr` that is
/// CoreAudio's END-OF-STREAM signal, and a converter told that once is finished
/// for the life of the converter — every later fill returns `noErr` with zero
/// output packets, which this file mapped to a silent empty array. Device
/// 2026-09-10 (BV1S9DcYpEgP, HE-AAC): exactly one 2048-frame quantum decoded,
/// then permanent silence with no error raised anywhere, and the session died
/// on `launch reserve unavailable audio=0`.
///
/// A non-zero status is back-pressure instead: the converter returns what it
/// has and stays usable. File scope because the callback is `@convention(c)`
/// and captures nothing.
private let converterNoInputDataAvailable: OSStatus = 0x6E6F_6474  // 'nodt'

/// The converter, pending AU FIFO and resampler share one executor. Cancellation
/// retires caller publication; native state is released only after an executing
/// decode has returned to this actor, including direct decode bursts.
actor AudioToolboxAudioDecoder: MediaAudioDecoding {
    private var converter: AudioConverterRef?
    /// Retains the last supplied input beyond a fill until the next callback/reset/close.
    private var retainedConverterInput: InputBox?
    private var opened = false
    /// Compressed input rate reported by the AudioConverter after negotiation.
    private var inputSampleRate: Double = 44_100
    /// PCM rate reported by the AudioConverter before the engine SRC.
    private var nativeDecodedSampleRate: Double = 44_100
    private var outSampleRate: Double = 48_000
    /// Mirrors `MediaEngineSession.EnginePCM.channelCount`, like `outSampleRate`,
    /// without coupling this actor to the MainActor session. Change both owners
    /// together: `AudioTimelineBuffer` rejects a mismatched format at first append.
    static let engineChannelCount: UInt32 = 2
    private var outChannels: UInt32 = 2
    /// Set at open when the platform decoder gave us mono and the engine wants
    /// stereo. Duplication is the one channel conversion that needs no
    /// assumption about channel ORDER, which is why it is the only one done
    /// here rather than refused.
    private var duplicatesMonoToStereo = false
    /// What the converter was opened for; `nil` while closed.
    private var input: AudioToolboxInput?
    /// Stateful PCM SRC retained across compressed packets.
    private var pcmResampler = PCMLinearResampler(
        inputSampleRate: 44_100,
        outputSampleRate: 48_000,
        channelCount: 2
    )
    private(set) var framesProduced = 0
    /// Access units the converter has taken but not yet answered with PCM.
    ///
    /// The boundary is 1-in/1-out and the fail-closed rate check in `open()`
    /// keeps it that way, but `converterNoInputDataAvailable` deliberately lets a
    /// converter withhold output for one AU and answer on a later fill. When
    /// that happens the PCM belongs to the OLDER access unit, so its timing has
    /// to come from here rather than from the packet in hand — stamping the
    /// newer packet's PTS would publish a permanent A/V offset that nothing
    /// downstream can detect. Bounded by `fillPCMRing`'s own no-progress fence,
    /// which stops feeding this decoder after two bursts without PCM; cleared
    /// at `flush()` and `close()`.
    private var pendingAccessUnits: [PendingAccessUnit] = []
    /// Display evidence requires a negotiated native PCM format and a known
    /// AU boundary. Only open or a successful native reset can reestablish a
    /// boundary after an ambiguous fill.
    private var hasVerifiedNativePCMFormat = false
    private var hasVerifiedSRCLayout = false
    private var nativeAccessUnitBoundaryKnown = false
    /// Bursts where the converter consumed an AU and produced nothing. Drives
    /// the bounded `no PCM` report only.
    private var noPCMReturns = 0
    private var lastDiagnostics = MediaAudioDecodeDiagnostics.unavailable

    private struct PendingAccessUnit {
        let pts: TimeInterval
        let timing: MediaAudioPacketTiming?
        let displayCoverage: MediaDisplayLease?
    }

    private final class InputBox: @unchecked Sendable {
        /// Stable owned bytes; never escape a temporary Data buffer pointer.
        let bytes: UnsafeMutableRawPointer
        let byteCount: Int
        var consumed = false
        var entries = 0
        var toldToWait = false
        // AAC and FLAC are VBR. Native conversion needs the whole AU's size.
        let packetDesc: UnsafeMutablePointer<AudioStreamPacketDescription>
        init(_ data: Data) {
            byteCount = data.count
            bytes = .allocate(byteCount: max(1, data.count), alignment: 16)
            packetDesc = .allocate(capacity: 1)
            data.withUnsafeBytes { raw in
                if let base = raw.baseAddress, raw.count > 0 {
                    bytes.copyMemory(from: base, byteCount: raw.count)
                }
            }
            packetDesc.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(data.count)
            )
        }
        deinit {
            bytes.deallocate()
            packetDesc.deallocate()
        }
    }

    func decodeDiagnostics() async -> MediaAudioDecodeDiagnostics {
        lastDiagnostics
    }

    /// One compressed AAC AU can produce more than one native PCM quantum when
    /// the converter's negotiated output ASBD is at a higher rate (for example
    /// an explicit SBR path). The output request must cover that negotiated
    /// ratio or the converter returns only a partial AU and the next packet is
    /// effectively played too fast.
    static func converterOutputFramesPerAccessUnit(
        compressedFrames: Int,
        inputSampleRate: Double,
        outputSampleRate: Double
    ) -> Int {
        guard compressedFrames > 0,
              inputSampleRate.isFinite,
              inputSampleRate > 0,
              outputSampleRate.isFinite,
              outputSampleRate > 0
        else { return max(1, compressedFrames) }
        let ratio = outputSampleRate / inputSampleRate
        guard ratio.isFinite, ratio > 0 else { return max(1, compressedFrames) }
        return max(
            compressedFrames,
            Int(ceil(Double(compressedFrames) * ratio - 1e-9))
        )
    }

    /// Preserves the pre-FLAC entry point: a nil codec selects AAC unchanged.
    func open(formatHint: Data?) async throws {
        try openNative(codec: nil, formatHint: formatHint)
    }

    func open(codec: String?, formatHint: Data?) async throws {
        try openNative(codec: codec, formatHint: formatHint)
    }

    /// Native replacement is one actor turn: no reentrancy between disposing
    /// the old converter and publishing its replacement.
    private func openNative(codec: String?, formatHint: Data?) throws {
        try Task.checkCancellation()
        closeNative()
        let input = try AudioToolboxInput.resolve(codec: codec, formatHint: formatHint)
        let label = input.logLabel
        // These are the requested rates. AudioConverter may normalize them
        // from the magic cookie; the current input/output ASBDs queried after
        // creation are the values used for frame accounting below.
        //
        // BOTH sides are the DECODED rate. The input used to be the AAC CORE
        // rate (24 kHz on this stream) against a 48 kHz output, which put a 2x
        // rate conversion INSIDE the converter — precisely the arrangement the
        // comment above `outASBD` forbids. See `converterNoInputDataAvailable`
        // for what that cost on device. AAC-LC was never affected because its
        // core rate IS its output rate; only SBR/PS streams have the two apart.
        // FLAC has a single rate, STREAMINFO's.
        let requestedInputSampleRate = input.decodedSampleRate
        let requestedNativeSampleRate = input.decodedSampleRate
        // See `AudioToolboxInput.requestedOutputChannels` for why AAC asks the
        // platform decoder for the ENGINE's channel count and FLAC for its own.
        let requestedOutputChannels = input.requestedOutputChannels
        // The DECODED channel count, not the core one: Parametric Stereo
        // expands a mono core to stereo output, and describing the input as
        // mono there made the converter hand back a mono-ified PS stream.
        let inChannels = input.channels
        self.inputSampleRate = requestedInputSampleRate
        self.nativeDecodedSampleRate = requestedNativeSampleRate
        self.outChannels = requestedOutputChannels
        self.input = input
        self.pcmResampler = PCMLinearResampler(
            inputSampleRate: requestedNativeSampleRate,
            outputSampleRate: outSampleRate,
            channelCount: Int(requestedOutputChannels)
        )

        // Decode to interleaved Float32 at the stream's native rate first.
        // AudioConverter's compressed-input callback is packetized one AU at a
        // time; asking that converter to also perform 44.1 → 48 kHz SRC makes
        // it request future compressed packets, which this boundary cannot
        // safely provide. The small PCM SRC below is stateful across AUs.
        var outASBD = AudioStreamBasicDescription(
            mSampleRate: requestedNativeSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * requestedOutputChannels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * requestedOutputChannels,
            mChannelsPerFrame: requestedOutputChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // Input: the compressed stream described the way CoreAudio and the
        // CONTAINER both describe it — see `AudioToolboxInput.inputDescription`.
        var inASBD = input.inputDescription

        var converterOut: AudioConverterRef?
        let status = AudioConverterNew(&inASBD, &outASBD, &converterOut)
        guard status == noErr, let converterOut else {
            throw MediaEngineError.decodeFailed("AudioConverterNew status=\(status)")
        }
        // Best-effort for both codecs: AAC-LC decodes from the ASBD alone, and
        // FLAC frames self-describe (measured: decoding with no cookie works).
        // A rejected cookie is logged, never fatal.
        var cookieRejected = false
        if let cookie = input.magicCookie {
            let cookieStatus = cookie.withUnsafeBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return AudioConverterSetProperty(
                    converterOut,
                    kAudioConverterDecompressionMagicCookie,
                    UInt32(cookie.count),
                    base
                )
            }
            if cookieStatus != noErr {
                cookieRejected = true
                PlayerLog.log(
                    "[PathA] \(label) magic cookie rejected status=\(cookieStatus) " +
                    "cookie=\(cookie.count)B — decoding from ASBD only"
                )
            }
        }
        self.converter = converterOut
        self.opened = true
        self.framesProduced = 0
        resetResampler()
        lastDiagnostics = MediaAudioDecodeDiagnostics(
            status: .idle,
            converterStatus: nil,
            inputPacketConsumed: false,
            outputFrames: 0,
            inputCallbackRequests: 0,
            inputCallbackAskedForMore: false,
            pendingAccessUnits: 0,
            noPCMReturns: 0
        )
        var converterInputASBD = inASBD
        var converterInputASBDSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let inputASBDStatus = AudioConverterGetProperty(
            converterOut,
            kAudioConverterCurrentInputStreamDescription,
            &converterInputASBDSize,
            &converterInputASBD
        )
        var converterOutputASBD = outASBD
        var converterOutputASBDSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let outputASBDStatus = AudioConverterGetProperty(
            converterOut,
            kAudioConverterCurrentOutputStreamDescription,
            &converterOutputASBDSize,
            &converterOutputASBD
        )
        let negotiatedInputRate = inputASBDStatus == noErr
            && converterInputASBD.mSampleRate.isFinite
            && converterInputASBD.mSampleRate > 0
            ? converterInputASBD.mSampleRate
            : requestedInputSampleRate
        let negotiatedOutputRate = outputASBDStatus == noErr
            && converterOutputASBD.mSampleRate.isFinite
            && converterOutputASBD.mSampleRate > 0
            ? converterOutputASBD.mSampleRate
            : requestedNativeSampleRate
        let negotiatedInputChannels = converterInputASBD.mChannelsPerFrame > 0
            ? converterInputASBD.mChannelsPerFrame
            : inChannels
        let negotiatedOutputChannels = converterOutputASBD.mChannelsPerFrame > 0
            ? converterOutputASBD.mChannelsPerFrame
            : outChannels
        self.inputSampleRate = negotiatedInputRate
        self.nativeDecodedSampleRate = negotiatedOutputRate
        self.outChannels = negotiatedOutputChannels
        // The converter must be a DECODER and nothing else.
        //
        // Different rates on its two sides mean it holds a sample-rate
        // converter, and an SRC needs input beyond the access unit this
        // boundary hands over one at a time. That is the configuration that
        // made HE-AAC decode a single quantum and then go permanently silent,
        // and it is invisible at the point of failure: the converter reports
        // `noErr` and simply stops producing. Refuse HERE, at open, where it
        // becomes an error the recovery ladder can act on — the same shape and
        // the same reason as the channel-count refusal below.
        //
        // Rate changes belong to `pcmResampler`, which is stateful across
        // access units and needs no lookahead.
        if abs(negotiatedInputRate - negotiatedOutputRate) > 0.5 {
            AudioConverterDispose(converterOut)
            self.converter = nil
            self.opened = false
            throw MediaEngineError.notImplemented(
                "\(label) converter negotiated \(Int(negotiatedInputRate))Hz in / " +
                "\(Int(negotiatedOutputRate))Hz out; a rate conversion inside the " +
                "converter makes it request access units this boundary supplies " +
                "one at a time, and it stops producing PCM after the first"
            )
        }
        // The engine format is a CONTRACT, not a hope. Mono is normalized in
        // software below (duplicating one channel is unambiguous and needs no
        // channel-order assumption); anything else fails HERE, at open, where it
        // becomes an error the recovery ladder can act on.
        //
        // Failing beats the alternative it replaces. The old behaviour accepted
        // any channel count and deadlocked silently in `buffering` forever,
        // because the fault was invisible to every readiness check: the decoder
        // opened, frames decoded, the PCM buffer filled to its target, and
        // `launchReadiness` only ever asked whether the SOURCE had content —
        // never whether a renderer could pull it.
        let engineChannels = Self.engineChannelCount
        self.duplicatesMonoToStereo = negotiatedOutputChannels == 1
            && engineChannels == 2
        if negotiatedOutputChannels != engineChannels, !duplicatesMonoToStereo {
            throw MediaEngineError.notImplemented(
                "\(label) decoded to \(negotiatedOutputChannels)ch; the engine renders " +
                "\(engineChannels)ch and its PCM buffer accepts no other format, " +
                "so this session would have no media clock"
            )
        }
        hasVerifiedNativePCMFormat = inASBD.mFormatID == kAudioFormatMPEG4AAC && !cookieRejected
            && inputASBDStatus == noErr
            && outputASBDStatus == noErr
            && converterInputASBD.mSampleRate == requestedNativeSampleRate
            && converterInputASBD.mChannelsPerFrame > 0
            && converterOutputASBD.mSampleRate == requestedNativeSampleRate
            && converterOutputASBD.mFormatID == kAudioFormatLinearPCM
            && converterOutputASBD.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && converterOutputASBD.mFramesPerPacket == 1
            && converterOutputASBD.mChannelsPerFrame > 0
            && converterOutputASBD.mBytesPerFrame == negotiatedOutputChannels * UInt32(MemoryLayout<Float>.size)
        let outputFlags = converterOutputASBD.mFormatFlags
        hasVerifiedSRCLayout = converterInputASBD.mFormatID == kAudioFormatMPEG4AAC
            && converterOutputASBD.mBitsPerChannel == 32
            && (outputFlags & kAudioFormatFlagIsPacked) != 0
            && (outputFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) == 0
        nativeAccessUnitBoundaryKnown = true
        self.pcmResampler = PCMLinearResampler(
            inputSampleRate: negotiatedOutputRate,
            outputSampleRate: outSampleRate,
            channelCount: Int(negotiatedOutputChannels)
        )
        resetResampler()
        var primeInfo = AudioConverterPrimeInfo(leadingFrames: 0, trailingFrames: 0)
        var primeInfoSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        let primeInfoStatus = AudioConverterGetProperty(
            converterOut,
            kAudioConverterPrimeInfo,
            &primeInfoSize,
            &primeInfo
        )
        var primeMethod = UInt32(kConverterPrimeMethod_Normal)
        var primeMethodSize = UInt32(MemoryLayout<UInt32>.size)
        let primeMethodStatus = AudioConverterGetProperty(
            converterOut,
            kAudioConverterPrimeMethod,
            &primeMethodSize,
            &primeMethod
        )
        let codecDetail: String
        switch input {
        case .aac(let config, let asc, _):
            let ascHex = asc.prefix(16).map { String(format: "%02x", $0) }.joined()
            codecDetail =
                "asc=\(asc.count)B/\(ascHex) " +
                "aot=\(config.audioObjectType) coreAOT=\(config.coreAudioObjectType) " +
                "in=\(Int(negotiatedInputRate))Hz/\(negotiatedInputChannels)ch " +
                "core=\(Int(config.coreSampleRate))Hz ext=\(config.extensionSampleRate.map { String(Int($0)) } ?? "none")Hz "
        case .flac(let info, _):
            codecDetail =
                "streaminfo=\(info.sampleRate)Hz/\(info.channels)ch/\(info.bitsPerSample)bit " +
                "block=\(info.minimumBlockSize)-\(info.maximumBlockSize) " +
                "samples=\(info.totalSamples) " +
                "in=\(Int(negotiatedInputRate))Hz/\(negotiatedInputChannels)ch "
        }
        let aacFlags: String
        if case .aac(let config, _, _) = input {
            aacFlags =
                "sbr=\(config.sbrPresent ? 1 : 0) ps=\(config.psPresent ? 1 : 0) " +
                "au=\(config.frameLength) "
        } else {
            aacFlags = "fpp=\(input.compressedFramesPerPacket) "
        }
        PlayerLog.log(
            "[PathA] \(label) decoder open " + codecDetail +
            "decode=\(Int(negotiatedOutputRate))Hz pcm=\(Int(outSampleRate))Hz/" +
            "\(duplicatesMonoToStereo ? engineChannels : negotiatedOutputChannels)ch" +
            (duplicatesMonoToStereo ? "(mono→stereo)" : "") + " " +
            aacFlags +
            "inASBD=\(Int(converterInputASBD.mSampleRate))Hz/\(converterInputASBD.mChannelsPerFrame)ch/" +
            "\(converterInputASBD.mBytesPerFrame)Bpf " +
            "outASBD=\(Int(converterOutputASBD.mSampleRate))Hz/\(converterOutputASBD.mChannelsPerFrame)ch/" +
            "\(converterOutputASBD.mBytesPerFrame)Bpf " +
            "asbdStatus=\(inputASBDStatus),\(outputASBDStatus) " +
            "prime=\(primeMethod) lead=\(primeInfo.leadingFrames) trail=\(primeInfo.trailingFrames) " +
            "primeStatus=\(primeMethodStatus),\(primeInfoStatus)"
        )
    }

    func decode(
        _ packet: MediaPacket, pendingDisplaySupport: AudioPendingDisplaySupport
    ) async throws -> [MediaAudioFrame] {
        // A cancelled caller may still have been queued behind close/open.
        // Reject it before touching whichever native instance is current now.
        try Task.checkCancellation()
        guard opened, let converter else { throw MediaEngineError.stopped }
        guard packet.track == .audio, !packet.data.isEmpty else { return [] }

        let box = InputBox(packet.data)

        let callback: AudioConverterComplexInputDataProc = { _, ioNumDataPackets, ioData, outPacketDesc, inUserData in
            guard let inUserData else { return -1 }
            let box = Unmanaged<InputBox>.fromOpaque(inUserData).takeUnretainedValue()
            box.entries += 1
            if box.consumed {
                // Back-pressure, not end of stream. Answering `noErr` here is
                // what permanently finished the converter; see
                // `converterNoInputDataAvailable`.
                ioNumDataPackets.pointee = 0
                box.toldToWait = true
                return converterNoInputDataAvailable
            }
            box.consumed = true
            ioData.pointee.mBuffers.mData = box.bytes
            ioData.pointee.mBuffers.mDataByteSize = UInt32(box.byteCount)
            // Compressed audio has no PCM channel layout in this buffer. A
            // non-zero value makes AudioConverter treat the AU as a
            // channelized PCM-like buffer; Apple's decoder callback uses 0.
            ioData.pointee.mBuffers.mNumberChannels = 0
            ioData.pointee.mNumberBuffers = 1
            ioNumDataPackets.pointee = 1
            // Hand the converter the AU's byte size (VBR) so it can parse it.
            box.packetDesc.pointee.mDataByteSize = UInt32(box.byteCount)
            outPacketDesc?.pointee = box.packetDesc
            return noErr
        }

        // One compressed AU contains `frameLength` core frames. Explicit SBR
        // produces the extension-rate PCM quantum (usually 2048 frames). Keep
        // the request to one AU; asking for more can make the converter request
        // a future packet and poison the one-AU callback. A FLAC frame holds at
        // most STREAMINFO's maximum block size; a shorter one (the last block,
        // or a variable-block stream) returns fewer frames — and a converter
        // that asks for more is told to wait, not handed a future packet.
        let frameLength = input?.compressedFramesPerPacket ?? 1_024
        let converterRatioCapacityFrames = Self.converterOutputFramesPerAccessUnit(
            compressedFrames: frameLength,
            inputSampleRate: inputSampleRate,
            outputSampleRate: nativeDecodedSampleRate
        )
        let expectedConfigurationFrames = input?.nativeFramesPerPacket ?? frameLength
        let converterCapacityFrames = max(
            expectedConfigurationFrames,
            converterRatioCapacityFrames
        )
        let expectedNativeFrames = converterCapacityFrames
        var pcm = [Float](
            repeating: 0,
            count: converterCapacityFrames * Int(outChannels)
        )
        var packetSize = UInt32(converterCapacityFrames)
        let userData = Unmanaged.passUnretained(box).toOpaque()
        // The converter may still reference the preceding input until its next
        // callback. Keep both boxes across this fill, then retain supplied input
        // beyond the return; a fill need not invoke another input callback.
        let convStatus: OSStatus = withExtendedLifetime((retainedConverterInput, box)) {
            pcm.withUnsafeMutableBytes { raw in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: outChannels,
                        mDataByteSize: UInt32(raw.count),
                        mData: raw.baseAddress
                    )
                )
                return AudioConverterFillComplexBuffer(
                    converter,
                    callback,
                    userData,
                    &packetSize,
                    &bufferList,
                    nil
                )
            }
        }
        if box.consumed {
            retainedConverterInput = box
        }
        // A verified zero-output fill can leave an older AU pending. It
        // does not lose the FIFO boundary unless this input was never taken,
        // the native call failed, or PCM ended partway through an AU.
        let frames = Int(packetSize)
        let currentInputWasAccepted = box.consumed
            && (convStatus == noErr || (convStatus == converterNoInputDataAvailable && box.toldToWait))
        // Keep the existing timing FIFO behavior. Only input the converter
        // actually accepted can transfer source display custody to that FIFO.
        pendingAccessUnits.append(PendingAccessUnit(
            pts: packet.pts,
            timing: packet.audioTiming,
            displayCoverage: currentInputWasAccepted ? packet.displayCoverage : nil
        ))
        nativeAccessUnitBoundaryKnown = nativeAccessUnitBoundaryKnown && currentInputWasAccepted
            && (frames == 0 || frames == expectedConfigurationFrames)
        let hasCompleteNativeAccessUnit = hasVerifiedNativePCMFormat && nativeAccessUnitBoundaryKnown
            && frames == expectedConfigurationFrames && !pendingAccessUnits.isEmpty
        // Some converters return `kAudioConverterErr_InvalidInputSize` once on EOS-like AU;
        // accept any produced frames. `converterNoInputDataAvailable` is this
        // boundary's OWN back-pressure signal rather than a converter fault:
        // the converter asked for a second access unit, was told to wait, and
        // returned whatever it already had.
        if convStatus != noErr, convStatus != converterNoInputDataAvailable, packetSize == 0 {
            recordDiagnostics(
                status: .converterError,
                converterStatus: convStatus,
                inputPacketConsumed: box.consumed,
                outputFrames: 0,
                callbackEntries: box.entries,
                callbackAskedForMore: box.toldToWait
            )
            // Retire only the entry THIS call pushed. `removeAll()` was a
            // desync: the queue legitimately holds more than one entry
            // whenever the converter withheld an earlier access unit (the
            // `frames == 0` guard below deliberately does not pop), which is
            // the normal HE-AAC priming state this whole FIFO exists for.
            // Dropping those older entries leaves their PCM still inside the
            // converter with no timing to pop back, so the next successful
            // decode stamps it with a NEWER packet's pts — a permanent A/V
            // offset that lasts until the next `flush()` and that nothing
            // downstream can detect. The failing access unit is the one the
            // converter just rejected, so it is the last one in.
            //
            // The `InvalidInputSize` branch is the one that provably keeps
            // decoding afterwards, so it is the one that bites; the throwing
            // branch is corrected too rather than resting on the assumption
            // that a fault always reaches `flush()` before the next decode.
            _ = pendingAccessUnits.popLast()
            if convStatus == kAudioConverterErr_InvalidInputSize {
                return []
            }
            throw MediaEngineError.decodeFailed("AudioConverterFill status=\(convStatus)")
        }
        guard frames > 0, frames <= converterCapacityFrames else {
            reportNoPCM(
                status: convStatus,
                frames: frames,
                requested: converterCapacityFrames,
                packet: packet,
                callbackEntries: box.entries,
                toldToWait: box.toldToWait
            )
            recordDiagnostics(
                status: box.toldToWait
                    ? .waitingForInput
                    : (box.entries == 0 ? .drained : .inputConsumedNoPCM),
                converterStatus: convStatus,
                inputPacketConsumed: box.consumed,
                outputFrames: 0,
                callbackEntries: box.entries,
                callbackAskedForMore: box.toldToWait
            )
            return []
        }
        // Associate converter output with the oldest accepted access unit.
        let emitted = pendingAccessUnits[0]
        let outputPCM: [Float]
        let outputFrames: Int
        let verifiedTail: AudioDisplayDecodedTail?
        if abs(nativeDecodedSampleRate - outSampleRate) <= 0.5 {
            outputPCM = Array(pcm.prefix(frames * Int(outChannels)))
            outputFrames = frames
            verifiedTail = hasCompleteNativeAccessUnit && nativeDecodedSampleRate == outSampleRate
                ? emitted.displayCoverage?.interval.map { .native($0.upper) } : nil
        } else {
            let verifiedInput = hasCompleteNativeAccessUnit && hasVerifiedSRCLayout
                ? verifiedResamplerInput(emitted, frames: frames) : nil
            let output = pcmResampler.process(pcm, frameCount: frames, verifiedSource: verifiedInput)
            outputPCM = output.pcm
            verifiedTail = output.verifiedSourceEnd.map { .resampled($0) }
            outputFrames = outputPCM.count / Int(outChannels)
        }
        guard outputFrames > 0 else {
            // The converter already handed back native PCM for the OLDEST
            // queued access unit (`frames > 0` above), so that entry's timing
            // is spent whether or not the resampler kept the samples. Leaving
            // it queued would hand it to the next successful decode instead —
            // one access unit of permanent pts drift. This is the opposite
            // case from the `frames == 0` guard above, where the access unit
            // really is still inside the converter and must stay queued.
            if !pendingAccessUnits.isEmpty {
                pendingAccessUnits.removeFirst()
            }
            reportNoPCM(
                status: convStatus,
                frames: frames,
                requested: converterCapacityFrames,
                packet: packet,
                callbackEntries: box.entries,
                toldToWait: box.toldToWait,
                stage: "resample"
            )
            recordDiagnostics(
                status: .inputConsumedNoPCM,
                converterStatus: convStatus,
                inputPacketConsumed: box.consumed,
                outputFrames: frames,
                callbackEntries: box.entries,
                callbackAskedForMore: box.toldToWait
            )
            return []
        }
        let displayInterval = MediaDisplayInterval.pcm(
            start: emitted.displayCoverage?.interval?.lower, frames: outputFrames, rate: outSampleRate
        )
        pendingDisplaySupport.install(
            source: emitted.displayCoverage,
            interval: displayInterval,
            verifiedTail: verifiedTail
        )
        // The PCM that just came out belongs to the OLDEST access unit still
        // inside the converter, which is this packet only while the boundary
        // stays 1-in/1-out. Popping keeps that assumption honest instead of
        // implicit.
        if !pendingAccessUnits.isEmpty { pendingAccessUnits.removeFirst() }
        if framesProduced < 4 {
            PlayerLog.log(
                "[PathA] \(logLabel) decoded nativeFramesIn=\(frames) framesOut=\(outputFrames) " +
                    "rate=\(Int(inputSampleRate))->\(Int(nativeDecodedSampleRate))->\(Int(outSampleRate)) " +
                    "expectedNative=\(expectedNativeFrames) bytesPerFrame=\(Int(outChannels) * MemoryLayout<Float>.size) " +
                    "status=\(convStatus) cbEntries=\(box.entries) " +
                    "cbWait=\(box.toldToWait ? 1 : 0) pend=\(pendingAccessUnits.count)" +
                    (packet.audioTiming.map {
                        " ptsTicks=\($0.ptsTicks) dtsTicks=\($0.dtsTicks) " +
                        "durTicks=\($0.durationTicks) ts=\($0.trackTimescale) " +
                        "effectiveTS=\(String(format: "%.3f", $0.effectiveTimescale))"
                    } ?? "")
            )
        }
        // Mono -> stereo, last thing before the boundary. After the resampler,
        // because the resampler is built for the decoded channel count; and
        // frame COUNT is unchanged by duplication, so `duration` below still
        // divides frames by the rate.
        let emittedPCM: [Float]
        let emittedChannels: Int
        if duplicatesMonoToStereo {
            var stereo = [Float]()
            stereo.reserveCapacity(outputPCM.count * 2)
            for sample in outputPCM {
                stereo.append(sample)
                stereo.append(sample)
            }
            emittedPCM = stereo
            emittedChannels = Int(Self.engineChannelCount)
        } else {
            emittedPCM = outputPCM
            emittedChannels = Int(outChannels)
        }
        let pcmData = emittedPCM.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        let duration = TimeInterval(outputFrames) / outSampleRate
        framesProduced += 1
        recordDiagnostics(
            status: .producedPCM,
            converterStatus: convStatus,
            inputPacketConsumed: box.consumed,
            outputFrames: outputFrames,
            callbackEntries: box.entries,
            callbackAskedForMore: box.toldToWait
        )
        return [
            MediaAudioFrame(
                pts: emitted.pts,
                duration: duration,
                sampleRate: outSampleRate,
                channelCount: emittedChannels,
                pcm: pcmData,
                decodeTiming: emitted.timing.map {
                    MediaAudioDecodeTiming(
                        packet: $0,
                        decodedInputFrames: frames,
                        resampledOutputFrames: outputFrames,
                        decoderInputSampleRate: inputSampleRate,
                        decoderOutputSampleRate: nativeDecodedSampleRate
                    )
                }
            )
        ]
    }

    func flush() async {
        guard !Task.isCancelled else { return }
        if let converter {
            let status = withExtendedLifetime(retainedConverterInput) {
                AudioConverterReset(converter)
            }
            nativeAccessUnitBoundaryKnown = status == noErr
            if status == noErr {
                retainedConverterInput = nil
            }
        }
        // Preserve the existing post-seek timing reset. Input storage has the
        // separate native boundary above: a failed reset must keep it alive.
        pendingAccessUnits.removeAll()
        noPCMReturns = 0
        lastDiagnostics = MediaAudioDecodeDiagnostics(
            status: .idle,
            converterStatus: nil,
            inputPacketConsumed: false,
            outputFrames: 0,
            inputCallbackRequests: 0,
            inputCallbackAskedForMore: false,
            pendingAccessUnits: 0,
            noPCMReturns: 0
        )
        resetResampler()
    }

    func close() async {
        closeNative()
    }

    private func closeNative() {
        if let converter {
            _ = withExtendedLifetime(retainedConverterInput) {
                AudioConverterDispose(converter)
            }
        }
        converter = nil
        opened = false
        // Terminal handle: dispose before input release; never reuse even on a disposal error.
        retainedConverterInput = nil
        inputSampleRate = 44_100
        nativeDecodedSampleRate = 44_100
        outChannels = 2
        hasVerifiedNativePCMFormat = false
        hasVerifiedSRCLayout = false
        nativeAccessUnitBoundaryKnown = false
        input = nil
        pendingAccessUnits.removeAll()
        noPCMReturns = 0
        lastDiagnostics = MediaAudioDecodeDiagnostics(
            status: .idle,
            converterStatus: nil,
            inputPacketConsumed: false,
            outputFrames: 0,
            inputCallbackRequests: 0,
            inputCallbackAskedForMore: false,
            pendingAccessUnits: 0,
            noPCMReturns: 0
        )
        resetResampler()
    }

    /// The converter consumed an access unit and produced no PCM.
    ///
    /// This was a bare `return []` at four separate points in `decode`. The
    /// success log sits after all four and `framesProduced` only counts
    /// successes, so a decoder producing nothing was indistinguishable in a
    /// device log from one that was never called — the only symptom that ever
    /// reached the user was `launch reserve unavailable audio=0`, several
    /// hundred milliseconds later and naming the wrong layer.
    ///
    /// Reporting changes no control flow. `cbEntries`/`cbWait` are what
    /// separate the two failure shapes that look identical from outside:
    /// `cbEntries=0` means the converter no longer asks this boundary for
    /// input at all (it considers itself finished), while `cbEntries=1
    /// cbWait=0 outFrames=0` means it took the access unit and rejected it.
    private func reportNoPCM(
        status: OSStatus,
        frames: Int,
        requested: Int,
        packet: MediaPacket,
        callbackEntries: Int,
        toldToWait: Bool,
        stage: String = "convert"
    ) {
        noPCMReturns += 1
        // Loud at the start (prime failures happen in the first few AUs), then
        // sparse, so a long broken stream cannot flood the ring buffer.
        guard noPCMReturns <= 8 || noPCMReturns % 100 == 0 else { return }
        PlayerLog.log(
            "[PathA] \(logLabel) no PCM #\(noPCMReturns) stage=\(stage) status=\(status) " +
            "outFrames=\(frames) reqFrames=\(requested) auBytes=\(packet.data.count) " +
            "pts=\(String(format: "%.6f", packet.pts)) " +
            "cbEntries=\(callbackEntries) cbWait=\(toldToWait ? 1 : 0) " +
            "pend=\(pendingAccessUnits.count) ok=\(framesProduced) " +
            "in=\(Int(inputSampleRate))Hz native=\(Int(nativeDecodedSampleRate))Hz"
        )
    }

    /// `AAC` / `FLAC` in log lines; `AAC` while closed, as every line read
    /// before FLAC existed.
    private var logLabel: String {
        input?.logLabel ?? "AAC"
    }

    private func recordDiagnostics(
        status: MediaAudioDecodeStatus,
        converterStatus: OSStatus?,
        inputPacketConsumed: Bool,
        outputFrames: Int,
        callbackEntries: Int,
        callbackAskedForMore: Bool
    ) {
        lastDiagnostics = MediaAudioDecodeDiagnostics(
            status: status,
            converterStatus: converterStatus,
            inputPacketConsumed: inputPacketConsumed,
            outputFrames: max(0, outputFrames),
            inputCallbackRequests: max(0, callbackEntries),
            inputCallbackAskedForMore: callbackAskedForMore,
            pendingAccessUnits: pendingAccessUnits.count,
            noPCMReturns: noPCMReturns
        )
    }

    private func verifiedResamplerInput(_ unit: PendingAccessUnit, frames: Int) -> MediaDisplayLease? {
        guard let source = unit.displayCoverage, source.isCurrent,
              let interval = source.interval, let timing = unit.timing,
              timing.effectiveTimescale == Double(timing.trackTimescale) else { return nil }
        let scale = Int64(timing.trackTimescale)
        let declaredEnd = timing.ptsTicks.addingReportingOverflow(Int64(timing.durationTicks))
        guard !declaredEnd.overflow,
              MediaDisplayTime(timing.ptsTicks, scale: scale) == interval.lower,
              MediaDisplayTime(declaredEnd.partialValue, scale: scale) == interval.upper,
              interval.lower.adding(frames: frames, sampleRate: nativeDecodedSampleRate) == interval.upper
        else { return nil }
        return source
    }

    private func resetResampler() {
        pcmResampler.reset()
    }
}
