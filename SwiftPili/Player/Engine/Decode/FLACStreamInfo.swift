import Foundation

/// The FLAC STREAMINFO block, read from an fMP4 `dfLa` box payload.
///
/// `PathAFMP4Parser` surfaces the `dfLa` payload raw — the 4-byte FullBox
/// header followed by FLAC metadata blocks — exactly as it surfaces `esds` for
/// AAC. The sample entry's 16.16 rate field cannot express rates above
/// 65535 Hz, so rate, channel count and bit depth are read from STREAMINFO,
/// never from the container.
///
/// Validation follows FFmpeg's `mov_read_dfla`: FullBox version 0, and the
/// first metadata block must be STREAMINFO of exactly 34 bytes. Later blocks
/// (SEEKTABLE, VORBIS_COMMENT, …) are ignored here and travel in the cookie.
struct FLACStreamInfo: Equatable, Sendable {
    static let blockType: UInt8 = 0
    static let blockLength = 34
    /// FullBox version/flags + one metadata block header.
    private static let prefixLength = 4 + 4

    let minimumBlockSize: Int
    let maximumBlockSize: Int
    let sampleRate: Int
    let channels: UInt32
    let bitsPerSample: Int
    let totalSamples: UInt64

    /// Parse the `dfLa` box payload (the bytes after its 8-byte box header).
    static func parse(dfLa payload: Data) throws -> FLACStreamInfo {
        let bytes = [UInt8](payload)
        guard bytes.count >= prefixLength + blockLength else {
            throw MediaEngineError.decodeFailed(
                "FLAC dfLa payload \(bytes.count)B is shorter than a STREAMINFO block"
            )
        }
        guard bytes[0] == 0 else {
            throw MediaEngineError.notImplemented("FLAC dfLa version \(bytes[0])")
        }
        let type = bytes[4] & 0x7F
        let length = Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        guard type == blockType, length == blockLength else {
            throw MediaEngineError.decodeFailed(
                "FLAC dfLa first block type=\(type) length=\(length); STREAMINFO (34B) must come first"
            )
        }
        let block = Array(bytes[prefixLength..<(prefixLength + blockLength)])
        let minimumBlockSize = Int(block[0]) << 8 | Int(block[1])
        let maximumBlockSize = Int(block[2]) << 8 | Int(block[3])
        let sampleRate = Int(block[10]) << 12 | Int(block[11]) << 4 | Int(block[12]) >> 4
        let channels = UInt32((block[12] >> 1) & 0x07) + 1
        let bitsPerSample = (Int(block[12] & 0x01) << 4 | Int(block[13]) >> 4) + 1
        let totalSamples = UInt64(block[13] & 0x0F) << 32
            | UInt64(block[14]) << 24 | UInt64(block[15]) << 16
            | UInt64(block[16]) << 8 | UInt64(block[17])
        // FLAC's own floor for a block is 16 samples; STREAMINFO's maximum is
        // what sizes every decode request, so a zero or inverted pair would
        // size it wrong rather than fail.
        guard sampleRate > 0,
              maximumBlockSize >= 16,
              minimumBlockSize <= maximumBlockSize else {
            throw MediaEngineError.decodeFailed(
                "FLAC STREAMINFO invalid rate=\(sampleRate) " +
                "block=\(minimumBlockSize)-\(maximumBlockSize)"
            )
        }
        return FLACStreamInfo(
            minimumBlockSize: minimumBlockSize,
            maximumBlockSize: maximumBlockSize,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            totalSamples: totalSamples
        )
    }

    /// AudioToolbox's FLAC decompression cookie: the WHOLE `dfLa` box, its
    /// 8-byte header included.
    ///
    /// Apple does not document the layout. Measured on macOS AudioToolbox
    /// (task 09-29-hires-flac-audio, research/reference-gate.md): the FLAC
    /// encoder's own compression cookie is exactly `size | 'dfLa' | payload`,
    /// and every other shape — bare STREAMINFO, `fLaC` + block (Media3's
    /// initialization data), the headerless box body, a bare block — is
    /// rejected by `kAudioConverterDecompressionMagicCookie` with `'!dat'`.
    static func magicCookie(dfLa payload: Data) -> Data? {
        let (size, overflow) = payload.count.addingReportingOverflow(8)
        guard !overflow, size <= Int(UInt32.max) else { return nil }
        let size32 = UInt32(size)
        var cookie = Data(capacity: size)
        cookie.append(contentsOf: [
            UInt8(truncatingIfNeeded: size32 >> 24),
            UInt8(truncatingIfNeeded: size32 >> 16),
            UInt8(truncatingIfNeeded: size32 >> 8),
            UInt8(truncatingIfNeeded: size32),
        ])
        cookie.append(contentsOf: Array("dfLa".utf8))
        cookie.append(payload)
        return cookie
    }
}
