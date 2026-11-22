import Foundation

/// What the seek / resume-open preroll may do with one PRE-TARGET compressed
/// video sample (task 10-03-demand-seek-long-preroll, design §3.1).
///
/// `.submit` is the default and the answer on every fail-closed path. A wrong
/// `.submit` costs speed; a wrong `.skip`/`.truncate` costs correctness — so
/// only a sample proven non-reference by its own bitstream is ever withheld.
enum VideoPrerollSampleAction: Equatable, Sendable {
    /// Decode the whole sample.
    case submit
    /// No frame in the sample is a reference: do not hand it to the decoder.
    case skip
    /// AV1 only: hand over just the first `byteCount` bytes, which carry every
    /// reference frame of the temporal unit; the trailing non-reference frame
    /// is dropped (Media3 `sampleLimitAfterSkippingNonReferenceFrame`).
    case truncate(byteCount: Int)
}

/// Classifier seam. Production uses `VideoSampleDependencyClassifier`; the
/// session's test seam injects a fake (design OI-10).
///
/// A classifier MUST see every sample in decode order, including the ones it
/// lets the caller skip, so stateful codecs (AV1 `RefFrameType`) stay current.
protocol VideoPrerollSampleClassifying: Sendable {
    var codecLabel: String { get }
    /// Called at every seek generation, next to the decoder flush.
    mutating func reset()
    mutating func classify(_ data: Data, isKeyframe: Bool) -> VideoPrerollSampleAction
}

/// Non-reference sample classification from the bitstream alone.
///
/// - AVC: `.skip` iff not a keyframe, it carries a non-IDR slice (type 1),
///   EVERY NAL has `nal_ref_idc == 0`, and no IDR / partition / parameter-set
///   / auxiliary / extension NAL is present (Media3
///   `NalUnitUtil.isH264NalUnitDependedOn`).
/// - HEVC: `.skip` iff not a keyframe and every VCL NAL is a sub-layer
///   non-reference type (`< 16`, even) at the HIGHEST temporal sub-layer
///   (`TemporalId == numTemporalLayers − 1`, Media3
///   `isH265NalUnitDependedOn`); `numTemporalLayers == 0` (unknown) never skips.
///   The skip rule trusts hvcC's declared layer count, so the first NAL whose
///   TemporalId exceeds it (a non-conformant muxer) latches the classifier to
///   `.submit` for the rest of the stream: "highest sub-layer" is then unknown,
///   and a referenced sub-layer non-reference picture could be withheld.
/// - AV1: stateful port of the host bench's parser. A temporal unit is
///   `.skip` iff every frame in it (shown, hidden or `show_existing_frame`)
///   has `refresh_frame_flags == 0`; `.truncate` iff the non-reference frames
///   form a SUFFIX of the unit.
///
/// Fail closed: malformed length prefixes, truncated OBUs, unparsable
/// headers, reduced still pictures, multiple operating points, an in-band
/// parameter set inside an otherwise skippable AVC/HEVC sample, and an AV1
/// stream not yet primed by a key frame since `reset()` all answer `.submit`.
struct VideoSampleDependencyClassifier: VideoPrerollSampleClassifying {
    private enum Codec: Sendable {
        case avc(lengthSize: Int)
        case hevc(lengthSize: Int, maxSubLayers: Int)
        case av1
    }

    private let codec: Codec
    let codecLabel: String
    private var av1: AV1TemporalUnitParser
    /// HEVC: a NAL carried a TemporalId above hvcC's declared sub-layers.
    /// Sticky for the classifier's lifetime (one decoder open) — `reset()` is
    /// a seek, not a new stream — like the AV1 parser's `unsupported`.
    private(set) var hevcDeclaredSubLayersViolated = false

    /// `nil` for a codec this classifier does not understand, or a config it
    /// cannot read — the caller then never skips.
    init?(codec: String?, config: Data) {
        guard let codec else { return nil }
        let label = codec.lowercased()
        let bytes = [UInt8](config)
        switch label {
        case "avc1", "avc3":
            // avcC: configurationVersion, profile, compat, level,
            // reserved(6) | lengthSizeMinusOne(2).
            guard bytes.count > 4, bytes[0] == 1 else { return nil }
            self.codec = .avc(lengthSize: Int(bytes[4] & 0x03) + 1)
            self.av1 = AV1TemporalUnitParser()
        case "hvc1", "hev1":
            // hvcC byte 21: constantFrameRate(2) | numTemporalLayers(3) |
            // temporalIdNested(1) | lengthSizeMinusOne(2).
            guard bytes.count > 21, bytes[0] == 1 else { return nil }
            self.codec = .hevc(
                lengthSize: Int(bytes[21] & 0x03) + 1,
                maxSubLayers: Int(bytes[21] >> 3) & 0x07
            )
            self.av1 = AV1TemporalUnitParser()
        case "av01":
            // av1C: marker|version, profile|level, tier|depth|…, reserved|
            // initial_presentation_delay, then configOBUs.
            guard bytes.count >= 4, bytes[0] == 0x81 else { return nil }
            self.codec = .av1
            var state = AV1TemporalUnitParser()
            if bytes.count > 4 {
                // Only a sequence header is taken from the config; a parse
                // failure here simply leaves the stream waiting for the
                // in-band one every key-frame temporal unit carries.
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
            // Keyframes are scanned too: the latch must see every sample, not
            // only the candidates for withholding.
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

    /// Walk length-prefixed NAL units. Returns `nil` on any malformed prefix.
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
            // Any NAL with `nal_ref_idc != 0` makes the sample depended-on
            // (Media3 `isH264NalUnitDependedOn`'s first test).
            if (header >> 5) & 0x03 != 0 { carriesReference = true }
            switch Int(header & 0x1F) {
            case 1:
                vcl += 1
            case 2...5, 7, 8, 15, 19, 20, 21:
                // IDR, data partitions, parameter sets, auxiliary and
                // extension slices: never withheld.
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

    /// The stateless verdict for one sample, plus whether any NAL carried a
    /// TemporalId above the declared `maxSubLayers − 1` (in which case the
    /// verdict is `.submit`). Unknown sub-layers (`0`) never skip and never
    /// report a violation.
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
