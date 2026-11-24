import CoreMedia
import Foundation

enum PathACodecConfig {
    struct AACConfiguration: Equatable, Sendable {
        let audioObjectType: Int
        let coreAudioObjectType: Int
        let coreSampleRate: Double
        let extensionSampleRate: Double?
        let outputSampleRate: Double
        let coreChannels: UInt32
        let channels: UInt32
        let sbrPresent: Bool
        let psPresent: Bool
        let frameLength: Int

        var isAAC: Bool {
            coreAudioObjectType == 1 || coreAudioObjectType == 2
        }

        var nativeFramesPerAccessUnit: Int {
            max(1, Int((Double(frameLength) * outputSampleRate / coreSampleRate).rounded()))
        }
    }

    enum InBandVideoCodec: Sendable {
        case h264
        case hevc
    }

    static func inBandBootstrap(codec: String?, config: Data) -> (codec: InBandVideoCodec, nalLengthSize: Int)? {
        switch codec?.lowercased() {
        case "avc3":
            let nalLengthSize = config.count >= 5 ? Int(config[4] & 0x03) + 1 : 4
            return (.h264, nalLengthSize)
        case "hev1":
            let nalLengthSize = config.count >= 22 ? Int(config[21] & 0x03) + 1 : 4
            return (.hevc, nalLengthSize)
        default:
            return nil
        }
    }

    static func makeInBandFormatDescription(
        codec: InBandVideoCodec,
        parameterSets: [Data],
        nalLengthSize: Int
    ) throws -> CMFormatDescription {
        switch codec {
        case .h264:
            return try createH264FormatDescription(parameterSets: parameterSets, nalLengthSize: nalLengthSize)
        case .hevc:
            return try createHEVCFormatDescription(parameterSets: parameterSets, nalLengthSize: nalLengthSize)
        }
    }

    static func extractInBandParameterSets(
        from data: Data,
        nalLengthSize: Int,
        codec: InBandVideoCodec
    ) -> [Data]? {
        guard (1...4).contains(nalLengthSize), data.count > nalLengthSize else { return nil }
        return data.withUnsafeBytes { raw -> [Data]? in
            let total = raw.count
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var offset = 0
            var sets: [Data]?
            var hasSPS = false
            var hasPPS = false
            while offset + nalLengthSize <= total {
                let nalLength: Int
                if nalLengthSize == 4 {
                    nalLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
                } else {
                    var length = 0
                    for i in 0..<nalLengthSize {
                        length = (length << 8) | Int(base[offset + i])
                    }
                    nalLength = length
                }
                offset += nalLengthSize
                guard nalLength > 0, offset + nalLength <= total else { break }
                let header = base[offset]
                let isParameterSet: Bool
                switch codec {
                case .h264:
                    let type = header & 0x1F
                    if type == 7 { hasSPS = true; isParameterSet = true }
                    else if type == 8 { hasPPS = true; isParameterSet = true }
                    else { isParameterSet = false }
                case .hevc:
                    let type = (header >> 1) & 0x3F
                    if type == 32 { isParameterSet = true }
                    else if type == 33 { hasSPS = true; isParameterSet = true }
                    else if type == 34 { hasPPS = true; isParameterSet = true }
                    else { isParameterSet = false }
                }
                if isParameterSet {
                    if sets == nil { sets = [] }
                    sets!.append(Data(bytes: base + offset, count: nalLength))
                }
                offset += nalLength
            }
            return (hasSPS && hasPPS) ? sets : nil
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

    static func aacAudioSpecificConfig(fromESDSOrASC data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)

        let structuralTags: Set<UInt8> = [0x03, 0x04, 0x05]
        if let first = bytes.first, structuralTags.contains(first) {
            return findDecoderSpecificInfo(bytes, in: 0..<bytes.count)
        }

        if bytes.count > 4,
           bytes[0] == 0,
           structuralTags.contains(bytes[4]) {
            return findDecoderSpecificInfo(bytes, in: 4..<bytes.count)
        }

        if data.count >= 2, data.count <= 8 { return data }
        return findDecoderSpecificInfo(bytes, in: 0..<bytes.count)
    }

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
                guard length >= 3 else { return nil }
                let flags = bytes[payloadStart + 2]
                var childStart = payloadStart + 3
                if flags & 0x80 != 0 {
                    guard payloadEnd - childStart >= 2 else { return nil }
                    childStart += 2
                }
                if flags & 0x40 != 0 {
                    guard childStart < payloadEnd else { return nil }
                    let urlLength = Int(bytes[childStart])
                    guard payloadEnd - childStart - 1 >= urlLength else { return nil }
                    childStart += 1 + urlLength
                }
                if flags & 0x20 != 0 {
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
        default: return nil
        }

        guard let frameLengthFlag = reader.read(bits: 1),
              let dependsOnCoreCoder = reader.read(bits: 1)
        else { return nil }
        if dependsOnCoreCoder == 1, reader.read(bits: 14) == nil { return nil }
        _ = reader.read(bits: 1)
        let frameLength = frameLengthFlag == 1 ? 960 : 1024

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
                    bitIndex = saved
                    return nil
                }
                bitIndex -= 10
            }
            bitIndex = saved
            return nil
        }
    }

    static func aacMagicCookie(fromESDS data: Data) -> Data? {
        let bytes = [UInt8](data)
        if let first = bytes.first, first == 0x03 { return data }
        if bytes.count > 4, bytes[4] == 0x03 { return Data(bytes[4...]) }
        return nil
    }

    // MARK: - H.264

    private static func h264FormatDescription(avcC: Data) throws -> CMFormatDescription {
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
            offset += 1
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
        return try createHEVCFormatDescription(parameterSets: sets, nalLengthSize: nalLengthSize)
    }

    private static func createHEVCFormatDescription(
        parameterSets: [Data],
        nalLengthSize: Int
    ) throws -> CMFormatDescription {
        var flat = Data()
        var ranges: [Range<Int>] = []
        for set in parameterSets {
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
                parameterSetCount: parameterSets.count,
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
