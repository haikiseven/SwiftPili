import AudioToolbox
import Foundation

private let converterNoInputDataAvailable: OSStatus = 0x6E6F_6474

actor AudioToolboxAudioDecoder: MediaAudioDecoding {
    private struct ConverterHandle: @unchecked Sendable {
        let ref: AudioConverterRef
    }

    private var converter: ConverterHandle?
    private var retainedConverterInput: InputBox?
    private var opened = false
    private var inputSampleRate: Double = 44_100
    private var nativeDecodedSampleRate: Double = 44_100
    private var outSampleRate: Double = 48_000
    static let engineChannelCount: UInt32 = 2
    private var outChannels: UInt32 = 2
    private var duplicatesMonoToStereo = false
    private var input: AudioToolboxInput?
    private var pcmResampler = PCMLinearResampler(
        inputSampleRate: 44_100,
        outputSampleRate: 48_000,
        channelCount: 2
    )
    private(set) var framesProduced = 0
    private var pendingAccessUnits: [PendingAccessUnit] = []
    private var hasVerifiedNativePCMFormat = false
    private var hasVerifiedSRCLayout = false
    private var nativeAccessUnitBoundaryKnown = false
    private var noPCMReturns = 0
    private var lastDiagnostics = MediaAudioDecodeDiagnostics.unavailable

    deinit {
        if let converter {
            _ = withExtendedLifetime(retainedConverterInput) {
                AudioConverterDispose(converter.ref)
            }
        }
    }

    private struct PendingAccessUnit {
        let pts: TimeInterval
        let timing: MediaAudioPacketTiming?
        let displayCoverage: MediaDisplayLease?
    }

    private final class InputBox: @unchecked Sendable {
        let bytes: UnsafeMutableRawPointer
        let byteCount: Int
        var consumed = false
        var entries = 0
        var toldToWait = false
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

    func open(formatHint: Data?) async throws {
        try openNative(codec: nil, formatHint: formatHint)
    }

    func open(codec: String?, formatHint: Data?) async throws {
        try openNative(codec: codec, formatHint: formatHint)
    }

    private func openNative(codec: String?, formatHint: Data?) throws {
        try Task.checkCancellation()
        closeNative()
        let input = try AudioToolboxInput.resolve(codec: codec, formatHint: formatHint)
        let label = input.logLabel
        let requestedInputSampleRate = input.decodedSampleRate
        let requestedNativeSampleRate = input.decodedSampleRate
        let requestedOutputChannels = input.requestedOutputChannels
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

        var inASBD = input.inputDescription

        var converterOut: AudioConverterRef?
        let status = AudioConverterNew(&inASBD, &outASBD, &converterOut)
        guard status == noErr, let converterOut else {
            throw MediaEngineError.decodeFailed("AudioConverterNew status=\(status)")
        }
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
        self.converter = ConverterHandle(ref: converterOut)
        var openSucceeded = false
        defer {
            if !openSucceeded {
                closeNative()
            }
        }
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
        if abs(negotiatedInputRate - negotiatedOutputRate) > 0.5 {
            throw MediaEngineError.notImplemented(
                "\(label) converter negotiated \(Int(negotiatedInputRate))Hz in / " +
                "\(Int(negotiatedOutputRate))Hz out; a rate conversion inside the " +
                "converter makes it request access units this boundary supplies " +
                "one at a time, and it stops producing PCM after the first"
            )
        }
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
        openSucceeded = true
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
        try Task.checkCancellation()
        guard opened, let converter else { throw MediaEngineError.stopped }
        guard packet.track == .audio, !packet.data.isEmpty else { return [] }

        let box = InputBox(packet.data)

        let callback: AudioConverterComplexInputDataProc = { _, ioNumDataPackets, ioData, outPacketDesc, inUserData in
            guard let inUserData else { return -1 }
            let box = Unmanaged<InputBox>.fromOpaque(inUserData).takeUnretainedValue()
            box.entries += 1
            if box.consumed {
                ioNumDataPackets.pointee = 0
                box.toldToWait = true
                return converterNoInputDataAvailable
            }
            box.consumed = true
            ioData.pointee.mBuffers.mData = box.bytes
            ioData.pointee.mBuffers.mDataByteSize = UInt32(box.byteCount)
            ioData.pointee.mBuffers.mNumberChannels = 0
            ioData.pointee.mNumberBuffers = 1
            ioNumDataPackets.pointee = 1
            box.packetDesc.pointee.mDataByteSize = UInt32(box.byteCount)
            outPacketDesc?.pointee = box.packetDesc
            return noErr
        }

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
                    converter.ref,
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
        let frames = Int(packetSize)
        let currentInputWasAccepted = box.consumed
            && (convStatus == noErr || (convStatus == converterNoInputDataAvailable && box.toldToWait))
        pendingAccessUnits.append(PendingAccessUnit(
            pts: packet.pts,
            timing: packet.audioTiming,
            displayCoverage: currentInputWasAccepted ? packet.displayCoverage : nil
        ))
        nativeAccessUnitBoundaryKnown = nativeAccessUnitBoundaryKnown && currentInputWasAccepted
            && (frames == 0 || frames == expectedConfigurationFrames)
        let hasCompleteNativeAccessUnit = hasVerifiedNativePCMFormat && nativeAccessUnitBoundaryKnown
            && frames == expectedConfigurationFrames && !pendingAccessUnits.isEmpty
        if convStatus != noErr, convStatus != converterNoInputDataAvailable, packetSize == 0 {
            recordDiagnostics(
                status: .converterError,
                converterStatus: convStatus,
                inputPacketConsumed: box.consumed,
                outputFrames: 0,
                callbackEntries: box.entries,
                callbackAskedForMore: box.toldToWait
            )
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
                AudioConverterReset(converter.ref)
            }
            nativeAccessUnitBoundaryKnown = status == noErr
            if status == noErr {
                retainedConverterInput = nil
            }
        }
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
                AudioConverterDispose(converter.ref)
            }
        }
        converter = nil
        opened = false
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
