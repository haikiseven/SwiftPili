import Foundation

struct FLACStreamInfo: Equatable, Sendable {
    static let blockType: UInt8 = 0
    static let blockLength = 34
    private static let prefixLength = 4 + 4

    let minimumBlockSize: Int
    let maximumBlockSize: Int
    let sampleRate: Int
    let channels: UInt32
    let bitsPerSample: Int
    let totalSamples: UInt64

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
