import Foundation

enum VideoPrerollSampleAction: Equatable, Sendable {
    case submit
    case skip
    case truncate(byteCount: Int)
}

protocol VideoPrerollSampleClassifying: Sendable {
    var codecLabel: String { get }
    mutating func reset()
    mutating func classify(_ data: Data, isKeyframe: Bool) -> VideoPrerollSampleAction
}

struct VideoSampleDependencyClassifier: VideoPrerollSampleClassifying {
    private enum Codec: Sendable {
        case avc(lengthSize: Int)
        case hevc(lengthSize: Int, maxSubLayers: Int)
        case av1
    }

    private let codec: Codec
    let codecLabel: String
    private var av1: AV1TemporalUnitParser
    private(set) var hevcDeclaredSubLayersViolated = false

    init?(codec: String?, config: Data) {
        guard let codec else { return nil }
        let label = codec.lowercased()
        let bytes = [UInt8](config)
        switch label {
        case "avc1", "avc3":
            guard bytes.count > 4, bytes[0] == 1 else { return nil }
            self.codec = .avc(lengthSize: Int(bytes[4] & 0x03) + 1)
            self.av1 = AV1TemporalUnitParser()
        case "hvc1", "hev1":
            guard bytes.count > 21, bytes[0] == 1 else { return nil }
            self.codec = .hevc(
                lengthSize: Int(bytes[21] & 0x03) + 1,
                maxSubLayers: Int(bytes[21] >> 3) & 0x07
            )
            self.av1 = AV1TemporalUnitParser()
        case "av01":
            guard bytes.count >= 4, bytes[0] == 0x81 else { return nil }
            self.codec = .av1
            var state = AV1TemporalUnitParser()
            if bytes.count > 4 {
                _ = bytes.withUnsafeBufferPointer { buffer in
                    state.walk(UnsafeRawBufferPointer(buffer), from: 4, configOnly: true)
                }
            }
            self.av1 = state
        default:
            return nil
        }
        self.codecLabel = label
    }

    mutating func reset() {
        av1.resetReferenceState()
    }

    mutating func classify(_ data: Data, isKeyframe: Bool) -> VideoPrerollSampleAction {
        switch codec {
        case .avc(let lengthSize):
            guard !isKeyframe else { return .submit }
            return data.withUnsafeBytes { Self.classifyAVC($0, lengthSize: lengthSize) }
        case .hevc(let lengthSize, let maxSubLayers):
            guard !hevcDeclaredSubLayersViolated else { return .submit }
            let scan = data.withUnsafeBytes {
                Self.scanHEVC($0, lengthSize: lengthSize, maxSubLayers: maxSubLayers)
            }
            if scan.exceedsDeclaredSubLayers {
                hevcDeclaredSubLayersViolated = true
                return .submit
            }
            return isKeyframe ? .submit : scan.action
        case .av1:
            var state = av1
            let action = data.withUnsafeBytes { state.classify($0, isKeyframe: isKeyframe) }
            av1 = state
            return action
        }
    }

    // MARK: - AVC / HEVC

    private static func forEachNAL(
        _ bytes: UnsafeRawBufferPointer,
        lengthSize: Int,
        minimumHeader: Int,
        _ body: (_ offset: Int) -> Void
    ) -> Bool {
        guard (1...4).contains(lengthSize) else { return false }
        var index = 0
        let end = bytes.count
        guard end > 0 else { return false }
        while index < end {
            guard index + lengthSize <= end else { return false }
            var length = 0
            for byteIndex in 0..<lengthSize {
                length = length << 8 | Int(bytes[index + byteIndex])
            }
            index += lengthSize
            guard length >= minimumHeader, index + length <= end else { return false }
            body(index)
            index += length
        }
        return true
    }

    static func classifyAVC(_ bytes: UnsafeRawBufferPointer, lengthSize: Int) -> VideoPrerollSampleAction {
        var vcl = 0
        var carriesReference = false
        let wellFormed = forEachNAL(bytes, lengthSize: lengthSize, minimumHeader: 1) { offset in
            let header = bytes[offset]
            if (header >> 5) & 0x03 != 0 { carriesReference = true }
            switch Int(header & 0x1F) {
            case 1:
                vcl += 1
            case 2...5, 7, 8, 15, 19, 20, 21:
                carriesReference = true
            default:
                break
            }
        }
        guard wellFormed, vcl > 0, !carriesReference else {
            return .submit
        }
        return .skip
    }

    private static func scanHEVC(
        _ bytes: UnsafeRawBufferPointer,
        lengthSize: Int,
        maxSubLayers: Int
    ) -> (action: VideoPrerollSampleAction, exceedsDeclaredSubLayers: Bool) {
        guard maxSubLayers > 0 else { return (.submit, false) }
        var vcl = 0
        var droppableVCL = 0
        var carriesParameterSet = false
        var exceedsDeclaredSubLayers = false
        let wellFormed = forEachNAL(bytes, lengthSize: lengthSize, minimumHeader: 2) { offset in
            let type = Int(bytes[offset] >> 1) & 0x3F
            let temporalIDPlusOne = Int(bytes[offset + 1] & 0x07)
            if temporalIDPlusOne - 1 > maxSubLayers - 1 {
                exceedsDeclaredSubLayers = true
            }
            if type < 32 {
                vcl += 1
                let subLayerNonReference = type < 16 && type % 2 == 0
                if subLayerNonReference, temporalIDPlusOne - 1 == maxSubLayers - 1 {
                    droppableVCL += 1
                }
            } else if (32...34).contains(type) {
                carriesParameterSet = true
            }
        }
        guard !exceedsDeclaredSubLayers else { return (.submit, true) }
        guard wellFormed, vcl > 0, vcl == droppableVCL, !carriesParameterSet else {
            return (.submit, false)
        }
        return (.skip, false)
    }
}
