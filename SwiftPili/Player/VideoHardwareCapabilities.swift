import CoreMedia
import QuartzCore
import VideoToolbox

enum VideoHardwareCapabilities {
    struct Snapshot: Sendable {
        let h264: Bool
        let hevc: Bool
        let av1: Bool

        func supports(codecs: String) -> Bool {
            switch VideoHardwareCapabilities.codecType(codecs: codecs) {
            case kCMVideoCodecType_H264: return h264
            case kCMVideoCodecType_HEVC: return hevc
            case kCMVideoCodecType_AV1: return av1
            default: return false
            }
        }
    }

    private nonisolated static let snapshotTask: Task<Snapshot, Never> = Task.detached(priority: .utility) {
        let start = CACurrentMediaTime()
        let snapshot = Snapshot(
            h264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
            hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        )
        let elapsedMS = Int((CACurrentMediaTime() - start) * 1000)
        PlayerLog.log(
            "[Player] VT system support h264=\(snapshot.h264) hevc=\(snapshot.hevc) av1=\(snapshot.av1)" +
            " queries completed (\(elapsedMS)ms)"
        )
        return snapshot
    }

    nonisolated static func prewarm() {
        _ = snapshotTask
    }

    nonisolated static func snapshot() async -> Snapshot {
        await snapshotTask.value
    }

    nonisolated static func codecType(codecs: String) -> CMVideoCodecType? {
        if codecs.hasPrefix("avc") || codecs.hasPrefix("h264") {
            return kCMVideoCodecType_H264
        }
        if codecs.hasPrefix("hev") || codecs.hasPrefix("hvc") || codecs.hasPrefix("dvh") {
            return kCMVideoCodecType_HEVC
        }
        if codecs.hasPrefix("av01") || codecs.hasPrefix("av1") {
            return kCMVideoCodecType_AV1
        }
        return nil
    }
}
