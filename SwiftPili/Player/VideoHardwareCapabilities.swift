import CoreMedia
import QuartzCore
import VideoToolbox

enum VideoHardwareCapabilities {
    struct Snapshot: Sendable {
        let h264: Bool
        let hevc: Bool
        let av1: Bool
        let dolbyVisionHEVC: Bool

        init(h264: Bool, hevc: Bool, av1: Bool, dolbyVisionHEVC: Bool? = nil) {
            self.h264 = h264
            self.hevc = hevc
            self.av1 = av1
            self.dolbyVisionHEVC = dolbyVisionHEVC ?? hevc
        }

        func supports(codecs: String) -> Bool {
            switch VideoHardwareCapabilities.codecType(codecs: codecs) {
            case kCMVideoCodecType_H264: return h264
            case kCMVideoCodecType_HEVC: return hevc
            case kCMVideoCodecType_DolbyVisionHEVC: return dolbyVisionHEVC
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
            av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            dolbyVisionHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC)
        )
        let elapsedMS = Int((CACurrentMediaTime() - start) * 1000)
        PlayerLog.log(
            "[Player] VT system support h264=\(snapshot.h264) hevc=\(snapshot.hevc) " +
            "dv=\(snapshot.dolbyVisionHEVC) av1=\(snapshot.av1)" +
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
        let normalized = codecs.lowercased()
        if normalized.hasPrefix("avc") || normalized.hasPrefix("h264") {
            return kCMVideoCodecType_H264
        }
        if normalized.hasPrefix("dvh") || normalized.hasPrefix("dvhe") {
            return kCMVideoCodecType_DolbyVisionHEVC
        }
        if normalized.hasPrefix("hev") || normalized.hasPrefix("hvc") {
            return kCMVideoCodecType_HEVC
        }
        if normalized.hasPrefix("av01") || normalized.hasPrefix("av1") {
            return kCMVideoCodecType_AV1
        }
        return nil
    }
}
