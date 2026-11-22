import Foundation

struct AV1SequenceHeader: Sendable {
    var reducedStillPicture = false
    var decoderModelInfoPresent = false
    var equalPictureInterval = false
    var bufferRemovalTimeLength = 0
    var framePresentationTimeLength = 0
    var operatingPointCount = 1
    var operatingPointIDC: [Int] = [0]
    var decoderModelPresentForOperatingPoint: [Bool] = [false]
    var frameIDNumbersPresent = false
    var frameIDLength = 0
    var forceScreenContentTools = 2
    var forceIntegerMV = 2
    var orderHintBits = 0
}

struct AV1BitReader {
    let bytes: UnsafeRawBufferPointer
    var position: Int
    let end: Int
    private(set) var overran = false

    init(_ bytes: UnsafeRawBufferPointer, range: Range<Int>) {
        self.bytes = bytes
        position = range.lowerBound * 8
        end = range.upperBound * 8
    }

    mutating func bits(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            guard position < end else {
                overran = true
                position += 1
                value <<= 1
                continue
            }
            let bit = Int(bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
            value = value << 1 | bit
            position += 1
        }
        return value
    }

    mutating func flag() -> Bool { bits(1) == 1 }

    mutating func uvlc() -> Int {
        var leadingZeros = 0
        while !flag() {
            leadingZeros += 1
            if leadingZeros >= 32 || overran {
                overran = true
                return 0
            }
        }
        return bits(leadingZeros) + (1 << leadingZeros) - 1
    }
}

struct AV1TemporalUnitParser: Sendable {
    private static let keyFrame = 0
    private static let intraOnlyFrame = 2
    private static let switchFrame = 3
    private static let allFrames = 0xFF

    struct Frame {
        var refresh: Int
    }

    struct OBU {
        var start: Int
        var end: Int
        var frame: Int
    }

    private struct OBUHeader {
        var type: Int
        var temporalID: Int
        var spatialID: Int
        var payload: Range<Int>
    }

    private static let unknownFrameType = -1

    private(set) var sequence: AV1SequenceHeader?
    private var referenceFrameType = [Int](repeating: unknownFrameType, count: 8)
    private(set) var primed = false
    private(set) var unsupported = false

    mutating func resetReferenceState() {
        referenceFrameType = [Int](repeating: Self.unknownFrameType, count: 8)
        primed = false
    }

    mutating func walk(
        _ bytes: UnsafeRawBufferPointer,
        from start: Int,
        configOnly: Bool = false
    ) -> (frames: [Frame], obus: [OBU])? {
        var frames: [Frame] = []
        var obus: [OBU] = []
        var index = start
        while index < bytes.count {
            let obuStart = index
            guard let header = Self.readOBUHeader(bytes, &index) else { return nil }
            let owner: Int
            switch header.type {
            case 4: owner = frames.count - 1
            case 3, 6: owner = frames.count
            default: owner = -1
            }
            obus.append(OBU(start: obuStart, end: header.payload.upperBound, frame: owner))
            if header.type == 1 {
                guard let parsed = Self.parseSequenceHeader(bytes, header.payload) else { return nil }
                sequence = parsed
                if parsed.reducedStillPicture || parsed.operatingPointCount > 1 {
                    unsupported = true
                }
                continue
            }
            guard !configOnly, header.type == 3 || header.type == 6 else { continue }
            guard let sequence, !unsupported,
                  let frame = parseFrameHeader(bytes, header, sequence: sequence) else {
                return nil
            }
            frames.append(frame)
        }
        return (frames, obus)
    }

    mutating func classify(
        _ bytes: UnsafeRawBufferPointer,
        isKeyframe: Bool
    ) -> VideoPrerollSampleAction {
        guard let unit = walk(bytes, from: 0) else {
            primed = false
            return .submit
        }
        guard !isKeyframe, primed, !unsupported, !unit.frames.isEmpty else {
            return .submit
        }
        let nonReference = unit.frames.map { $0.refresh == 0 }
        if nonReference.allSatisfy({ $0 }) {
            return .skip
        }
        return Self.referencePrefixAction(unit.obus, nonReference: nonReference, byteCount: bytes.count)
    }

    private static func referencePrefixAction(
        _ obus: [OBU],
        nonReference: [Bool],
        byteCount: Int
    ) -> VideoPrerollSampleAction {
        func ownedByNonReference(_ obu: OBU) -> Bool {
            obu.frame >= 0 && obu.frame < nonReference.count && nonReference[obu.frame]
        }
        guard nonReference.contains(true),
              let firstDroppable = obus.firstIndex(where: ownedByNonReference),
              obus[firstDroppable...].allSatisfy(ownedByNonReference) else {
            return .submit
        }
        let keep = obus[firstDroppable].start
        guard keep > 0, keep < byteCount else { return .submit }
        return .truncate(byteCount: keep)
    }

    private static func readOBUHeader(_ bytes: UnsafeRawBufferPointer, _ index: inout Int) -> OBUHeader? {
        let end = bytes.count
        let header = bytes[index]
        index += 1
        guard header & 0x80 == 0 else { return nil }
        var temporalID = 0
        var spatialID = 0
        if header & 0x04 != 0 {
            guard index < end else { return nil }
            temporalID = Int(bytes[index] >> 5)
            spatialID = Int(bytes[index] >> 3) & 0x03
            index += 1
        }
        var size = end - index
        if header & 0x02 != 0 {
            guard let value = leb128(bytes, &index) else { return nil }
            size = value
        }
        guard size >= 0, index + size <= end else { return nil }
        let payload = index..<(index + size)
        index = payload.upperBound
        return OBUHeader(
            type: Int(header >> 3) & 0x0F,
            temporalID: temporalID,
            spatialID: spatialID,
            payload: payload
        )
    }

    private static func leb128(_ bytes: UnsafeRawBufferPointer, _ index: inout Int) -> Int? {
        var value = 0
        for group in 0..<8 {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            value |= Int(byte & 0x7F) << (7 * group)
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    // MARK: Sequence header

    private static func parseSequenceHeader(
        _ bytes: UnsafeRawBufferPointer,
        _ range: Range<Int>
    ) -> AV1SequenceHeader? {
        var reader = AV1BitReader(bytes, range: range)
        var header = AV1SequenceHeader()
        _ = reader.bits(3)
        _ = reader.bits(1)
        header.reducedStillPicture = reader.flag()
        if header.reducedStillPicture {
            _ = reader.bits(5)
        } else {
            parseTimingAndOperatingPoints(&reader, &header)
        }
        let widthBits = reader.bits(4) + 1
        let heightBits = reader.bits(4) + 1
        _ = reader.bits(widthBits)
        _ = reader.bits(heightBits)
        if !header.reducedStillPicture { header.frameIDNumbersPresent = reader.flag() }
        if header.frameIDNumbersPresent {
            let delta = reader.bits(4) + 2
            let additional = reader.bits(3) + 1
            header.frameIDLength = delta + additional
        }
        _ = reader.bits(3)
        if !header.reducedStillPicture {
            parseCodingTools(&reader, &header)
        }
        return reader.overran ? nil : header
    }

    private static func parseTimingAndOperatingPoints(
        _ reader: inout AV1BitReader,
        _ header: inout AV1SequenceHeader
    ) {
        if reader.flag() {
            _ = reader.bits(32)
            _ = reader.bits(32)
            header.equalPictureInterval = reader.flag()
            if header.equalPictureInterval { _ = reader.uvlc() }
            header.decoderModelInfoPresent = reader.flag()
        }
        var bufferDelayLength = 0
        if header.decoderModelInfoPresent {
            bufferDelayLength = reader.bits(5) + 1
            _ = reader.bits(32)
            header.bufferRemovalTimeLength = reader.bits(5) + 1
            header.framePresentationTimeLength = reader.bits(5) + 1
        }
        let initialDisplayDelayPresent = reader.flag()
        header.operatingPointCount = reader.bits(5) + 1
        header.operatingPointIDC = []
        header.decoderModelPresentForOperatingPoint = []
        for _ in 0..<header.operatingPointCount {
            header.operatingPointIDC.append(reader.bits(12))
            if reader.bits(5) > 7 { _ = reader.bits(1) }
            var present = false
            if header.decoderModelInfoPresent {
                present = reader.flag()
                if present {
                    _ = reader.bits(bufferDelayLength)
                    _ = reader.bits(bufferDelayLength)
                    _ = reader.bits(1)
                }
            }
            header.decoderModelPresentForOperatingPoint.append(present)
            if initialDisplayDelayPresent, reader.flag() { _ = reader.bits(4) }
        }
    }

    private static func parseCodingTools(
        _ reader: inout AV1BitReader,
        _ header: inout AV1SequenceHeader
    ) {
        _ = reader.bits(4)
        let orderHint = reader.flag()
        if orderHint { _ = reader.bits(2) }
        header.forceScreenContentTools = reader.flag() ? 2 : reader.bits(1)
        if header.forceScreenContentTools > 0 {
            header.forceIntegerMV = reader.flag() ? 2 : reader.bits(1)
        } else {
            header.forceIntegerMV = 2
        }
        if orderHint { header.orderHintBits = reader.bits(3) + 1 }
    }

    // MARK: Frame header

    private mutating func parseFrameHeader(
        _ bytes: UnsafeRawBufferPointer,
        _ obu: OBUHeader,
        sequence: AV1SequenceHeader
    ) -> Frame? {
        var reader = AV1BitReader(bytes, range: obu.payload)
        if reader.flag() {
            let slot = reader.bits(3)
            guard !reader.overran else { return nil }
            if referenceFrameType[slot] == Self.unknownFrameType {
                referenceFrameType = [Int](repeating: Self.unknownFrameType, count: 8)
                return Frame(refresh: Self.allFrames)
            }
            if referenceFrameType[slot] == Self.keyFrame {
                referenceFrameType = [Int](repeating: Self.keyFrame, count: 8)
                primed = true
                return Frame(refresh: Self.allFrames)
            }
            return Frame(refresh: 0)
        }
        guard let (frameType, refresh) = Self.readFrameTypeAndRefresh(&reader, obu, sequence: sequence) else {
            return nil
        }
        for slot in 0..<8 where refresh & (1 << slot) != 0 {
            referenceFrameType[slot] = frameType
        }
        if frameType == Self.keyFrame, refresh == Self.allFrames {
            primed = true
        }
        return Frame(refresh: refresh)
    }

    private static func readFrameTypeAndRefresh(
        _ reader: inout AV1BitReader,
        _ obu: OBUHeader,
        sequence: AV1SequenceHeader
    ) -> (frameType: Int, refresh: Int)? {
        let frameType = reader.bits(2)
        let intra = frameType == keyFrame || frameType == intraOnlyFrame
        let show = reader.flag()
        let refreshesAll = frameType == switchFrame || (frameType == keyFrame && show)
        if show, sequence.decoderModelInfoPresent, !sequence.equalPictureInterval {
            _ = reader.bits(sequence.framePresentationTimeLength)
        }
        if !show { _ = reader.bits(1) }
        let errorResilient = refreshesAll ? true : reader.flag()
        _ = reader.bits(1)
        let screenContent = sequence.forceScreenContentTools == 2
            ? reader.bits(1) : sequence.forceScreenContentTools
        if screenContent > 0, sequence.forceIntegerMV == 2 { _ = reader.bits(1) }
        if sequence.frameIDNumbersPresent { _ = reader.bits(sequence.frameIDLength) }
        if frameType != switchFrame { _ = reader.bits(1) }
        _ = reader.bits(sequence.orderHintBits)
        if !(intra || errorResilient) { _ = reader.bits(3) }
        skipBufferRemovalTimes(&reader, obu, sequence: sequence)
        let refresh = refreshesAll ? allFrames : reader.bits(8)
        return reader.overran ? nil : (frameType, refresh)
    }

    private static func skipBufferRemovalTimes(
        _ reader: inout AV1BitReader,
        _ obu: OBUHeader,
        sequence: AV1SequenceHeader
    ) {
        guard sequence.decoderModelInfoPresent, reader.flag() else { return }
        for point in 0..<sequence.operatingPointCount
        where sequence.decoderModelPresentForOperatingPoint[point] {
            let idc = sequence.operatingPointIDC[point]
            let inTemporal = (idc >> obu.temporalID) & 1 == 1
            let inSpatial = (idc >> (obu.spatialID + 8)) & 1 == 1
            if idc == 0 || (inTemporal && inSpatial) {
                _ = reader.bits(sequence.bufferRemovalTimeLength)
            }
        }
    }
}
