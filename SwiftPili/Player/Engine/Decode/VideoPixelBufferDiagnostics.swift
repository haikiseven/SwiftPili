import CoreVideo
import Foundation

/// A bounded, pixel-free description of one decoded video image buffer.
struct VideoPixelBufferPlaneSnapshot: Sendable, Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

/// Presence is kept separate from the value so an attachment whose value is
/// not one of Core Video's known strings is still observable without logging
/// an arbitrary CF object description.
struct VideoPixelBufferAttachmentSnapshot: Sendable, Equatable {
    let isPresent: Bool
    let valueDescription: String?
}

struct VideoPixelBufferSnapshot: Sendable, Equatable {
    let pixelFormatType: UInt32
    let pixelFormatFourCC: String
    let width: Int
    let height: Int
    let planeCount: Int
    let planes: [VideoPixelBufferPlaneSnapshot]
    /// Non-planar buffers have no Core Video planes, but their base stride is
    /// still useful for distinguishing BGRA from a bi-planar output.
    let baseBytesPerRow: Int?
    let colorPrimaries: VideoPixelBufferAttachmentSnapshot
    let transferFunction: VideoPixelBufferAttachmentSnapshot
    let yCbCrMatrix: VideoPixelBufferAttachmentSnapshot
    let chromaLocation: VideoPixelBufferAttachmentSnapshot
    let bottomFieldChromaLocation: VideoPixelBufferAttachmentSnapshot
    let fieldCount: VideoPixelBufferAttachmentSnapshot
    let fieldDetail: VideoPixelBufferAttachmentSnapshot

    /// A bounded representation suitable for a single diagnostic log line.
    var logDescription: String {
        let planeDescription = planes.enumerated().map { index, plane in
            "\(index)=\(plane.width)x\(plane.height)/\(plane.bytesPerRow)"
        }.joined(separator: ",")
        let baseDescription = baseBytesPerRow.map { " baseStride=\($0)" } ?? ""
        return "format=\(pixelFormatFourCC)(0x\(String(pixelFormatType, radix: 16))) " +
            "size=\(width)x\(height) planes=\(planeCount) [\(planeDescription)]" +
            "\(baseDescription) " +
            "primaries=\(colorPrimaries.logDescription) " +
            "transfer=\(transferFunction.logDescription) " +
            "matrix=\(yCbCrMatrix.logDescription) " +
            "chroma=\(chromaLocation.logDescription) " +
            "bottomFieldChroma=\(bottomFieldChromaLocation.logDescription) " +
            "fieldCount=\(fieldCount.logDescription) fieldDetail=\(fieldDetail.logDescription)"
    }
}

private extension VideoPixelBufferAttachmentSnapshot {
    var logDescription: String {
        guard isPresent else { return "absent" }
        return valueDescription.map { "present:\($0)" } ?? "present:unknown"
    }
}

enum VideoPixelBufferDiagnostics {
    private static let maxPlanes = 8
    private static let maxDimension = 1_000_000
    private static let maxBytesPerRow = 100_000_000
    private static let maxAttachmentDescriptionLength = 48

    /// Pure inspection: reads Core Video metadata only and never reads a pixel
    /// address. The returned value contains no object references.
    static func snapshot(_ pixelBuffer: CVPixelBuffer) -> VideoPixelBufferSnapshot {
        let rawPlaneCount = max(0, CVPixelBufferGetPlaneCount(pixelBuffer))
        let planeCount = min(rawPlaneCount, maxPlanes)
        let planes = (0..<planeCount).map { index in
            VideoPixelBufferPlaneSnapshot(
                width: boundedDimension(CVPixelBufferGetWidthOfPlane(pixelBuffer, index)),
                height: boundedDimension(CVPixelBufferGetHeightOfPlane(pixelBuffer, index)),
                bytesPerRow: boundedBytesPerRow(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, index))
            )
        }

        let nonPlanarStride: Int?
        if rawPlaneCount == 0 {
            nonPlanarStride = boundedBytesPerRow(CVPixelBufferGetBytesPerRow(pixelBuffer))
        } else {
            nonPlanarStride = nil
        }

        return VideoPixelBufferSnapshot(
            pixelFormatType: CVPixelBufferGetPixelFormatType(pixelBuffer),
            pixelFormatFourCC: fourCCString(CVPixelBufferGetPixelFormatType(pixelBuffer)),
            width: boundedDimension(CVPixelBufferGetWidth(pixelBuffer)),
            height: boundedDimension(CVPixelBufferGetHeight(pixelBuffer)),
            planeCount: planeCount,
            planes: planes,
            baseBytesPerRow: nonPlanarStride,
            colorPrimaries: attachment(
                pixelBuffer,
                key: kCVImageBufferColorPrimariesKey
            ),
            transferFunction: attachment(
                pixelBuffer,
                key: kCVImageBufferTransferFunctionKey
            ),
            yCbCrMatrix: attachment(
                pixelBuffer,
                key: kCVImageBufferYCbCrMatrixKey
            ),
            chromaLocation: attachment(
                pixelBuffer,
                key: kCVImageBufferChromaLocationTopFieldKey
            ),
            bottomFieldChromaLocation: attachment(pixelBuffer, key: kCVImageBufferChromaLocationBottomFieldKey),
            fieldCount: attachment(pixelBuffer, key: kCVImageBufferFieldCountKey),
            fieldDetail: attachment(pixelBuffer, key: kCVImageBufferFieldDetailKey)
        )
    }

    private static func boundedDimension(_ value: Int) -> Int {
        min(max(value, 0), maxDimension)
    }

    private static func boundedBytesPerRow(_ value: Int) -> Int {
        min(max(value, 0), maxBytesPerRow)
    }

    private static func fourCCString(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes.map { byte in
            byte >= 0x20 && byte <= 0x7e ? byte : UInt8(ascii: ".")
        }, encoding: .ascii) ?? "...."
    }

    private static func attachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString
    ) -> VideoPixelBufferAttachmentSnapshot {
        var mode = CVAttachmentMode.shouldPropagate
        guard let value = CVBufferCopyAttachment(pixelBuffer, key, &mode) else {
            return VideoPixelBufferAttachmentSnapshot(
                isPresent: false,
                valueDescription: nil
            )
        }

        let description: String
        if let stringValue = value as? String {
            description = boundedAttachmentDescription(stringValue)
        } else if CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber {
            description = boundedAttachmentDescription(number.stringValue)
        } else {
            description = "type=\(CFGetTypeID(value))"
        }
        return VideoPixelBufferAttachmentSnapshot(
            isPresent: true,
            valueDescription: description
        )
    }

    private static func boundedAttachmentDescription(_ value: String) -> String {
        let safe = value.filter {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == ":"
        }
        return String((safe.isEmpty ? "unknown" : safe).prefix(maxAttachmentDescriptionLength))
    }
}
