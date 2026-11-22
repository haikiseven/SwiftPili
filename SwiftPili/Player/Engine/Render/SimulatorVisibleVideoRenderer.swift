#if targetEnvironment(simulator)

import CoreVideo
import VideoToolbox
import UIKit

struct SimulatorVisibleVideoRendererSubmissionLedger: Equatable {
    static let maxInFlightSubmissions = 3

    struct Token: Hashable, Sendable {
        let id: UInt64
        let epoch: UInt64
    }

    enum Completion: Equatable, Sendable {
        case current
        case stale
        case unknown
    }

    private(set) var currentEpoch: UInt64 = 0
    private var inFlight: Set<Token> = []

    var inFlightCount: Int { inFlight.count }

    mutating func reserve(id: UInt64) -> Token? {
        guard inFlightCount < Self.maxInFlightSubmissions else {
            return nil
        }
        let token = Token(id: id, epoch: currentEpoch)
        inFlight.insert(token)
        return token
    }

    mutating func beginNewEpoch() {
        currentEpoch &+= 1
    }

    mutating func complete(_ token: Token) -> Completion {
        guard inFlight.remove(token) != nil else { return .unknown }
        return token.epoch == currentEpoch ? .current : .stale
    }
}

@MainActor
final class SimulatorVisibleVideoRenderer: NSObject, MediaVideoPresentation {
    static let maxInFlightSubmissions = SimulatorVisibleVideoRendererSubmissionLedger.maxInFlightSubmissions

    private static let backPressureDiagnostic = "simulator-visible-renderer-back-pressure"
    private static let noSurfaceDiagnostic = "simulator-visible-renderer-no-visible-surface"
    private static let cgImageDiagnostic = "simulator-visible-renderer-cgimage"
    private static let unsupportedFormatDiagnostic = "simulator-visible-renderer-unsupported-pixel-format"
    private static let maxFaultLogs = 3

    private final class Submission {
        let cgImage: CGImage
        let pixelBuffer: CVPixelBuffer

        init(cgImage: CGImage, pixelBuffer: CVPixelBuffer) {
            self.cgImage = cgImage
            self.pixelBuffer = pixelBuffer
        }
    }

    let hostViewController: UIViewController

    let surfaceView: UIImageView

    private var scaleMode: VideoScaleMode = .fit
    private var nextSubmissionID: UInt64 = 0
    private var submissionLedger = SimulatorVisibleVideoRendererSubmissionLedger()
    private var submissions: [UInt64: Submission] = [:]
    private var pendingFrame: MediaVideoFrame?
    private var faultLogCount = 0
    private var didLogFirstFrame = false
    private var didLogSurfaceSnapshot = false
    private let imageConverter = SimulatorVideoImageConverter()
    private var lastConversionPath: String?
    private var conversionPathLogCount = 0

    private(set) var presentedFrameCount = 0
    private(set) var presentAttemptCount = 0
    private(set) var completedSubmissionCount = 0
    private(set) var lastPresentedPTS: TimeInterval?
    private(set) var displayPlaybackCallCount = 0
    private(set) var lastDisplayPlaybackRate: Float = 0
    private(set) var lastDisplayPlaybackMediaTime: TimeInterval = 0

    override init() {
        let view = UIImageView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.isOpaque = false

        let host = UIViewController()
        host.view = view

        hostViewController = host
        surfaceView = view
        super.init()
        applyScaleMode()
    }

    // MARK: - MediaVideoRendering

    func setScaleMode(_ mode: VideoScaleMode) {
        scaleMode = mode
        applyScaleMode()
    }

    func present(_ frame: MediaVideoFrame) throws {
        presentAttemptCount += 1
        guard Self.canSubmit(inFlightCount: submissionLedger.inFlightCount) else {
            throw rendererFailure(Self.backPressureDiagnostic)
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        guard Self.isSupported(pixelFormat: pixelFormat, pixelBuffer: frame.pixelBuffer) else {
            throw rendererFailure(Self.unsupportedFormatDiagnostic)
        }

        guard destinationPixelSize() != nil else {
            logSurfaceSnapshotIfNeeded(reason: "surface-not-ready")
            throw rendererFailure(Self.noSurfaceDiagnostic)
        }
        guard pendingFrame == nil else {
            throw rendererFailure(Self.backPressureDiagnostic)
        }

        pendingFrame = frame
        defer { pendingFrame = nil }

        let cgImage = try makeImage(from: frame.pixelBuffer)

        let submissionID = nextID()
        guard let submissionToken = submissionLedger.reserve(id: submissionID) else {
            throw rendererFailure(Self.backPressureDiagnostic)
        }
        submissions[submissionID] = Submission(
            cgImage: cgImage,
            pixelBuffer: frame.pixelBuffer
        )

        let screenScale = surfaceView.window?.screen.scale ?? UIScreen.main.scale
        surfaceView.image = UIImage(
            cgImage: cgImage,
            scale: max(screenScale, 1),
            orientation: .up
        )

        completeSubmission(submissionToken)
        presentedFrameCount += 1
        lastPresentedPTS = frame.pts
        logSurfaceSnapshotIfNeeded(reason: "first-frame")
        if !didLogFirstFrame {
            didLogFirstFrame = true
            PlayerLog.log(
                "[PathA] Simulator visible renderer first frame sink=UIImageView " +
                    "conversion=\(lastConversionPath ?? "unknown") format=" +
                    formatDescription(pixelFormat) +
                    " planes=\(CVPixelBufferGetPlaneCount(frame.pixelBuffer)) " +
                    "size=\(CVPixelBufferGetWidth(frame.pixelBuffer))x\(CVPixelBufferGetHeight(frame.pixelBuffer))"
            )
        }
    }

    func setDisplayPlayback(rate: Float, mediaTime: TimeInterval) {
        displayPlaybackCallCount += 1
        lastDisplayPlaybackRate = rate
        lastDisplayPlaybackMediaTime = mediaTime
    }

    func flush() {
        pendingFrame = nil
        surfaceView.image = nil
        submissions.removeAll(keepingCapacity: true)
        submissionLedger.beginNewEpoch()
    }

    func invalidate() {
        pendingFrame = nil
        surfaceView.image = nil
        submissions.removeAll(keepingCapacity: true)
        submissionLedger.beginNewEpoch()
        lastPresentedPTS = nil
        didLogFirstFrame = false
        lastConversionPath = nil
        imageConverter.reset()
    }

    // MARK: - Pure/test seams

    static func canSubmit(inFlightCount: Int) -> Bool {
        inFlightCount >= 0 && inFlightCount < maxInFlightSubmissions
    }

    static func isSupported(pixelFormat: OSType, pixelBuffer: CVPixelBuffer) -> Bool {
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            return planeCount == 0
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return planeCount == 2
        default:
            return false
        }
    }

    // MARK: - Image sink helpers

    private func makeImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        do {
            let image = try imageConverter.makeImage(from: pixelBuffer)
            logConversionPath("vimage-bgra", pixelBuffer: pixelBuffer)
            return image
        } catch {
            logConversionPath("legacy-vt", pixelBuffer: pixelBuffer, failure: error)
        }
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard status == noErr, let image else {
            throw rendererFailure("\(Self.cgImageDiagnostic)-status=\(status)")
        }
        return image
    }

    private func logConversionPath(
        _ path: String, pixelBuffer: CVPixelBuffer, failure: SimulatorVideoImageConverter.Failure? = nil
    ) {
        guard lastConversionPath != path else { return }
        lastConversionPath = path
        guard conversionPathLogCount < Self.maxFaultLogs else { return }
        conversionPathLogCount += 1
        PlayerLog.log(
            "[PathA] Simulator visible renderer conversion=\(path) " +
                "stage=\(failure?.stage ?? "ready") status=\(failure?.status ?? 0) " +
                "format=\(formatDescription(CVPixelBufferGetPixelFormatType(pixelBuffer))) " +
                "size=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) " +
                SimulatorVideoImageConverter.colorSummary(pixelBuffer)
        )
    }

    private func applyScaleMode() {
        switch scaleMode {
        case .fit:
            surfaceView.contentMode = .scaleAspectFit
        case .fill:
            surfaceView.contentMode = .scaleAspectFill
        case .stretch:
            surfaceView.contentMode = .scaleToFill
        }
    }

    private func destinationPixelSize() -> CGSize? {
        guard hostViewController.viewIfLoaded === surfaceView,
              surfaceView.window != nil,
              surfaceView.superview != nil,
              surfaceView.bounds.width > 0,
              surfaceView.bounds.height > 0
        else {
            return nil
        }

        let scale = surfaceView.window?.screen.scale ?? UIScreen.main.scale
        let size = CGSize(
            width: surfaceView.bounds.width * scale,
            height: surfaceView.bounds.height * scale
        )
        guard size.width > 0,
              size.height > 0,
              size.width.isFinite,
              size.height.isFinite
        else {
            return nil
        }
        return size
    }

    private func nextID() -> UInt64 {
        nextSubmissionID &+= 1
        if nextSubmissionID == 0 {
            nextSubmissionID = 1
        }
        return nextSubmissionID
    }

    private func completeSubmission(
        _ token: SimulatorVisibleVideoRendererSubmissionLedger.Token
    ) {
        guard submissionLedger.complete(token) != .unknown else { return }
        guard submissions.removeValue(forKey: token.id) != nil else { return }
        completedSubmissionCount += 1
    }

    private func rendererFailure(_ diagnostic: String) -> MediaEngineError {
        logRendererFault(diagnostic)
        return .renderFailed(diagnostic)
    }

    private func logRendererFault(_ diagnostic: String) {
        guard faultLogCount < Self.maxFaultLogs else { return }
        faultLogCount += 1
        PlayerLog.log("[PathA] Simulator visible renderer fault=\(diagnostic)")
    }

    private func logSurfaceSnapshotIfNeeded(reason: String) {
        guard !didLogSurfaceSnapshot else { return }
        didLogSurfaceSnapshot = true
        let hostView = hostViewController.viewIfLoaded
        let windowAttached = surfaceView.window != nil
        let hostWindowAttached = hostView?.window != nil
        let superviewAttached = surfaceView.superview != nil
        let scale = surfaceView.window?.screen.scale ?? UIScreen.main.scale
        let pixelSize = CGSize(
            width: max(surfaceView.bounds.width, 0) * scale,
            height: max(surfaceView.bounds.height, 0) * scale
        )
        let surfaceSummary = [
            "reason=\(reason)",
            "sink=UIImageView",
            "window=\(windowAttached ? 1 : 0)",
            "hostWindow=\(hostWindowAttached ? 1 : 0)",
            "superview=\(superviewAttached ? 1 : 0)",
            "bounds=\(Self.describe(surfaceView.bounds))",
            "frame=\(Self.describe(surfaceView.frame))",
            "pixelSize=\(Self.describeSize(pixelSize))",
            "image=\(surfaceView.image == nil ? 0 : 1)",
            "hidden=\(surfaceView.isHidden ? 1 : 0)",
            "alpha=\(Self.describeScalar(surfaceView.alpha))",
            "opaque=\(surfaceView.isOpaque ? 1 : 0)",
            "scale=\(Self.describeScalar(scale))"
        ].joined(separator: " ")
        PlayerLog.log("[PathA] Simulator visible renderer surface \(surfaceSummary)")
    }

    private static func describe(_ rect: CGRect) -> String {
        "[\(describeScalar(rect.origin.x)),\(describeScalar(rect.origin.y))," +
            "\(describeScalar(rect.size.width)),\(describeScalar(rect.size.height))]"
    }

    private static func describeSize(_ size: CGSize) -> String {
        "[\(describeScalar(size.width)),\(describeScalar(size.height))]"
    }

    private static func describeScalar(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    private func formatDescription(_ pixelFormat: OSType) -> String {
        String(format: "0x%08X", pixelFormat)
    }
}

#endif
