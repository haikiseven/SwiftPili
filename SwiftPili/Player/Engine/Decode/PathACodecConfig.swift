import CoreMedia
import Foundation

/// Path A D3 — build CoreMedia format descriptions / AAC ASC from fMP4
/// sample-entry config boxes (avcC / hvcC payloads from `PathAFMP4.TrackInfo.config`).
enum PathACodecConfig {
    /// The rate fields in an AAC AudioSpecificConfig have different meanings
    /// when SBR/PS is explicitly signalled.  Keep those meanings separate from
    /// the rate at which the engine eventually publishes PCM.
    struct AACConfiguration: Equatable, Sendable {
        let audioObjectType: Int
        let coreAudioObjectType: Int
        let coreSampleRate: Double
        let extensionSampleRate: Double?
        let outputSampleRate: Double
        /// Channel count carried by the AAC core bitstream.
        let coreChannels: UInt32
        /// Decoded PCM channel count. Parametric Stereo expands mono core AAC
        /// to stereo output, so this can differ from `coreChannels`.
        let channels: UInt32
        let sbrPresent: Bool
        let psPresent: Bool
        let frameLength: Int

        var isAAC: Bool {
            coreAudioObjectType == 1 || coreAudioObjectType == 2
        }

        /// Number of PCM frames represented at the decoder's native/output
        /// rate by one core AAC access unit. SBR doubles this quantum while
        /// AAC-LC keeps it at 1024 (or the signalled 960-frame mode).
        var nativeFramesPerAccessUnit: Int {
            max(1, Int((Double(frameLength) * outputSampleRate / coreSampleRate).rounded()))
        }
    }

    static func makeVideoFormatDescription(
        codec: String,
        config: Data,
        codedDimensions: MediaVideoCodedDimensions? = nil
    ) throws -> CMFormatDescription {
        switch codec.lowercased() {
        case "avc1", "avc3":
            return try h264FormatDescription(avcC: config)
        case "hvc1", "hev1", "dvh1", "dvhe":
            return try hevcFormatDescription(hvcC: config)
        case "av01":
            guard let codedDimensions else {
                throw MediaEngineError.decodeFailed("AV1 coded dimensions missing or invalid in video track")
            }
            return try av1FormatDescription(av1C: config, codedDimensions: codedDimensions)
        default:
            throw MediaEngineError.decodeFailed(
                "unsupported video codec fourcc=\(codec) for VT open"
            )
        }
    }

    /// Extract AAC AudioSpecificConfig from an esds descriptor, or accept a
    /// short bare ASC as-is.
    ///
    /// Do not scan for an arbitrary `0x05` byte.  `esds` contains 32-bit
    /// bitrate fields before DecoderSpecificInfo, so a bitrate byte can look
    /// exactly like the DecoderSpecificInfo descriptor tag and produce a
    /// plausible-looking but completely wrong ASC.  The failing device asset
    /// had that shape: the old scan returned the expandable-length bytes plus
    /// one ASC byte (`80 80 80 02 12`) and subsequently reported AOT 16/88.2
    /// kHz instead of the AAC-LC 44.1 kHz descriptor later in the ES descriptor.
    static func aacAudioSpecificConfig(fromESDSOrASC data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)

        let structuralTags: Set<UInt8> = [0x03, 0x04, 0x05]
        // A short descriptor is still a descriptor. Parse it before accepting
        // bare ASC so `[05 02]`, truncated ES descriptors, and overlong
        // expandable lengths fail closed instead of becoming plausible codec
        // bits.
        if let first = bytes.first, structuralTags.contains(first) {
            return findDecoderSpecificInfo(bytes, in: 0..<bytes.count)
        }

        // An `esds` payload starts with FullBox version/flags. Some callers
        // hand us the descriptor stream without those four bytes; choose the
        // root from the actual structural tag instead of searching both roots
        // and accidentally treating FullBox/payload bytes as descriptors.
        if bytes.count > 4,
           bytes[0] == 0,
           structuralTags.contains(bytes[4]) {
            return findDecoderSpecificInfo(bytes, in: 4..<bytes.count)
        }

        if data.count >= 2, data.count <= 8 { return data }
        // Descriptor streams may legally contain unknown sibling tags. The
        // walker skips each one by its declared boundary and can then reach a
        // following ES/DecoderConfig descriptor without scanning its payload.
        return findDecoderSpecificInfo(bytes, in: 0..<bytes.count)
    }

    /// Walk the MPEG-4 descriptor hierarchy far enough to reach tag 0x05.
    /// DecoderConfigDescriptor has 13 fixed bytes before its child
    /// descriptors; ES_Descriptor has a small flag-dependent prefix.  Parsing
    /// those boundaries is what prevents bitrate data from being interpreted
    /// as a child tag.
    private static func findDecoderSpecificInfo(
        _ bytes: [UInt8],
        in range: Range<Int>
    ) -> Data? {
        guard range.lowerBound >= 0,
              range.lowerBound <= range.upperBound,
              range.upperBound <= bytes.count else { return nil }
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor < bytes.count,
                  let (length, lengthBytes) = readExpandableLength(bytes, at: cursor + 1)
            else { return nil }
            let (tagEnd, tagOverflow) = cursor.addingReportingOverflow(1)
            let (payloadStart, headerOverflow) = tagEnd.addingReportingOverflow(lengthBytes)
            let (payloadEnd, payloadOverflow) = payloadStart.addingReportingOverflow(length)
            guard !tagOverflow, !headerOverflow, !payloadOverflow,
                  payloadStart <= payloadEnd,
                  payloadEnd <= range.upperBound,
                  payloadEnd <= bytes.count else { return nil }

            switch bytes[cursor] {
            case 0x05:
                guard length > 0 else { return nil }
                return Data(bytes[payloadStart..<payloadEnd])
            case 0x03:
                // ES_ID (2) + flags (1), followed by optional dependency URL,
                // OCR ES_ID, and then nested descriptors.
                guard length >= 3 else { return nil }
                let flags = bytes[payloadStart + 2]
                var childStart = payloadStart + 3
                if flags & 0x80 != 0 {
                    // streamDependenceFlag: dependsOn_ES_ID (2 bytes).
                    guard payloadEnd - childStart >= 2 else { return nil }
                    childStart += 2
                }
                if flags & 0x40 != 0 {
                    // URL_Flag: URLlength (1) followed by URLstring.
                    guard childStart < payloadEnd else { return nil }
                    let urlLength = Int(bytes[childStart])
                    guard payloadEnd - childStart - 1 >= urlLength else { return nil }
                    childStart += 1 + urlLength
                }
                if flags & 0x20 != 0 {
                    // OCRstreamFlag: OCR_ES_Id (2 bytes).
                    guard payloadEnd - childStart >= 2 else { return nil }
                    childStart += 2
                }
                guard childStart <= payloadEnd else { return nil }
                if let asc = findDecoderSpecificInfo(
                    bytes,
                    in: childStart..<payloadEnd
                ) {
                    return asc
                }
            case 0x04:
                // objectTypeIndication(1), streamType/upstream/reserved(1),
                // bufferSizeDB(3), maxBitrate(4), avgBitrate(4).
                guard payloadEnd - payloadStart >= 13 else { return nil }
                let childStart = payloadStart + 13
                if let asc = findDecoderSpecificInfo(
                    bytes,
                    in: childStart..<payloadEnd
                ) {
                    return asc
                }
            default:
                break
            }
            cursor = payloadEnd
        }
        return nil
    }

    /// Parse the AAC AudioSpecificConfig without collapsing the core and SBR
    /// rates into one value.  For AAC-LC the core and output rates are the same.
    /// For explicit HE-AAC, `samplingFrequencyIndex` is the AAC core rate and
    /// `extensionSamplingFrequencyIndex` is the SBR output rate.
    static func aacConfiguration(fromESDSOrASC data: Data) -> AACConfiguration? {
        guard let asc = aacAudioSpecificConfig(fromESDSOrASC: data), asc.count >= 2 else {
            return nil
        }
        let bytes = [UInt8](asc)
        var reader = AACBitReader(bytes)
        guard let declaredAOT = reader.readAudioObjectType(),
              let firstRate = reader.readSamplingFrequency(),
              let channelConfiguration = reader.read(bits: 4)
        else { return nil }

        var coreAOT = declaredAOT
        let coreRate = firstRate
        var extensionRate: Double?
        var sbrPresent = false
        var psPresent = false

        if declaredAOT == 5 || declaredAOT == 29 {
            // Explicit hierarchical SBR/PS signalling. The first frequency is
            // the AAC core rate; the following frequency is the extension/output
            // rate, and the nested AOT names the core decoder.
            sbrPresent = true
            psPresent = declaredAOT == 29
            guard let extRate = reader.readSamplingFrequency(),
                  let nestedAOT = reader.readAudioObjectType()
            else { return nil }
            extensionRate = extRate
            coreAOT = nestedAOT
        }

        let coreChannels: UInt32
        switch channelConfiguration {
        case 1...6: coreChannels = UInt32(channelConfiguration)
        case 7: coreChannels = 8
        // ProgramConfigElement and reserved layouts are not parsed here. Do
        // not silently invent stereo; fail before constructing an ASBD.
        default: return nil
        }

        // GASpecificConfig starts with frameLengthFlag, dependsOnCoreCoder,
        // and extensionFlag. A dependent core carries an additional 14-bit
        // delay before extensionFlag; respecting it keeps the sync-extension
        // search rooted after the GA fields.
        guard let frameLengthFlag = reader.read(bits: 1),
              let dependsOnCoreCoder = reader.read(bits: 1)
        else { return nil }
        if dependsOnCoreCoder == 1, reader.read(bits: 14) == nil { return nil }
        // Some deployed HE-AAC cookies end immediately after the first two GA
        // flags (for example `2b9208`) and imply a false extensionFlag. Keep
        // that established representation compatible; any following bits are
        // still parsed from their exact boundary.
        _ = reader.read(bits: 1)
        let frameLength = frameLengthFlag == 1 ? 960 : 1024

        // AAC-LC may carry an explicit syncExtension after GASpecificConfig. It
        // is not required for the failing fixture, but recognizing it prevents
        // the rate parser from silently treating an HE-AAC/PS stream as LC.
        if !sbrPresent,
           coreAOT == 2,
           let sync = reader.readSyncExtension() {
            sbrPresent = sync.sbrPresent
            psPresent = sync.psPresent
            if sbrPresent {
                extensionRate = sync.sampleRate
            }
        }
        let channels = psPresent && coreChannels == 1 ? 2 : coreChannels
        return AACConfiguration(
            audioObjectType: declaredAOT,
            coreAudioObjectType: coreAOT,
            coreSampleRate: coreRate,
            extensionSampleRate: extensionRate,
            outputSampleRate: extensionRate ?? coreRate,
            coreChannels: coreChannels,
            channels: channels,
            sbrPresent: sbrPresent,
            psPresent: psPresent,
            frameLength: frameLength
        )
    }

    private struct AACBitReader {
        let bytes: [UInt8]
        private(set) var bitIndex = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var remainingBits: Int { bytes.count * 8 - bitIndex }

        mutating func read(bits count: Int) -> Int? {
            guard count >= 0, remainingBits >= count else { return nil }
            var value = 0
            for _ in 0..<count {
                let byte = bitIndex >> 3
                let shift = 7 - (bitIndex & 7)
                value = (value << 1) | Int((bytes[byte] >> shift) & 1)
                bitIndex += 1
            }
            return value
        }

        mutating func readAudioObjectType() -> Int? {
            guard let value = read(bits: 5) else { return nil }
            if value == 31 {
                guard let extensionValue = read(bits: 6) else { return nil }
                return 32 + extensionValue
            }
            return value
        }

        mutating func readSamplingFrequency() -> Double? {
            guard let index = read(bits: 4) else { return nil }
            let table: [Double] = [
                96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
                22_050, 16_000, 12_000, 11_025, 8_000, 7_350
            ]
            if index == 15 {
                guard let explicit = read(bits: 24), explicit > 0 else { return nil }
                return Double(explicit)
            }
            guard index < table.count else { return nil }
            return table[index]
        }

        mutating func readSyncExtension() -> (sampleRate: Double?, sbrPresent: Bool, psPresent: Bool)? {
            // The syncExtension follows GASpecificConfig. Require the complete
            // 11-bit marker, extension AOT 5, SBR flag, and (when present) its
            // extension rate. The previous parser read the extension AOT's
            // first bit as `sbrPresentFlag`, shifting every implicit HE-AAC
            // field by five bits.
            guard remainingBits >= 17 else { return nil }
            let saved = bitIndex
            while remainingBits >= 17 {
                guard let marker = read(bits: 11) else { break }
                if marker == 0x2b7,
                   let extensionAOT = readAudioObjectType(),
                   extensionAOT == 5,
                   let sbr = read(bits: 1) {
                    var extensionRate: Double?
                    if sbr == 1 {
                        guard let rate = readSamplingFrequency() else {
                            bitIndex = saved
                            return nil
                        }
                        extensionRate = rate
                    }
                    var ps = false
                    if sbr == 1, remainingBits >= 12 {
                        let beforePS = bitIndex
                        if let psMarker = read(bits: 11),
                           psMarker == 0x548,
                           let psFlag = read(bits: 1) {
                            ps = psFlag == 1
                        } else {
                            bitIndex = beforePS
                        }
                    }
                    return (extensionRate, sbr == 1, ps)
                }
                if marker == 0x2b7 {
                    // A complete sync marker with malformed/unsupported
                    // extension syntax is authoritative; do not search its
                    // payload for another marker.
                    bitIndex = saved
                    return nil
                }
                bitIndex -= 10
            }
            bitIndex = saved
            return nil
        }
    }

    /// The AAC magic cookie AudioConverter expects = the ES_Descriptor (esds box
    /// contents starting at tag `0x03`), with the FullBox version+flags stripped.
    /// Returns nil for a bare ASC (nothing to hand AudioConverter — decode from
    /// the ASBD alone for AAC-LC).
    static func aacMagicCookie(fromESDS data: Data) -> Data? {
        let bytes = [UInt8](data)
        if let first = bytes.first, first == 0x03 { return data }   // already ES descriptor
        if bytes.count > 4, bytes[4] == 0x03 { return Data(bytes[4...]) } // strip version/flags
        return nil
    }

    // MARK: - H.264

    private static func h264FormatDescription(avcC: Data) throws -> CMFormatDescription {
        // AVCDecoderConfigurationRecord (ISO 14496-15):
        // version(1) profile(1) compat(1) level(1) lengthSizeMinusOne(1) numSPS(1) …
        guard avcC.count >= 7 else {
            throw MediaEngineError.decodeFailed("avcC too short (\(avcC.count))")
        }
        let bytes = [UInt8](avcC)
        var offset = 4
        let nalLengthSize = Int(bytes[offset] & 0x03) + 1
        offset += 1
        let numSPS = Int(bytes[offset] & 0x1F)
        offset += 1
        var sets: [Data] = []
        for _ in 0..<numSPS {
            guard offset + 2 <= bytes.count else { break }
            let n = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard n > 0, offset + n <= bytes.count else { break }
            sets.append(Data(bytes[offset..<(offset + n)]))
            offset += n
        }
        guard offset < bytes.count else {
            throw MediaEngineError.decodeFailed(
                "avcC missing PPS (sps=\(sets.count) off=\(offset) len=\(avcC.count))"
            )
        }
        let numPPS = Int(bytes[offset])
        offset += 1
        for _ in 0..<numPPS {
            guard offset + 2 <= bytes.count else { break }
            let n = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard n > 0, offset + n <= bytes.count else { break }
            sets.append(Data(bytes[offset..<(offset + n)]))
            offset += n
        }
        guard sets.count >= 2 else {
            throw MediaEngineError.decodeFailed(
                "avcC need SPS+PPS, got \(sets.count) numSPS=\(numSPS) numPPS=\(numPPS)"
            )
        }
        return try createH264FormatDescription(parameterSets: sets, nalLengthSize: nalLengthSize)
    }

    private static func createH264FormatDescription(
        parameterSets: [Data],
        nalLengthSize: Int
    ) throws -> CMFormatDescription {
        // Flatten into one buffer with stable offsets so pointers remain valid.
        var flat = Data()
        var ranges: [Range<Int>] = []
        for set in parameterSets {
            let start = flat.count
            flat.append(set)
            ranges.append(start..<(start + set.count))
        }
        return try flat.withUnsafeBytes { raw -> CMFormatDescription in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw MediaEngineError.decodeFailed("avcC empty base")
            }
            var pointers: [UnsafePointer<UInt8>] = ranges.map { base + $0.lowerBound }
            var sizes: [Int] = ranges.map(\.count)
            var formatOut: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: Int32(nalLengthSize),
                formatDescriptionOut: &formatOut
            )
            guard status == noErr, let formatOut else {
                throw MediaEngineError.decodeFailed(
                    "CMVideoFormatDescriptionCreateFromH264ParameterSets status=\(status)"
                )
            }
            return formatOut
        }
    }

    // MARK: - HEVC

    private static func hevcFormatDescription(hvcC: Data) throws -> CMFormatDescription {
        guard hvcC.count >= 23 else {
            throw MediaEngineError.decodeFailed("hvcC too short (\(hvcC.count))")
        }
        let bytes = [UInt8](hvcC)
        let nalLengthSize = Int(bytes[21] & 0x03) + 1
        var offset = 22
        guard offset < bytes.count else {
            throw MediaEngineError.decodeFailed("hvcC no numOfArrays")
        }
        let numArrays = Int(bytes[offset])
        offset += 1
        var sets: [Data] = []
        for _ in 0..<numArrays {
            guard offset + 3 <= bytes.count else { break }
            offset += 1 // NAL type byte
            let numNalus = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            for _ in 0..<numNalus {
                guard offset + 2 <= bytes.count else { break }
                let n = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + n <= bytes.count else { break }
                sets.append(Data(bytes[offset..<(offset + n)]))
                offset += n
            }
        }
        guard !sets.isEmpty else {
            throw MediaEngineError.decodeFailed("hvcC empty parameter sets")
        }
        var flat = Data()
        var ranges: [Range<Int>] = []
        for set in sets {
            let start = flat.count
            flat.append(set)
            ranges.append(start..<(start + set.count))
        }
        return try flat.withUnsafeBytes { raw -> CMFormatDescription in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw MediaEngineError.decodeFailed("hvcC empty base")
            }
            var pointers: [UnsafePointer<UInt8>] = ranges.map { base + $0.lowerBound }
            var sizes: [Int] = ranges.map(\.count)
            var formatOut: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: Int32(nalLengthSize),
                extensions: nil,
                formatDescriptionOut: &formatOut
            )
            guard status == noErr, let formatOut else {
                throw MediaEngineError.decodeFailed(
                    "CMVideoFormatDescriptionCreateFromHEVCParameterSets status=\(status)"
                )
            }
            return formatOut
        }
    }

    // MARK: - AV1

    private static func av1FormatDescription(
        av1C: Data,
        codedDimensions: MediaVideoCodedDimensions
    ) throws -> CMFormatDescription {
        guard !av1C.isEmpty else {
            throw MediaEngineError.decodeFailed("av1C empty")
        }
        // Prefer SampleDescriptionExtensionAtoms — VT accepts av1C blob without
        // full OBU split (device Path A D3 soak).
        let atoms: [CFString: CFData] = [
            "av1C" as CFString: av1C as CFData
        ]
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms
        ]
        var formatOut: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1,
            width: codedDimensions.width,
            height: codedDimensions.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatOut
        )
        guard status == noErr, let formatOut else {
            throw MediaEngineError.decodeFailed(
                "CMVideoFormatDescriptionCreate AV1 status=\(status)"
            )
        }
        return formatOut
    }

    private static func readExpandableLength(_ bytes: [UInt8], at start: Int) -> (Int, Int)? {
        guard start >= 0, start < bytes.count else { return nil }
        var i = start
        var len = 0
        var count = 0
        while i < bytes.count, count < 4 {
            let b = bytes[i]
            i += 1
            count += 1
            len = (len << 7) | Int(b & 0x7F)
            if b & 0x80 == 0 { return (len, count) }
        }
        return nil
    }
}
