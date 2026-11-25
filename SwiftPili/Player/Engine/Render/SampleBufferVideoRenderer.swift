import AVFoundation
import AVKit
import CoreImage
import CoreMedia
import CoreVideo
import UIKit

private func finitePresentationIntervalEnd(
    start: TimeInterval,
    duration: TimeInterval
) -> TimeInterval? {
    guard start.isFinite, duration.isFinite, duration > 0 else {
        return nil
    }
    let end = start + duration
    return end.isFinite ? end : nil
}

struct DemandRendererSurfaceReadiness: Equatable, Sendable {
    let isInWindow: Bool
    let boundsUsable: Bool
    let displayLayerReady: Bool

    var provesDisplayReadiness: Bool {
        isInWindow && boundsUsable && displayLayerReady
    }
}

enum DemandInlinePresentationAdoption: Equatable, Sendable {
    case adopted
    case needsFlush
    case rendererFailed
    case missingSurface
}

enum DemandFramePresentationResult {
    case enqueued
    case waitingOnEnhancement
    case blockedOnASBD
    case recoveredNeedsRefeed
    case terminalFault(MediaRuntimeFault)
}

@MainActor
final class SampleBufferVideoRenderer: NSObject, MediaVideoPresentation, MediaPiPLeaseEventSource, @preconcurrency AVPictureInPictureControllerDelegate {
    private static var nextDebugRendererID: UInt64 = 0

    let hostViewController: UIViewController
    private let displayView: SampleBufferDisplayView
    private let presentationHoldView: PresentationImageHoldView
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private static let maxPendingEnhancedFrames = 8
    private static let maxPendingEnhancedStartFrames = 4

    private struct PendingEnhancedFrame {
        var frame: MediaVideoFrame
        let isMidpoint: Bool
        let sampleDurationOverride: TimeInterval?
        var fallbackOriginal: MediaVideoFrame?
        var commitsPresentationProgress: Bool
    }

    private let postProcessor = VideoFramePostProcessor()
    private var enhancementAttempt: EnhancementAttempt?
    private var busyWaitState: BusyWaitState?
    private var enhancementDeadlineTimer: EnhancementDeadlineTimer?
    private var enhancementDeadlineTarget: EnhancementDeadlineTarget?
    private var nextEnhancementID: UInt64 = 0
    private var enhancementBoundary: UInt64 = 0
    private var enhancementReference: MediaVideoFrame?
    private var pendingEnhancedOutput: [PendingEnhancedFrame] = []
    private var pendingOutputDrainWake: (@MainActor () -> Void)?
    private var demandOutputFloor: TimeInterval = 0
    private var enhancementDiagnostics = EnhancementDiagnostics()
    private let thumbnailContext = CIContext()
    private var latestAmbientPixelBuffer: CVPixelBuffer?
    private var ambientAccumulationContext: CGContext?
    private var ambientAccumulationSize: CGSize = .zero
    private var hasAmbientAccumulation = false
    private var isRendererAttached = false
    private(set) var debugRendererID: UInt64
    private(set) var presentCount = 0
    private var scaleMode: VideoScaleMode = .fit
    private var presentationCornerRadius: CGFloat = 0
    private var pipController: AVPictureInPictureController?
    private let pipPlaybackDelegate = EnginePiPPlaybackDelegate()
    private var pipLeaseChangeHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var pipNativeTransitionHandler: (@MainActor @Sendable (DemandPiPNativeEvent) -> Void)?
    private var pipRestoreRequestHandler: (@MainActor @Sendable (UInt64) -> Void)?
    private var nextPiPRestoreToken: UInt64 = 0
    private var pendingPiPRestoreCompletions: [UInt64: (Bool) -> Void] = [:]
    private var pipLeaseState = EnginePiPLeaseState()
    private(set) var isPiPActive = false
    private(set) var pipStartAttempted = false
    private var pipStartPending = false
    private(set) var displayRate: Float = 0
    private(set) var lastDisplayMediaTime: TimeInterval = 0
    private(set) var flushCount = 0
    private(set) var lastEnqueuedPTS: TimeInterval?
    private var presentationProgressSerial: UInt64 = 0
    private var lastPresentationProgressUptime: TimeInterval?
    private let mediaTimescale: CMTimeScale = 60_000
    private var consecutiveRendererFaultCount = 0
    private static let terminalRendererFaultThreshold = 3
    private var hasTerminalRendererFault: Bool {
        consecutiveRendererFaultCount >= Self.terminalRendererFaultThreshold
    }
    private var mediaDataWhenReadyHandler: (() -> Void)?
    private var isRequestingMediaData = false
    private var didLogFirstEnqueueDisplaySnapshot = false
    private var isWarmSuspended = false
    private var inlineRenderGeneration = 0
    private var inlineHostVisible = false
    private var inlineBoundsUsable = false
    private struct PresentationProofState: Equatable {
        private(set) var isAwaiting = false
        private(set) var candidatePTS: TimeInterval?
        private(set) var minimumFramePTS: TimeInterval?

        mutating func arm(minimumFramePTS: TimeInterval? = nil) {
            isAwaiting = true
            candidatePTS = nil
            self.minimumFramePTS = minimumFramePTS
        }

        mutating func clear() {
            isAwaiting = false
            candidatePTS = nil
            minimumFramePTS = nil
        }

        mutating func clearCandidate() {
            candidatePTS = nil
        }

        mutating func clearCandidateAndFloor() {
            clearCandidate()
            minimumFramePTS = nil
        }

        mutating func observe(
            framePTS: TimeInterval,
            frameDuration: TimeInterval,
            hostIsVisible: Bool,
            hostBoundsUsable: Bool,
            surfaceReadiness: DemandRendererSurfaceReadiness,
            rendererHealthy: Bool,
            isWarmSuspended: Bool
        ) -> (firstPTS: TimeInterval, proofPTS: TimeInterval)? {
            guard isAwaiting,
                  !isWarmSuspended,
                  hostIsVisible,
                  hostBoundsUsable,
                  surfaceReadiness.isInWindow,
                  surfaceReadiness.boundsUsable,
                  rendererHealthy,
                  framePTS.isFinite,
                  frameDuration.isFinite,
                  frameDuration > 0,
                  finitePresentationIntervalEnd(
                      start: framePTS,
                      duration: frameDuration
                  ) != nil,
                  minimumFramePTS.map({
                      framePTS + 1e-9 >= $0
                  }) ?? true else {
                return nil
            }
            guard let firstPTS = candidatePTS else {
                candidatePTS = framePTS
                return nil
            }
            guard abs(framePTS - firstPTS) > 1e-9,
                  surfaceReadiness.provesDisplayReadiness else {
                return nil
            }
            isAwaiting = false
            candidatePTS = nil
            return (firstPTS, framePTS)
        }
    }
    private var presentationProofState = PresentationProofState()
    private var presentationProofFloor: TimeInterval?
    private var presentationProofHandler: (@MainActor @Sendable (Int, TimeInterval, Bool) -> Void)?
    private enum PresentationImageHoldOrigin: Equatable {
        case paused
        case warmSuspension
        case runtimeFaultHandoff
    }
    private struct PresentationImageHoldState: Equatable {
        let id: UInt64
        let capturedRenderGeneration: Int
        var origin: PresentationImageHoldOrigin
        var renderGeneration: Int?
    }
    private var presentationImageHoldState: PresentationImageHoldState?
    private var retainedPresentationPixelBuffer: CVPixelBuffer?
    private var nextPresentationImageHoldID: UInt64 = 0
    private var presentationImageHoldSurfaceLossLogCount = 0
    private struct PresentationHoldRecoveryOperation: Equatable, Sendable {
        let id: UInt64
        let holdID: UInt64
        let rendererID: ObjectIdentifier
    }
    private var presentationHoldRecoveryOperation: PresentationHoldRecoveryOperation?
    private var nextHoldRecoveryOperationID: UInt64 = 0
    private weak var lastPresentationWindow: UIWindow?
    private var lastPresentationSurfaceBounds: CGSize = .zero

    var presentationProgressWitness: DemandPresentationProgressWitness {
        DemandPresentationProgressWitness(
            serial: presentationProgressSerial,
            lastProgressUptime: lastPresentationProgressUptime
        )
    }

    var currentPresentationRenderGeneration: Int {
        inlineRenderGeneration
    }

    private static func allocateDebugRendererID() -> UInt64 {
        nextDebugRendererID &+= 1
        if nextDebugRendererID == 0 {
            nextDebugRendererID = 1
        }
        return nextDebugRendererID
    }

    override init() {
        debugRendererID = Self.allocateDebugRendererID()
        let view = SampleBufferDisplayView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.sampleBufferLayer.backgroundColor = UIColor.clear.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isOpaque = false
        vc.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: vc.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
        ])
        let holdView = PresentationImageHoldView(frame: .zero)
        holdView.backgroundColor = .clear
        holdView.isOpaque = false
        holdView.sampleBufferLayer.backgroundColor = UIColor.clear.cgColor
        holdView.isHidden = true
        holdView.isUserInteractionEnabled = false
        holdView.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(holdView)
        NSLayoutConstraint.activate([
            holdView.topAnchor.constraint(equalTo: vc.view.topAnchor),
            holdView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
            holdView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            holdView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
        ])
        hostViewController = vc
        displayView = view
        presentationHoldView = holdView
        super.init()
        applyScaleMode()
        attachSynchronizerIfNeeded()
        synchronizer.setRate(0, time: .zero)
        displayRate = 0
        lastDisplayMediaTime = 0
        displayView.onPresentationSurfaceChanged = { [weak self] in
            self?.presentationSurfaceGeometryDidChange()
        }
    }

    // MARK: - PiP

    @discardableResult
    func startPiP() -> Bool {
        pipStartAttempted = true
        guard !pipStartPending else {
            PlayerLog.log("[PathA] PiP start already pending — awaiting native outcome")
            return true
        }
        guard pipLeaseChangeHandler != nil, pipPlaybackDelegate.hasTransportDelegate else {
            PlayerLog.log(
                "[PathA] PiP disabled — observed lease/transport bridge unavailable"
            )
            return false
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            PlayerLog.log("[PathA] PiP not supported on this device/simulator")
            return false
        }
        if pipController == nil {
            preparePiPControllerIfPossible()
        }
        guard let pipController else {
            PlayerLog.log("[PathA] PiP controller unavailable for ASBD layer")
            return false
        }
        guard pipController.isPictureInPicturePossible else {
            PlayerLog.log("[PathA] PiP not possible yet (no window or media)")
            return false
        }
        guard !isPiPActive else { return true }
        pipStartPending = true
        pipController.startPictureInPicture()
        PlayerLog.log("[PathA] PiP start requested — awaiting didStart")
        return true
    }

    func abandonPendingPiPStart() {
        guard pipStartPending, !isPiPActive else { return }
        let oldController = pipController
        oldController?.stopPictureInPicture()
        oldController?.delegate = nil
        pipPlaybackDelegate.bind(to: nil)
        pipController = nil
        let leaseWasObservedDuringCancellation = pipLeaseState.isActive || isPiPActive
        if leaseWasObservedDuringCancellation {
            pipLeaseChangeHandler?(false)
        }
        pipLeaseState.reset()
        isPiPActive = false
        pipStartPending = false
        pipStartAttempted = false
        if pipLeaseChangeHandler != nil, pipPlaybackDelegate.hasTransportDelegate {
            preparePiPControllerIfPossible()
        }
        PlayerLog.log("[PathA] PiP pending start abandoned — controller identity retired")
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
        PlayerLog.log("[PathA] PiP stop requested — awaiting didStop")
    }

    func setPiPNativeTransitionHandler(
        _ handler: (@MainActor @Sendable (DemandPiPNativeEvent) -> Void)?
    ) {
        pipNativeTransitionHandler = handler
    }

    func setPiPRestoreRequestHandler(
        _ handler: (@MainActor @Sendable (UInt64) -> Void)?
    ) {
        pipRestoreRequestHandler = handler
        if handler == nil {
            let pending = pendingPiPRestoreCompletions.values
            pendingPiPRestoreCompletions.removeAll()
            for completion in pending {
                completion(false)
            }
        }
    }

    func completePiPRestore(token: UInt64, success: Bool) {
        guard let completion = pendingPiPRestoreCompletions.removeValue(forKey: token) else {
            return
        }
        logPiPSurfaceBoundary(
            "restoreCompletion token=\(token) success=\(success ? 1 : 0)"
        )
        completion(success)
    }

    func setPiPLeaseChangeHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        pipLeaseChangeHandler = handler
        if handler == nil {
            let oldController = pipController
            oldController?.delegate = nil
            pipPlaybackDelegate.bind(to: nil)
            pipController = nil
            pipLeaseState.reset()
            isPiPActive = false
            pipStartAttempted = false
            pipStartPending = false
        } else if pipController == nil, pipPlaybackDelegate.hasTransportDelegate {
            preparePiPControllerIfPossible()
        }
    }

    func setPiPTransportDelegate(_ delegate: (any EnginePiPTransportDelegate)?) {
        pipPlaybackDelegate.transportDelegate = delegate
        if delegate != nil, pipLeaseChangeHandler != nil, pipController == nil {
            preparePiPControllerIfPossible()
        }
    }

    func updatePiPPlaybackState(
        currentTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) {
        pipPlaybackDelegate.update(
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying
        )
        pipController?.invalidatePlaybackState()
    }

    private func preparePiPControllerIfPossible() {
        guard pipLeaseChangeHandler != nil,
              pipPlaybackDelegate.hasTransportDelegate else {
            return
        }
        pipController?.delegate = nil
        pipController = nil
        if #available(iOS 15.0, *) {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayView.sampleBufferLayer,
                playbackDelegate: pipPlaybackDelegate
            )
            let controller = AVPictureInPictureController(contentSource: contentSource)
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.delegate = self
            pipController = controller
            pipPlaybackDelegate.bind(to: controller)
        }
    }

    private func applyPiPLeaseEvent(
        _ event: EnginePiPLeaseEvent,
        controller: AVPictureInPictureController?
    ) {
        guard pipLeaseChangeHandler != nil else { return }
        if let controller, pipController !== controller {
            return
        }
        guard pipLeaseState.apply(event) else { return }
        isPiPActive = pipLeaseState.isActive
        retireEnhancement()
        pipLeaseChangeHandler?(pipLeaseState.isActive)
        PlayerLog.log(
            "[PathA] PiP observed lease active=" +
            (pipLeaseState.isActive ? "1" : "0") +
            " event=" + event.rawValue
        )
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pipController === pictureInPictureController else { return }
        pipNativeTransitionHandler?(.willStart)
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pipController === pictureInPictureController else { return }
        pipStartPending = false
        pipStartAttempted = false
        pipNativeTransitionHandler?(.didStart)
        applyPiPLeaseEvent(.didStart, controller: pictureInPictureController)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        guard pipController === pictureInPictureController else { return }
        pipStartPending = false
        pipStartAttempted = false
        PlayerLog.log("[PathA] PiP failed to start: \(error.localizedDescription)")
        pipNativeTransitionHandler?(.failedToStart)
        applyPiPLeaseEvent(.failedToStart, controller: pictureInPictureController)
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pipController === pictureInPictureController else { return }
        logPiPSurfaceBoundary("nativeWillStop")
        pipNativeTransitionHandler?(.willStop)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pipController === pictureInPictureController else { return }
        pipStartPending = false
        pipStartAttempted = false
        logPiPSurfaceBoundary("nativeDidStop")
        pipNativeTransitionHandler?(.didStop)
        applyPiPLeaseEvent(.didStop, controller: pictureInPictureController)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard pipController === pictureInPictureController,
              pipRestoreRequestHandler != nil else {
            completionHandler(false)
            return
        }
        enqueuePiPRestore(completionHandler)
    }

    private func enqueuePiPRestore(_ completionHandler: @escaping (Bool) -> Void) {
        guard let pipRestoreRequestHandler else {
            completionHandler(false)
            return
        }
        nextPiPRestoreToken &+= 1
        if nextPiPRestoreToken == 0 { nextPiPRestoreToken = 1 }
        let token = nextPiPRestoreToken
        pendingPiPRestoreCompletions[token] = completionHandler
        logPiPSurfaceBoundary("restoreDelegate token=\(token)")
        pipRestoreRequestHandler(token)
    }

    func setScaleMode(_ mode: VideoScaleMode) {
        scaleMode = mode
        applyScaleMode()
    }

    private func logPiPSurfaceBoundary(_ edge: String) {
        guard PlayerLog.isCapturing else { return }

        func describe(_ view: UIView) -> String {
            let bounds = view.bounds
            let presentationFrame = view.layer.presentation()?.frame
            let presentation = presentationFrame.map {
                "p=\(Int($0.minX.rounded())),\(Int($0.minY.rounded()))"
                    + "-\(Int($0.width.rounded()))x\(Int($0.height.rounded()))"
            } ?? "p=-"
            return "b=\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded()))"
                + " w=\(view.window != nil ? 1 : 0)"
                + " hidden=\(view.isHidden ? 1 : 0)"
                + " alpha=\(view.alpha > 0.001 ? 1 : 0)"
                + " mask=\(view.layer.masksToBounds ? 1 : 0)"
                + " r=\(Int(view.layer.cornerRadius.rounded()))"
                + " super=\(view.superview.map { String(describing: type(of: $0)) } ?? "-")"
                + " \(presentation)"
        }

        PlayerLog.log(
            "[Surface][PiPTrace] \(edge) "
                + "sameRoot=\(hostViewController.view === displayView ? 1 : 0) "
                + "source{\(describe(displayView))} "
                + "host{\(describe(hostViewController.view))} "
                + "hold{\(describe(presentationHoldView))}"
        )
    }

    func setPresentationCornerRadius(_ radius: CGFloat) {
        let radius = max(0, radius)
        let views: [UIView] = [hostViewController.view, displayView, presentationHoldView]
        for view in views {
            view.layer.cornerRadius = radius
            view.layer.cornerCurve = .continuous
            view.layer.masksToBounds = radius > 0
            view.clipsToBounds = radius > 0
        }
        guard presentationCornerRadius != radius else { return }
        presentationCornerRadius = radius
        logPiPSurfaceBoundary("mask radius=\(Int(radius.rounded()))")
        PlayerLog.log(
            "[Surface] PiP source mask radius=\(Int(radius.rounded())) " +
                "host=\(hostViewController.view.layer.masksToBounds ? 1 : 0) " +
                "display=\(displayView.layer.masksToBounds ? 1 : 0) " +
                "hold=\(presentationHoldView.layer.masksToBounds ? 1 : 0)"
        )
    }

    // MARK: - Presentation horizon

    private var maxEnqueuedPresentationEnd: TimeInterval = 0

    func enqueuedAheadSeconds(from mediaTime: TimeInterval) -> TimeInterval {
        guard mediaTime.isFinite else { return 0 }
        var horizon = maxEnqueuedPresentationEnd.isFinite ? maxEnqueuedPresentationEnd : 0
        if let lastPending = pendingEnhancedOutput.last,
           let pendingEnd = finitePresentationIntervalEnd(
               start: lastPending.frame.pts,
               duration: lastPending.frame.duration
           ) {
            horizon = max(horizon, pendingEnd)
        }
        return max(0, horizon - max(0, mediaTime))
    }

    var videoEnhancementConfiguration: VideoEnhancementConfiguration {
        get { postProcessor.configuration }
        set {
            let oldValue = postProcessor.configuration
            guard oldValue != newValue else { return }
            postProcessor.configuration = newValue
            if !newValue.isShaderUniformOnlyChange(from: oldValue) {
                retireEnhancement(wakeWaitingDrain: true)
            }
        }
    }

    var videoEnhancementTelemetry: VideoEnhancementTelemetry {
        postProcessor.telemetry
    }

    /// Presentation lookahead requested by video enhancement (dynamic, memory-pressure-aware when active; `0.3 s` otherwise).
    var preferredPresentLeadSeconds: TimeInterval {
        postProcessor.configuration.isRequested ? postProcessor.preferredPresentLeadSeconds : 0.3
    }

    /// No-op retained for engine call-site compatibility; lightweight prewarm triggers once Frame 0 settles.
    func prewarmEnhancementIfNeeded(with _: MediaVideoFrame) {}

    func setDisplayPlayback(rate: Float, mediaTime: TimeInterval) {
        let native = displayView.sampleBufferLayer.sampleBufferRenderer
        let rendererFault = native.status == .failed || native.requiresFlushToResumeDecoding
        if rendererFault { maxEnqueuedPresentationEnd = 0 }
        attachSynchronizerIfNeeded()
        let safeRate = rate.isFinite ? max(0, rate) : 0
        if rendererFault || displayRate != safeRate {
            retireEnhancement(wakeWaitingDrain: true)
        }
        let pinned = mediaTime.isFinite ? max(0, mediaTime) : 0
        let pinTime = CMTime(seconds: pinned, preferredTimescale: mediaTimescale)
        synchronizer.setRate(safeRate, time: pinTime)
        displayRate = safeRate
        lastDisplayMediaTime = pinned
    }

    func present(_ frame: MediaVideoFrame) throws {
        try validatePresentationFrame(frame)
        retireEnhancement()
        attachSynchronizerIfNeeded()
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        _ = recoverFaultedRenderer(renderer)
        switch try enqueueSingleFrame(frame, renderer: renderer, isMidpoint: false) {
        case .enqueued: return
        case .blocked: throw MediaEngineError.renderFailed("ASBD not ready for more media data")
        case .rendererFault: throw MediaEngineError.renderFailed("ASBD fault during presentation")
        }
    }

    func updateDemandPresentationFloor(_ floor: TimeInterval) {
        guard floor.isFinite, floor != demandOutputFloor else { return }
        demandOutputFloor = floor
        retireEnhancement(wakeWaitingDrain: true)
    }

    private func validatePresentationFrame(_ frame: MediaVideoFrame) throws {
        guard finitePresentationIntervalEnd(start: frame.pts, duration: frame.duration) != nil,
              presentationProofFloor.map({ frame.pts + 1e-9 >= $0 }) ?? true else {
            throw MediaEngineError.renderFailed("frame below current presentation floor")
        }
    }

    private enum NativeFrameAdmission {
        case enqueued
        case blocked
        case rendererFault
    }

    @discardableResult
    private func recoverFaultedRenderer(_ renderer: AVSampleBufferVideoRenderer) -> Bool {
        guard renderer.status == .failed || renderer.requiresFlushToResumeDecoding else { return false }
        retireEnhancement()
        maxEnqueuedPresentationEnd = 0
        renderer.flush()
        flushCount += 1
        consecutiveRendererFaultCount = 0
        presentationProofState.clearCandidate()
        return true
    }

    private func recordRendererFault(
        _ renderer: AVSampleBufferVideoRenderer,
        reason: String
    ) -> DemandFramePresentationResult {
        consecutiveRendererFaultCount += 1
        guard hasTerminalRendererFault else { return .recoveredNeedsRefeed }
        let code = (renderer.error as NSError?)?.code ?? 0
        let fault = MediaRuntimeFault(
            subsystem: .videoRenderer,
            stage: .render,
            classification: .malfunction,
            recoverability: .automaticSourceAwareReopen,
            diagnostics: MediaRuntimeFaultDiagnostics(
                status: Int32(code),
                label: "asbd-fault",
                details: "\(reason) count=\(consecutiveRendererFaultCount)"
            )
        )
        return .terminalFault(fault)
    }

    private func enqueueSingleFrame(
        _ frame: MediaVideoFrame,
        renderer: AVSampleBufferVideoRenderer,
        isMidpoint: Bool,
        sampleDurationOverride: TimeInterval? = nil,
        commitsProgress: Bool? = nil
    ) throws -> NativeFrameAdmission {
        let shouldCommitProgress = commitsProgress ?? !isMidpoint
        guard !recoverFaultedRenderer(renderer) else { return .rendererFault }
        let isReadyForMoreMediaData = renderer.isReadyForMoreMediaData
        guard isReadyForMoreMediaData else { return .blocked }
        let sample = try Self.makeSampleBuffer(
            pixelBuffer: frame.pixelBuffer,
            pts: frame.pts,
            duration: sampleDurationOverride ?? frame.duration,
            timescale: mediaTimescale
        )

        renderer.enqueue(sample)
        guard !recoverFaultedRenderer(renderer) else { return .rendererFault }
        if shouldCommitProgress { consecutiveRendererFaultCount = 0 }
        latestAmbientPixelBuffer = frame.pixelBuffer
        guard shouldCommitProgress else {
            return .enqueued
        }
        if let end = finitePresentationIntervalEnd(start: frame.pts, duration: frame.duration) {
            maxEnqueuedPresentationEnd = max(maxEnqueuedPresentationEnd, end)
        }
        presentCount += 1
        lastEnqueuedPTS = frame.pts
        presentationProgressSerial &+= 1
        if presentationProgressSerial == 0 { presentationProgressSerial = 1 }
        lastPresentationProgressUptime = ProcessInfo.processInfo.systemUptime
        if presentationProofState.isAwaiting {
            reduceAndPublishPresentationProof(
                framePTS: frame.pts,
                frameDuration: frame.duration,
                surfaceReadiness: currentPresentationSurfaceReadiness(),
                rendererHealthy: renderer.status != .failed
                    && !renderer.requiresFlushToResumeDecoding,
                expectedHoldID: presentationImageHoldState?.id
            )
        }
        if !isMidpoint, !didLogFirstEnqueueDisplaySnapshot {
            didLogFirstEnqueueDisplaySnapshot = true
            let surfaceReadiness = currentPresentationSurfaceReadiness()
            let displayReady = surfaceReadiness.displayLayerReady ? "1" : "0"
            let status = String(
                String(describing: renderer.status)
                    .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
                    .prefix(32)
            )
            let safePTS = frame.pts.isFinite ? max(0, frame.pts) : 0
            PlayerLog.log(
                "[PathA] ASBD first enqueue display rendererID=\(debugRendererID) " +
                "pts=\(String(format: "%.3f", safePTS)) status=\(status) " +
                "readyBefore=\(isReadyForMoreMediaData ? 1 : 0) " +
                "readyAfter=\(renderer.isReadyForMoreMediaData ? 1 : 0) " +
                "readyDisplayAfter=\(displayReady) " +
                "surfaceWindow=\(surfaceReadiness.isInWindow ? 1 : 0) " +
                "surfaceBounds=\(surfaceReadiness.boundsUsable ? 1 : 0) " +
                "requiresFlushAfter=\(renderer.requiresFlushToResumeDecoding ? 1 : 0)"
            )
        }
        return .enqueued
    }

    var displayClockSeconds: TimeInterval {
        CMTimeGetSeconds(synchronizer.currentTime())
    }

    var isReadyForMoreMediaData: Bool {
        attachSynchronizerIfNeeded()
        guard !hasTerminalRendererFault else { return false }
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            return true
        }
        return renderer.isReadyForMoreMediaData
    }

    var demandPresentationHealth: DemandPresentationHealth {
        attachSynchronizerIfNeeded()
        if isWarmSuspended { return .warmSuspended }
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { return .needsFlush }
        if renderer.status == .failed { return .rendererFailed }
        let surfaceReadiness = currentPresentationSurfaceReadiness()
        guard inlineHostVisible, inlineBoundsUsable,
              surfaceReadiness.isInWindow,
              surfaceReadiness.boundsUsable else {
            return .missingSurface
        }
        return .attachedButUnproven
    }

    var pipPresentationHealth: DemandPresentationHealth {
        attachSynchronizerIfNeeded()
        if isWarmSuspended { return .warmSuspended }
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { return .needsFlush }
        if renderer.status == .failed { return .rendererFailed }
        let ready: Bool
        if #available(iOS 17.4, *) {
            ready = displayView.sampleBufferLayer.isReadyForDisplay
        } else {
            ready = renderer.status == .rendering
        }
        return ready ? .attachedButUnproven : .missingSurface
    }

    func currentDisplayedImage() -> UIImage? {
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        let pixelBuffer = frontmostNonWarmPresentationPixelBuffer()
            ?? renderer.displayedPixelBuffer()
        guard let pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let maxDimension: CGFloat = 640
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let scaled = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let cgImage = thumbnailContext.createCGImage(scaled, from: scaled.extent.integral)
        guard let cgImage else {
            return nil
        }
        let displayScale: CGFloat = {
            if let windowScale = displayView.window?.windowScene?.screen.scale, windowScale > 0 {
                return windowScale
            }
            if displayView.traitCollection.displayScale > 0 {
                return displayView.traitCollection.displayScale
            }
            return AppWindowMetrics.current?.windowScene?.screen.scale ?? 2
        }()
        return UIImage(
            cgImage: cgImage,
            scale: max(displayScale, 1),
            orientation: .up
        )
    }

    func currentAmbientSampleImage(targetSize: CGSize) -> UIImage? {
        let targetRect = CGRect(origin: .zero, size: targetSize).integral
        let width = Int(targetRect.width)
        let height = Int(targetRect.height)
        guard width > 0, height > 0 else { return nil }
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        let liveBuffer = displayRate > 0 ? latestAmbientPixelBuffer : nil
        guard let pixelBuffer = frontmostNonWarmPresentationPixelBuffer()
            ?? liveBuffer
            ?? renderer.displayedPixelBuffer()
            ?? latestAmbientPixelBuffer else {
            return nil
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        let intermediateRect = CGRect(
            x: 0,
            y: 0,
            width: targetRect.width * 2,
            height: targetRect.height * 2
        )
        let preScaleX = intermediateRect.width / extent.width
        let preScaleY = intermediateRect.height / extent.height
        let diffused = normalized
            .transformed(by: CGAffineTransform(scaleX: preScaleX, y: preScaleY))
            .cropped(to: intermediateRect)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14.0])
            .cropped(to: intermediateRect)
            .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            .cropped(to: targetRect)
        guard let rawCGImage = thumbnailContext.createCGImage(diffused, from: targetRect) else {
            return nil
        }
        if ambientAccumulationContext == nil || ambientAccumulationSize != targetRect.size {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            ambientAccumulationContext = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            ambientAccumulationSize = targetRect.size
            hasAmbientAccumulation = false
        }
        guard let context = ambientAccumulationContext else {
            return UIImage(cgImage: rawCGImage, scale: 1, orientation: .up)
        }
        context.saveGState()
        context.setBlendMode(.normal)
        context.setAlpha(hasAmbientAccumulation ? 0.10 : 1.0)
        context.draw(rawCGImage, in: targetRect)
        context.restoreGState()
        hasAmbientAccumulation = true
        guard let blendedCGImage = context.makeImage() else {
            return UIImage(cgImage: rawCGImage, scale: 1, orientation: .up)
        }
        return UIImage(
            cgImage: blendedCGImage,
            scale: 1,
            orientation: .up
        )
    }

    func setPresentationProofHandler(
        _ handler: (@MainActor @Sendable (Int, TimeInterval, Bool) -> Void)?
    ) {
        presentationProofHandler = handler
    }

    func noteInlineAttachment(
        renderGeneration: Int,
        isVisible: Bool,
        boundsUsable: Bool
    ) {
        let wasUsable = inlineHostVisible && inlineBoundsUsable
        let generationChanged = inlineRenderGeneration != renderGeneration
        if generationChanged { retireEnhancement(wakeWaitingDrain: true) }
        inlineRenderGeneration = renderGeneration
        inlineHostVisible = isVisible
        inlineBoundsUsable = boundsUsable
        let isUsable = isVisible && boundsUsable
        if !isUsable {
            presentationProofState.clear()
        } else if generationChanged || !wasUsable {
            presentationProofState.arm(minimumFramePTS: presentationProofFloor)
        }
        if isUsable,
           isWarmSuspended || presentationImageHoldState?.origin == .paused
               || presentationImageHoldState?.origin == .runtimeFaultHandoff {
            _ = renderPresentationImageHoldIfNeeded(
                renderGeneration: renderGeneration
            )
        }
    }

    func warmSuspendPresentation(mediaTime: TimeInterval) {
        guard !isWarmSuspended else { return }
        stopRequestingMediaData()
        setDisplayPlayback(rate: 0, mediaTime: mediaTime)
        captureDisplayedPresentationImage(origin: .warmSuspension)
        isWarmSuspended = true
        retireEnhancement()
        presentationProofState.clear()
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        maxEnqueuedPresentationEnd = 0
        renderer.flush(
            removingDisplayedImage: false,
            completionHandler: nil
        )
        flushCount += 1
    }

    func capturePausedPresentationImage() {
        guard displayRate == 0, !isWarmSuspended,
              presentationImageHoldState?.origin != .warmSuspension,
              presentationImageHoldState?.origin != .runtimeFaultHandoff else {
            return
        }
        captureDisplayedPresentationImage(origin: .paused)
        guard presentationImageHoldState?.origin == .paused,
              retainedPresentationPixelBuffer != nil else { return }
        presentationProofState.arm(minimumFramePTS: presentationProofFloor)
    }

    func retireNonWarmPresentationImage() {
        guard let state = presentationImageHoldState,
              state.origin != .warmSuspension else { return }
        clearPresentationImageHold()
    }

    @discardableResult
    func flushAndPrimePresentation(
        renderGeneration: Int,
        mediaTime: TimeInterval,
        mediaFloor: TimeInterval? = nil
    ) -> Bool {
        attachSynchronizerIfNeeded()
        stopRequestingMediaData()
        retireEnhancement()
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        let generationChanged = inlineRenderGeneration != renderGeneration
        if generationChanged
            || renderer.status == .failed
            || renderer.requiresFlushToResumeDecoding {
            maxEnqueuedPresentationEnd = 0
            renderer.flush()
            flushCount += 1
            consecutiveRendererFaultCount = 0
        }
        inlineRenderGeneration = renderGeneration
        let floor = mediaFloor ?? mediaTime
        guard floor.isFinite, mediaTime.isFinite else { return false }
        presentationProofFloor = max(0, floor)
        if inlineHostVisible && inlineBoundsUsable {
            presentationProofState.arm(minimumFramePTS: presentationProofFloor)
        } else {
            presentationProofState.clear()
        }
        didLogFirstEnqueueDisplaySnapshot = false
        setDisplayPlayback(rate: 0, mediaTime: mediaTime)
        return renderer.status != .failed
    }

    @discardableResult
    func reconcilePiPPresentation(
        mediaTime: TimeInterval,
        rate: Float
    ) -> Bool {
        attachSynchronizerIfNeeded()
        guard mediaTime.isFinite else { return false }
        stopRequestingMediaData()
        retireEnhancement()
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        let pinned = max(0, mediaTime)
        synchronizer.setRate(0, time: CMTime(
            seconds: pinned,
            preferredTimescale: mediaTimescale
        ))
        displayRate = 0
        lastDisplayMediaTime = pinned
        maxEnqueuedPresentationEnd = 0
        renderer.flush()
        flushCount += 1
        consecutiveRendererFaultCount = 0
        presentationProofState.clearCandidateAndFloor()
        presentationProofFloor = nil
        didLogFirstEnqueueDisplaySnapshot = false
        let safeRate = rate.isFinite ? max(0, rate) : 0
        setDisplayPlayback(rate: safeRate, mediaTime: pinned)
        return renderer.status != .failed
    }

    @discardableResult
    func resumePiPPresentation(
        renderGeneration: Int,
        mediaTime: TimeInterval,
        rate: Float,
        mediaFloor: TimeInterval? = nil
    ) -> Bool {
        attachSynchronizerIfNeeded()
        guard mediaTime.isFinite else { return false }
        stopRequestingMediaData()
        retireEnhancement()
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        guard renderer.status != .failed,
              !renderer.requiresFlushToResumeDecoding else {
            return false
        }
        inlineRenderGeneration = renderGeneration
        if let mediaFloor, mediaFloor.isFinite {
            presentationProofFloor = max(0, mediaFloor)
        }
        presentationProofState.clear()
        isWarmSuspended = false
        didLogFirstEnqueueDisplaySnapshot = false
        setDisplayPlayback(
            rate: rate.isFinite ? max(0, rate) : 0,
            mediaTime: mediaTime
        )
        return true
    }

    func resumePresentation(
        renderGeneration: Int,
        mediaTime: TimeInterval,
        rate: Float,
        mediaFloor: TimeInterval? = nil
    ) -> Bool {
        guard inlineHostVisible, inlineBoundsUsable else {
            return false
        }
        _ = renderPresentationImageHoldIfNeeded(
            renderGeneration: renderGeneration
        )
        guard flushAndPrimePresentation(
            renderGeneration: renderGeneration,
            mediaTime: mediaTime,
            mediaFloor: mediaFloor ?? mediaTime
        ) else {
            return false
        }
        isWarmSuspended = false
        setDisplayPlayback(rate: rate, mediaTime: mediaTime)
        return true
    }

    @discardableResult
    func adoptInlinePresentation(
        renderGeneration: Int,
        mediaTime: TimeInterval,
        rate: Float,
        mediaFloor: TimeInterval? = nil
    ) -> DemandInlinePresentationAdoption {
        guard inlineHostVisible, inlineBoundsUsable else {
            return .missingSurface
        }
        retireEnhancement(wakeWaitingDrain: true)
        attachSynchronizerIfNeeded()
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding {
            return .needsFlush
        }
        if renderer.status == .failed {
            return .rendererFailed
        }
        inlineRenderGeneration = renderGeneration
        let floor = mediaFloor ?? mediaTime
        guard floor.isFinite, mediaTime.isFinite else { return .missingSurface }
        presentationProofFloor = max(0, floor)
        presentationProofState.arm(minimumFramePTS: presentationProofFloor)
        isWarmSuspended = false
        didLogFirstEnqueueDisplaySnapshot = false
        _ = renderPresentationImageHoldIfNeeded(
            renderGeneration: renderGeneration
        )
        setDisplayPlayback(rate: rate, mediaTime: mediaTime)
        return .adopted
    }

    var demandLivenessRenderer: DemandLivenessRenderer {
        attachSynchronizerIfNeeded()
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding {
            return .needsFlush
        }
        if renderer.status == .failed {
            return .failed
        }
        return renderer.isReadyForMoreMediaData ? .ready : .backPressure
    }

    // MARK: - Path A redesign step 3: ASBD-pull present feed

    private var wantsNativeMediaDataRequest: Bool {
        mediaDataWhenReadyHandler != nil || !pendingEnhancedOutput.isEmpty
    }

    private var pendingOutputWakeThreshold: Int {
        enhancementAttempt != nil
            ? Self.maxPendingEnhancedFrames
            : (Self.maxPendingEnhancedStartFrames + 1)
    }

    private func syncNativeMediaDataRequest() {
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        if wantsNativeMediaDataRequest {
            guard !isRequestingMediaData else { return }
            attachSynchronizerIfNeeded()
            isRequestingMediaData = true
            renderer.requestMediaDataWhenReady(on: DispatchQueue.main) { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleNativeMediaDataWhenReady()
                }
            }
        } else {
            guard isRequestingMediaData else { return }
            isRequestingMediaData = false
            renderer.stopRequestingMediaData()
        }
    }

    private func handleNativeMediaDataWhenReady() {
        guard isRequestingMediaData else { return }
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        let savedWake = pendingOutputDrainWake
        if !pendingEnhancedOutput.isEmpty {
            let drainOutcome = drainPendingEnhancedOutput(renderer: renderer)
            if drainOutcome == .rendererFault {
                if let handler = mediaDataWhenReadyHandler {
                    handler()
                } else if let savedWake {
                    savedWake()
                }
                syncNativeMediaDataRequest()
                return
            }
        }
        if pendingEnhancedOutput.count < pendingOutputWakeThreshold {
            let wake = pendingOutputDrainWake
            pendingOutputDrainWake = nil
            if let handler = mediaDataWhenReadyHandler {
                handler()
            } else if let wake {
                wake()
            }
        }
        syncNativeMediaDataRequest()
    }

    func requestMediaDataWhenReady(_ handler: @escaping () -> Void) {
        attachSynchronizerIfNeeded()
        mediaDataWhenReadyHandler = handler
        syncNativeMediaDataRequest()
    }

    func stopRequestingMediaData() {
        mediaDataWhenReadyHandler = nil
        syncNativeMediaDataRequest()
    }

    func flush() {
        retireNonWarmPresentationImage()
        flushActivePresentation { $0.flush() }
    }

    func flushForRuntimeFaultPictureHandoff() {
        guard displayRate == 0, !isWarmSuspended, !isPiPActive,
              presentationImageHoldState?.origin != .warmSuspension else {
            flush()
            return
        }
        if frontmostNonWarmPresentationPixelBuffer() != nil,
           var state = presentationImageHoldState {
            state.origin = .runtimeFaultHandoff
            presentationImageHoldState = state
        } else {
            captureDisplayedPresentationImage(origin: .runtimeFaultHandoff)
            if presentationImageHoldState?.origin != .runtimeFaultHandoff {
                retireNonWarmPresentationImage()
            }
        }
        _ = renderPresentationImageHoldIfNeeded(
            renderGeneration: inlineRenderGeneration
        )
        flushActivePresentation {
            $0.flush(removingDisplayedImage: false, completionHandler: nil)
        }
    }

    private func flushActivePresentation(
        _ flushRenderer: (AVSampleBufferVideoRenderer) -> Void
    ) {
        retireEnhancement()
        stopRequestingMediaData()
        consecutiveRendererFaultCount = 0
        let current = synchronizer.currentTime()
        let currentSeconds = CMTimeGetSeconds(current)
        let pinTime: CMTime
        if current.isValid, current.isNumeric, currentSeconds.isFinite {
            pinTime = current
            lastDisplayMediaTime = max(0, currentSeconds)
        } else {
            pinTime = CMTime(seconds: lastDisplayMediaTime, preferredTimescale: mediaTimescale)
        }
        synchronizer.setRate(0, time: pinTime)
        displayRate = 0
        maxEnqueuedPresentationEnd = 0
        latestAmbientPixelBuffer = nil
        hasAmbientAccumulation = false
        flushRenderer(displayView.sampleBufferLayer.sampleBufferRenderer)
        flushCount += 1
        presentationProofState.clearCandidateAndFloor()
        presentationProofFloor = nil
        lastPresentationProgressUptime = nil
    }

    func invalidate() {
        retireEnhancement()
        enhancementDeadlineTimer = nil
        postProcessor.tearDown()
        stopPiP()
        updatePiPPlaybackState(currentTime: 0, duration: 0, isPlaying: false)
        stopRequestingMediaData()
        clearPresentationImageHold()
        synchronizer.setRate(0, time: .zero)
        displayRate = 0
        lastDisplayMediaTime = 0
        consecutiveRendererFaultCount = 0
        maxEnqueuedPresentationEnd = 0
        latestAmbientPixelBuffer = nil
        hasAmbientAccumulation = false
        displayView.sampleBufferLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
        presentCount = 0
        flushCount = 0
        lastEnqueuedPTS = nil
        lastPresentationProgressUptime = nil
        didLogFirstEnqueueDisplaySnapshot = false
        pipStartAttempted = false
        pipStartPending = false
        if pipLeaseState.isActive {
            pipLeaseState.reset()
            isPiPActive = false
            pipLeaseChangeHandler?(false)
        }
        pipController?.delegate = nil
        pipPlaybackDelegate.bind(to: nil)
        pipController = nil
        pipLeaseState.reset()
        isPiPActive = false
        pipLeaseChangeHandler = nil
        pipNativeTransitionHandler = nil
        setPiPRestoreRequestHandler(nil)
        pipPlaybackDelegate.transportDelegate = nil
        isWarmSuspended = false
        inlineHostVisible = false
        inlineBoundsUsable = false
        presentationProofState.clear()
        presentationProofFloor = nil
        presentationProofHandler = nil
        lastPresentationWindow = nil
        lastPresentationSurfaceBounds = .zero
    }

    // MARK: - Helpers

    private func attachSynchronizerIfNeeded() {
        guard !isRendererAttached else { return }
        synchronizer.addRenderer(displayView.sampleBufferLayer)
        isRendererAttached = true
    }

    @discardableResult
    private func reduceAndPublishPresentationProof(
        framePTS: TimeInterval,
        frameDuration: TimeInterval,
        surfaceReadiness: DemandRendererSurfaceReadiness,
        rendererHealthy: Bool,
        expectedHoldID: UInt64? = nil
    ) -> Bool {
        if let hold = presentationImageHoldState {
            guard expectedHoldID == hold.id else { return false }
        } else if expectedHoldID != nil {
            return false
        }
        guard let proof = presentationProofState.observe(
            framePTS: framePTS,
            frameDuration: frameDuration,
            hostIsVisible: inlineHostVisible,
            hostBoundsUsable: inlineBoundsUsable,
            surfaceReadiness: surfaceReadiness,
            rendererHealthy: rendererHealthy,
            isWarmSuspended: isWarmSuspended
        ) else {
            return false
        }
        let safeFirstPTS = max(0, proof.firstPTS)
        let safePTS = max(0, proof.proofPTS)
        PlayerLog.log(
            "[PathA][continuation] presentation proof " +
                "rendererID=\(debugRendererID) render=\(inlineRenderGeneration) " +
                "firstPTS=\(String(format: "%.3f", safeFirstPTS)) " +
                "proofPTS=\(String(format: "%.3f", safePTS)) " +
                "floor=\(presentationProofFloor.map { String(format: "%.3f", $0) } ?? "n/a") " +
                "displayReady=1 surfaceWindow=1 surfaceBounds=1"
        )
        if let hold = presentationImageHoldState,
           expectedHoldID == hold.id {
            let releasedHoldID = hold.id
            clearPresentationImageHold(expectedID: releasedHoldID)
            PlayerLog.log(
                "[PathA][continuation] presentation image hold released=1 " +
                    "reason=proof render=\(inlineRenderGeneration) " +
                    "hold=\(releasedHoldID)"
            )
        }
        presentationProofHandler?(
            inlineRenderGeneration,
            framePTS,
            true
        )
        return true
    }

    private func currentPresentationSurfaceReadiness()
        -> DemandRendererSurfaceReadiness {
        let boundsUsable = displayView.bounds.width > 1
            && displayView.bounds.height > 1
        let isInWindow = displayView.window != nil
            && !displayView.isHidden
            && displayView.alpha > 0.001
        let readyForDisplay: Bool?
        if #available(iOS 17.4, *) {
            readyForDisplay = displayView.sampleBufferLayer.isReadyForDisplay
        } else {
            readyForDisplay = nil
        }
        let displayLayerReady = Self.resolveDisplayLayerReadiness(
            readyForDisplay: readyForDisplay,
            fallbackRendererStatus:
                displayView.sampleBufferLayer.sampleBufferRenderer.status
        )
        return DemandRendererSurfaceReadiness(
            isInWindow: isInWindow,
            boundsUsable: boundsUsable,
            displayLayerReady: displayLayerReady
        )
    }

    private func presentationSurfaceGeometryDidChange() {
        updateEnhancementDisplaySurface()
        let currentWindow = displayView.window
        let currentBounds = displayView.bounds.size
        let windowChanged = lastPresentationWindow !== currentWindow
        let boundsChanged = lastPresentationSurfaceBounds != currentBounds
        if windowChanged || boundsChanged
            || currentWindow == nil
            || currentBounds.width <= 1
            || currentBounds.height <= 1 {
            presentationProofState.clearCandidate()
        }
        lastPresentationWindow = currentWindow
        lastPresentationSurfaceBounds = currentBounds
    }

    static func resolveDisplayLayerReadiness(
        readyForDisplay: Bool?,
        fallbackRendererStatus: AVQueuedSampleBufferRenderingStatus
    ) -> Bool {
        if let readyForDisplay { return readyForDisplay }
        return fallbackRendererStatus == .rendering
    }

    private func applyScaleMode() {
        let gravity: AVLayerVideoGravity
        switch scaleMode {
        case .fit:
            gravity = .resizeAspect
        case .fill:
            gravity = .resizeAspectFill
        case .stretch:
            gravity = .resize
        }
        displayView.sampleBufferLayer.videoGravity = gravity
        presentationHoldView.sampleBufferLayer.videoGravity = gravity
        updateEnhancementDisplaySurface()
    }

    /// Lets super resolution cap its output to what the layer can actually show.
    private func updateEnhancementDisplaySurface() {
        let bounds = displayView.bounds
        let scale = displayView.window?.screen.scale ?? displayView.traitCollection.displayScale
        guard bounds.width > 0, bounds.height > 0, scale > 0 else { return }
        postProcessor.displaySurface = VideoEnhancementDisplaySurface(
            pixelWidth: Int((bounds.width * scale).rounded()), pixelHeight: Int((bounds.height * scale).rounded()),
            fills: scaleMode != .fit
        )
    }

    private func frontmostNonWarmPresentationPixelBuffer() -> CVPixelBuffer? {
        guard let state = presentationImageHoldState,
              state.origin != .warmSuspension,
              state.renderGeneration == inlineRenderGeneration,
              let pixelBuffer = retainedPresentationPixelBuffer,
              inlineHostVisible, inlineBoundsUsable,
              !presentationHoldView.isHidden,
              presentationHoldView.window != nil,
              presentationHoldView.alpha > 0.001,
              presentationHoldView.bounds.width > 1,
              presentationHoldView.bounds.height > 1 else { return nil }
        let renderer = presentationHoldView.sampleBufferLayer.sampleBufferRenderer
        guard renderer.status != .failed,
              !renderer.requiresFlushToResumeDecoding else { return nil }
        return pixelBuffer
    }

    private func captureDisplayedPresentationImage(
        origin: PresentationImageHoldOrigin
    ) {
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        let captureRate = String(format: "%.3f", displayRate)
        let rateZero = displayRate == 0 ? 1 : 0
        guard let displayed = renderer.displayedPixelBuffer() else {
            if origin == .warmSuspension,
               var state = presentationImageHoldState,
               state.origin == .paused,
               retainedPresentationPixelBuffer != nil {
                state.origin = .warmSuspension
                presentationImageHoldState = state
            }
            PlayerLog.log(
                "[PathA][continuation] presentation image hold captured=0 " +
                    "render=\(inlineRenderGeneration) rate=\(captureRate) " +
                    "rateZero=\(rateZero)"
            )
            return
        }

        if var state = presentationImageHoldState,
           state.origin == .paused,
           let retained = retainedPresentationPixelBuffer,
           retained === displayed {
            state.origin = origin
            presentationImageHoldState = state
            return
        }

        clearPresentationImageHold()
        nextPresentationImageHoldID &+= 1
        if nextPresentationImageHoldID == 0 { nextPresentationImageHoldID = 1 }
        let state = PresentationImageHoldState(
            id: nextPresentationImageHoldID,
            capturedRenderGeneration: inlineRenderGeneration,
            origin: origin,
            renderGeneration: nil
        )
        presentationImageHoldState = state
        retainedPresentationPixelBuffer = displayed
        presentationHoldView.isHidden = true
        PlayerLog.log(
            "[PathA][continuation] presentation image hold captured=1 " +
                "render=\(inlineRenderGeneration) hold=\(state.id) " +
                "rate=\(captureRate) rateZero=\(rateZero)"
        )
    }

    func refreshPresentationImageHold() {
        _ = renderPresentationImageHoldIfNeeded(
            renderGeneration: inlineRenderGeneration
        )
    }

    private func presentationHoldSurfaceHealth() -> (failed: Bool, requiresFlush: Bool) {
        let renderer = presentationHoldView.sampleBufferLayer.sampleBufferRenderer
        return (
            renderer.status == .failed,
            renderer.requiresFlushToResumeDecoding
        )
    }

    @discardableResult
    private func renderPresentationImageHoldIfNeeded(
        renderGeneration: Int
    ) -> Bool {
        guard var state = presentationImageHoldState,
              let pixelBuffer = retainedPresentationPixelBuffer,
              inlineHostVisible,
              inlineBoundsUsable else {
            return false
        }
        let holdHealth = presentationHoldSurfaceHealth()
        let holdSurfaceIsLive = !holdHealth.failed && !holdHealth.requiresFlush
        if !holdSurfaceIsLive,
           !presentationHoldView.isHidden,
           presentationImageHoldSurfaceLossLogCount < 8 {
            presentationImageHoldSurfaceLossLogCount += 1
            PlayerLog.log(
                "[PathA][continuation] presentation image hold surface lost " +
                    "render=\(renderGeneration) hold=\(state.id) " +
                    "failed=\(holdHealth.failed ? 1 : 0) " +
                    "needsFlush=\(holdHealth.requiresFlush ? 1 : 0) " +
                    "— re-enqueueing"
            )
        }
        if state.renderGeneration == renderGeneration,
           !presentationHoldView.isHidden,
           holdSurfaceIsLive {
            return true
        }
        if state.renderGeneration != nil,
           state.renderGeneration != renderGeneration,
           !presentationHoldView.isHidden,
           holdSurfaceIsLive {
            state.renderGeneration = renderGeneration
            presentationImageHoldState = state
            return true
        }
        let renderer = presentationHoldView.sampleBufferLayer.sampleBufferRenderer
        let preflightHealth = presentationHoldSurfaceHealth()
        if preflightHealth.failed || preflightHealth.requiresFlush {
            guard presentationHoldRecoveryOperation == nil else { return false }
            nextHoldRecoveryOperationID &+= 1
            let operation = PresentationHoldRecoveryOperation(
                id: nextHoldRecoveryOperationID,
                holdID: state.id,
                rendererID: ObjectIdentifier(renderer)
            )
            presentationHoldRecoveryOperation = operation
            renderer.flush(removingDisplayedImage: false) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.completeHoldRecoveryAfterFlush(operation: operation)
                    }
                }
            }
            return false
        }
        do {
            let sample = try Self.makeImmediateImageSampleBuffer(
                pixelBuffer: pixelBuffer
            )
            guard renderer.status != .failed,
                  !renderer.requiresFlushToResumeDecoding,
                  renderer.isReadyForMoreMediaData else {
                return false
            }
            renderer.enqueue(sample)
            guard renderer.status != .failed,
                  !renderer.requiresFlushToResumeDecoding else {
                return false
            }
            state.renderGeneration = renderGeneration
            presentationImageHoldState = state
            presentationHoldView.isHidden = false
            PlayerLog.log(
                "[PathA][continuation] presentation image hold displayed=1 " +
                    "render=\(renderGeneration) hold=\(state.id)"
            )
            return true
        } catch {
            PlayerLog.log(
                "[PathA][continuation] presentation image hold render failed " +
                    "render=\(renderGeneration)"
            )
            return false
        }
    }

    private func completeHoldRecoveryAfterFlush(
        operation: PresentationHoldRecoveryOperation
    ) {
        guard presentationHoldRecoveryOperation == operation else { return }
        presentationHoldRecoveryOperation = nil
        guard var state = presentationImageHoldState,
              state.id == operation.holdID,
              let pixelBuffer = retainedPresentationPixelBuffer,
              inlineHostVisible,
              inlineBoundsUsable else {
            return
        }
        let renderer = presentationHoldView.sampleBufferLayer.sampleBufferRenderer
        guard ObjectIdentifier(renderer) == operation.rendererID else { return }
        let renderGeneration = inlineRenderGeneration
        guard renderer.status != .failed,
              !renderer.requiresFlushToResumeDecoding,
              renderer.isReadyForMoreMediaData else {
            PlayerLog.log(
                "[PathA][debug] hold recovery completion blocked " +
                    "failed=\(renderer.status == .failed) " +
                    "needsFlush=\(renderer.requiresFlushToResumeDecoding) " +
                    "ready=\(renderer.isReadyForMoreMediaData)"
            )
            return
        }
        do {
            let sample = try Self.makeImmediateImageSampleBuffer(
                pixelBuffer: pixelBuffer
            )
            renderer.enqueue(sample)
            guard renderer.status != .failed,
                  !renderer.requiresFlushToResumeDecoding else {
                return
            }
            state.renderGeneration = renderGeneration
            presentationImageHoldState = state
            presentationHoldView.isHidden = false
            PlayerLog.log(
                "[PathA][continuation] presentation image hold displayed=1 " +
                    "render=\(renderGeneration) hold=\(state.id)"
            )
        } catch {
            PlayerLog.log(
                "[PathA][continuation] presentation image hold render failed " +
                    "render=\(renderGeneration)"
            )
        }
    }

    private func clearPresentationImageHold(expectedID: UInt64? = nil) {
        guard let state = presentationImageHoldState,
              expectedID == nil || state.id == expectedID else {
            return
        }
        presentationHoldView.sampleBufferLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
        presentationHoldView.isHidden = true
        presentationImageHoldState = nil
        retainedPresentationPixelBuffer = nil
        presentationHoldRecoveryOperation = nil
    }

    static func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        pts: TimeInterval,
        duration: TimeInterval,
        timescale: CMTimeScale
    ) throws -> CMSampleBuffer {
        var formatDesc: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard fdStatus == noErr, let formatDescription = formatDesc else {
            throw MediaEngineError.renderFailed(
                "CMVideoFormatDescriptionCreateForImageBuffer status=\(fdStatus)"
            )
        }

        let ptsCM = CMTime(seconds: max(0, pts), preferredTimescale: timescale)
        let durCM = CMTime(seconds: max(duration, 0.001), preferredTimescale: timescale)
        var timing = CMSampleTimingInfo(
            duration: durCM,
            presentationTimeStamp: ptsCM,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sample = sampleBuffer else {
            throw MediaEngineError.renderFailed(
                "CMSampleBufferCreateReadyWithImageBuffer status=\(sbStatus)"
            )
        }
        assert(CMTIME_IS_VALID(ptsCM))
        return sample
    }

    static func makeImmediateImageSampleBuffer(
        pixelBuffer: CVPixelBuffer
    ) throws -> CMSampleBuffer {
        var formatDesc: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard fdStatus == noErr, let formatDescription = formatDesc else {
            throw MediaEngineError.renderFailed(
                "CMVideoFormatDescriptionCreateForImageBuffer hold status=\(fdStatus)"
            )
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sample = sampleBuffer else {
            throw MediaEngineError.renderFailed(
                "CMSampleBufferCreateReadyWithImageBuffer hold status=\(sbStatus)"
            )
        }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: true
        ) as? [NSMutableDictionary],
        let attachment = attachments.first else {
            throw MediaEngineError.renderFailed(
                "sample attachment unavailable for presentation hold"
            )
        }
        attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
        return sample
    }
}

// MARK: - Demand enhancement admission

extension SampleBufferVideoRenderer {
    private enum EnhancementState {
        case processing
        case ready(VideoFrameEnhancementResult, enhancedOriginal: EnhancedOriginalAdmission)
        case bypassed
    }

    private enum MidpointAdmission {
        case pending
        case draining(remaining: [PostProcessFrameBox], admittedCount: Int, lastAdmitted: MediaVideoFrame?)
        case resolved(admittedCount: Int, lastAdmitted: MediaVideoFrame?)

        var isResolved: Bool {
            if case .resolved = self { return true }
            return false
        }

        var admittedCount: Int {
            switch self {
            case .pending: 0
            case let .draining(_, count, _), let .resolved(count, _): count
            }
        }

        var lastAdmitted: MediaVideoFrame? {
            switch self {
            case .pending: nil
            case let .draining(_, _, last), let .resolved(_, last): last
            }
        }
    }

    private enum MidpointDrainOutcome {
        case completed
        case rendererFault
    }

    private enum PendingOutputDrainOutcome {
        case drained
        case blocked
        case rendererFault
    }

    private var lastQueuedPTS: TimeInterval? {
        pendingEnhancedOutput.last?.frame.pts ?? lastEnqueuedPTS
    }

    private enum EnhancedOriginalAdmission {
        case unavailable
        case late
        case ready(MediaVideoFrame)
    }

    private enum EnhancementDeadlineTarget: Equatable {
        case attempt(id: UInt64, boundary: UInt64)
        case busyWait(frame: EnhancementFrameIdentity, boundary: UInt64)
    }

    private struct BusyWaitState {
        let frame: EnhancementFrameIdentity
        let boundary: UInt64
        let deadline: ContinuousClock.Instant
        let wake: @MainActor () -> Void
    }

    private struct EnhancementAttempt {
        let id: UInt64
        let frame: EnhancementFrameIdentity
        let reference: MediaVideoFrame
        let deadlines: VideoEnhancementDeadlines
        let canUpscale: Bool
        let committedPlan: VideoFrameInterpolationPlan?
        let activeOriginalDuration: TimeInterval?
        let wake: @MainActor () -> Void
        var state = EnhancementState.processing
        var midpoint: MidpointAdmission

        var workDeadline: ContinuousClock.Instant { deadlines.workDeadline(upscaling: canUpscale) }

        var admittedMidpointCount: Int { midpoint.admittedCount }

        var lastAdmittedMidpoint: MediaVideoFrame? { midpoint.lastAdmitted }
    }

    private struct EnhancementPresentation {
        let original: MediaVideoFrame
        let reference: MediaVideoFrame
        let admission: VideoEnhancementAdmission
        let mediaTime: TimeInterval
        let playbackRate: Double
        let originalDelay: TimeInterval?
        let midpointDelay: TimeInterval?

        var canUpscale: Bool { admission.canUpscale }
        var interpolationPlan: VideoFrameInterpolationPlan? { admission.interpolationPlan }
        var interpolationBypassReason: String? { admission.interpolationBypassReason }
        var activeOriginalDuration: TimeInterval? { admission.activeOriginalDuration }
        var hasInterpolationPlan: Bool { admission.hasInterpolationPhases }
    }

    private struct EnhancementDiagnostics {
        var submissions = 0
        var completions = 0
        var midpointsGenerated = 0
        var deadlinesMissed = 0
        var workerBusy = 0
        var nativeWaits = 0
        var originalsEnqueued = 0
        var midpointsEnqueued = 0
        var lastInterpolationBypass: String?
        var lastReport: ContinuousClock.Instant?
        var superResolution = SuperResolutionDiagnostics()

        mutating func noteInterpolationDeadline(_ reason: String) {
            deadlinesMissed += 1
            lastInterpolationBypass = reason
        }
    }

    func presentDemandFrame(
        _ frame: MediaVideoFrame,
        mediaTime: TimeInterval,
        playbackRate: Double,
        onEnhancementWake: @escaping @MainActor () -> Void
    ) throws -> DemandFramePresentationResult {
        try validatePresentationFrame(frame)
        guard frame.pts + 1e-9 >= demandOutputFloor else {
            throw MediaEngineError.renderFailed("frame below current Demand output floor")
        }
        attachSynchronizerIfNeeded()
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        if hasTerminalRendererFault {
            return recordRendererFault(renderer, reason: "ASBD terminal fault")
        }
        if recoverFaultedRenderer(renderer) {
            return recordRendererFault(renderer, reason: "ASBD fault before enqueue")
        }
        if !pendingEnhancedOutput.isEmpty {
            if drainPendingEnhancedOutput(renderer: renderer) == .rendererFault {
                return recordRendererFault(renderer, reason: "ASBD fault draining pending enhancement output")
            }
            syncNativeMediaDataRequest()
        }
        discardEnhancementForReplacedHead(frame)
        if !renderer.isReadyForMoreMediaData {
            let canPipelineEnhancement: Bool
            if tracksEnhancementAdmissions {
                if enhancementAttempt != nil {
                    canPipelineEnhancement = pendingEnhancedOutput.count < Self.maxPendingEnhancedFrames
                } else {
                    canPipelineEnhancement = pendingEnhancedOutput.count <= Self.maxPendingEnhancedStartFrames
                }
            } else {
                canPipelineEnhancement = false
            }
            guard canPipelineEnhancement else {
                if !pendingEnhancedOutput.isEmpty {
                    pendingOutputDrainWake = onEnhancementWake
                    syncNativeMediaDataRequest()
                }
                return noteNativeWait()
            }
        }
        pendingOutputDrainWake = nil
        if let attempt = enhancementAttempt {
            return try resumeEnhancement(
                attempt,
                frame: frame,
                mediaTime: mediaTime,
                playbackRate: playbackRate,
                renderer: renderer
            )
        }
        let admission: VideoEnhancementAdmission
        switch postProcessor.evaluateAdmission(
            for: frame,
            previous: enhancementReference,
            playbackRate: playbackRate
        ) {
        case let .eligible(resolved):
            admission = resolved
        case let .ineligible(bypassReason, activeOriginalDuration):
            if tracksSuperResolutionAdmissions {
                enhancementDiagnostics.superResolution.noteBypass(bypassReason ?? "Enhancement disabled")
            }
            return try admitOriginal(
                frame,
                renderer: renderer,
                playbackRate: playbackRate,
                activeOriginalDuration: activeOriginalDuration
            )
        }
        if let plan = admission.interpolationPlan, plan.phases.isEmpty {
            if !plan.emitsOriginal, lastQueuedPTS != nil, !admission.canUpscale {
                recordSkippedOriginalAdmission(frame, committedPlan: plan, playbackRate: playbackRate)
                return .enqueued
            }
            if plan.emitsOriginal, !admission.canUpscale {
                return try admitOriginal(
                    frame,
                    renderer: renderer,
                    committedPlan: plan,
                    playbackRate: playbackRate,
                    activeOriginalDuration: admission.activeOriginalDuration
                )
            }
        }
        guard let reference = enhancementReference,
              let request = makeEnhancementPresentation(
                  frame: frame,
                  reference: reference,
                  admission: admission,
                  mediaTime: mediaTime,
                  rate: playbackRate
              ) else {
            return try admitOriginal(
                frame,
                renderer: renderer,
                playbackRate: playbackRate,
                activeOriginalDuration: admission.activeOriginalDuration
            )
        }
        let hasEligibleWork = request.canUpscale || request.midpointDelay != nil
        if postProcessor.isBusy, hasEligibleWork {
            let waitRunway = request.canUpscale ? request.originalDelay : (request.midpointDelay ?? request.originalDelay)
            if let waitRunway, waitRunway > 0.015 {
                parkForBusyWorker(
                    frame: frame,
                    originalDelay: waitRunway,
                    wake: onEnhancementWake
                )
                return .waitingOnEnhancement
            }
            clearBusyWaitState()
            let busyReason = recordBusyWorkerBypass(for: request)
            postProcessor.noteBypass(busyReason)
            return try admitOriginal(
                frame,
                renderer: renderer,
                playbackRate: playbackRate,
                activeOriginalDuration: admission.activeOriginalDuration
            )
        }
        clearBusyWaitState()
        guard let deadlines = enhancementDeadlines(for: request) else {
            return try admitOriginal(
                frame,
                renderer: renderer,
                playbackRate: playbackRate,
                activeOriginalDuration: admission.activeOriginalDuration
            )
        }
        startEnhancement(request, deadlines: deadlines, wake: onEnhancementWake)
        return .waitingOnEnhancement
    }

    private func discardEnhancementForReplacedHead(_ frame: MediaVideoFrame) {
        let identity = EnhancementFrameIdentity(frame)
        if let busy = busyWaitState, busy.frame != identity {
            clearBusyWaitState()
        }
        guard let attempt = enhancementAttempt, attempt.frame != identity else { return }
        clearEnhancementAttempt()
        postProcessor.flush()
    }

    private func parkForBusyWorker(
        frame: MediaVideoFrame,
        originalDelay: TimeInterval,
        wake: @escaping @MainActor () -> Void
    ) {
        let boundary = enhancementBoundary
        let identity = EnhancementFrameIdentity(frame)
        let waitSeconds = max(0.005, originalDelay - 0.010)
        let deadline = ContinuousClock.now.advanced(by: .seconds(waitSeconds))
        busyWaitState = BusyWaitState(
            frame: identity,
            boundary: boundary,
            deadline: deadline,
            wake: wake
        )
        postProcessor.notifyWhenIdle { [weak self] in
            self?.wakeFromBusyWorker(boundary: boundary)
        }
        armEnhancementDeadlineWake(
            until: deadline,
            target: .busyWait(frame: identity, boundary: boundary)
        )
    }

    private func wakeFromBusyWorker(boundary: UInt64) {
        guard enhancementBoundary == boundary,
              let busy = busyWaitState,
              busy.boundary == boundary else {
            return
        }
        clearBusyWaitState()
        busy.wake()
    }

    private func clearBusyWaitState() {
        let hadBusyWait = busyWaitState != nil
        busyWaitState = nil
        if hadBusyWait {
            postProcessor.clearIdleCallback()
            if case .busyWait = enhancementDeadlineTarget {
                cancelEnhancementDeadlineWake()
            }
        }
    }

    private func recordBusyWorkerBypass(for request: EnhancementPresentation) -> String {
        if postProcessor.isWarming {
            let reason = "Enhancement warming up"
            if request.midpointDelay != nil {
                enhancementDiagnostics.lastInterpolationBypass = reason
            }
            if request.canUpscale {
                enhancementDiagnostics.superResolution.noteBypass(reason)
            }
            return reason
        }
        enhancementDiagnostics.workerBusy += 1
        if request.midpointDelay != nil {
            enhancementDiagnostics.lastInterpolationBypass = "Interpolation worker busy"
        }
        let busyReason = "Enhancement worker busy"
        if request.canUpscale {
            enhancementDiagnostics.superResolution.noteBypass(busyReason)
        }
        return busyReason
    }

    private func makeEnhancementPresentation(
        frame: MediaVideoFrame,
        reference: MediaVideoFrame,
        admission: VideoEnhancementAdmission,
        mediaTime: TimeInterval,
        rate: Double
    ) -> EnhancementPresentation? {
        let earliestMidpointPTS = admission.interpolationPlan?.pts.first
        guard let clock = enhancementClock(mediaTime: mediaTime, rate: rate) else {
            if earliestMidpointPTS != nil {
                enhancementDiagnostics.lastInterpolationBypass = "Playback clock unavailable"
            }
            if tracksSuperResolutionAdmissions {
                enhancementDiagnostics.superResolution.noteBypass("Playback clock unavailable")
            }
            return nil
        }
        return EnhancementPresentation(
            original: frame,
            reference: reference,
            admission: admission,
            mediaTime: mediaTime,
            playbackRate: rate,
            originalDelay: enhancementDelay(pts: frame.pts, clock: clock, rate: rate),
            midpointDelay: earliestMidpointPTS.flatMap { enhancementDelay(pts: $0, clock: clock, rate: rate) }
        )
    }

    private func enhancementDeadlines(for request: EnhancementPresentation) -> VideoEnhancementDeadlines? {
        let generationDeadlineReason = "Interpolation generation deadline"
        if request.hasInterpolationPlan, request.midpointDelay == nil {
            enhancementDiagnostics.noteInterpolationDeadline(generationDeadlineReason)
        }
        guard let originalDelay = request.originalDelay else {
            if request.canUpscale { enhancementDiagnostics.superResolution.late += 1 }
            return nil
        }
        guard request.midpointDelay != nil || request.canUpscale else {
            let reason = request.hasInterpolationPlan
                ? generationDeadlineReason
                : (request.interpolationBypassReason ?? "Frame timing gap")
            postProcessor.noteBypass(reason)
            return nil
        }
        guard !postProcessor.isBusy else {
            let busyReason = recordBusyWorkerBypass(for: request)
            postProcessor.noteBypass(busyReason)
            return nil
        }
        let now = ContinuousClock.now
        return VideoEnhancementDeadlines(
            original: now.advanced(by: .seconds(originalDelay)),
            midpoint: request.midpointDelay.map { now.advanced(by: .seconds($0)) }
        )
    }

    private func enhancementClock(mediaTime: TimeInterval, rate: Double) -> TimeInterval? {
        let displayTime = displayClockSeconds
        guard mediaTime.isFinite, displayTime.isFinite, rate.isFinite, rate > 0,
              Double(displayRate) == rate, Double(synchronizer.rate) == rate else { return nil }
        return max(mediaTime, displayTime)
    }

    private func enhancementDelay(pts: TimeInterval, clock: TimeInterval, rate: Double) -> TimeInterval? {
        guard clock.isFinite, rate.isFinite, rate > 0, displayRate > 0 else { return nil }
        let delay = (pts - clock) / rate - 0.008
        return delay.isFinite && delay > 0 ? min(delay, preferredPresentLeadSeconds) : nil
    }

    private func startEnhancement(
        _ request: EnhancementPresentation,
        deadlines: VideoEnhancementDeadlines,
        wake: @escaping @MainActor () -> Void
    ) {
        nextEnhancementID &+= 1
        let id = nextEnhancementID
        let boundary = enhancementBoundary
        let attempt = EnhancementAttempt(
            id: id,
            frame: EnhancementFrameIdentity(request.original),
            reference: request.reference,
            deadlines: deadlines,
            canUpscale: request.canUpscale,
            committedPlan: request.interpolationPlan,
            activeOriginalDuration: request.activeOriginalDuration,
            wake: wake,
            midpoint: deadlines.midpoint == nil ? .resolved(admittedCount: 0, lastAdmitted: nil) : .pending
        )
        enhancementAttempt = attempt
        enhancementDiagnostics.submissions += 1
        postProcessor.submit(
            request.original,
            previous: request.reference,
            admission: request.admission,
            deadlines: deadlines
        ) { [weak self] update in
            guard let self, self.enhancementBoundary == boundary else { return }
            self.receiveEnhancementUpdate(update, id: id)
        }
        armEnhancementDeadlineWake(until: attempt.workDeadline, target: .attempt(id: id, boundary: boundary))
    }

    private func armEnhancementDeadlineWake(
        until deadline: ContinuousClock.Instant,
        target: EnhancementDeadlineTarget
    ) {
        enhancementDeadlineTarget = target
        let timer = enhancementDeadlineTimer ?? {
            let created = EnhancementDeadlineTimer { [weak self] in
                self?.handleEnhancementDeadlineWake()
            }
            enhancementDeadlineTimer = created
            return created
        }()
        timer.arm(until: deadline)
    }

    private func handleEnhancementDeadlineWake() {
        guard let target = enhancementDeadlineTarget else { return }
        enhancementDeadlineTarget = nil
        switch target {
        case let .attempt(id, boundary):
            guard enhancementBoundary == boundary,
                  let attempt = enhancementAttempt,
                  attempt.id == id,
                  case .processing = attempt.state else { return }
            if ContinuousClock.now < attempt.workDeadline {
                armEnhancementDeadlineWake(
                    until: attempt.workDeadline,
                    target: .attempt(id: attempt.id, boundary: boundary)
                )
                return
            }
            expireEnhancement(attempt)
            attempt.wake()
        case let .busyWait(frame, boundary):
            guard enhancementAttempt == nil,
                  enhancementBoundary == boundary,
                  let busy = busyWaitState,
                  busy.boundary == boundary,
                  busy.frame == frame else { return }
            if ContinuousClock.now < busy.deadline {
                armEnhancementDeadlineWake(
                    until: busy.deadline,
                    target: .busyWait(frame: frame, boundary: boundary)
                )
                return
            }
            clearBusyWaitState()
            busy.wake()
        }
    }

    private func receiveEnhancementUpdate(_ update: VideoFrameEnhancementUpdate, id: UInt64) {
        if case let .finished(result) = update {
            enhancementDiagnostics.completions += 1
            enhancementDiagnostics.midpointsGenerated += result.midpoints.count
            if result.enhancedOriginal != nil { enhancementDiagnostics.superResolution.originalsProcessed += 1 }
        }
        guard var attempt = enhancementAttempt, attempt.id == id,
              case .processing = attempt.state else { return }
        switch update {
        case let .midpointReady(midpoints):
            guard case .pending = attempt.midpoint, !midpoints.isEmpty else { return }
            attempt.midpoint = .draining(remaining: midpoints, admittedCount: 0, lastAdmitted: nil)
            enhancementAttempt = attempt
        case let .finished(result):
            receiveCompletedEnhancement(result, attempt: attempt)
        }
        attempt.wake()
    }

    private func receiveCompletedEnhancement(_ result: VideoFrameEnhancementResult, attempt: EnhancementAttempt) {
        if let reason = result.interpolationBypassReason {
            enhancementDiagnostics.lastInterpolationBypass = reason
        }
        if let reason = result.originalSuperResolutionBypassReason {
            enhancementDiagnostics.superResolution.noteBypass(reason)
        }
        var completed = attempt
        if case .pending = completed.midpoint {
            completed.midpoint = result.midpoints.isEmpty
                ? .resolved(admittedCount: 0, lastAdmitted: nil)
                : .draining(remaining: result.midpoints, admittedCount: 0, lastAdmitted: nil)
        }
        cancelEnhancementDeadlineWake()
        let enhancedOriginal: EnhancedOriginalAdmission
        if attempt.canUpscale, ContinuousClock.now >= attempt.deadlines.original {
            enhancedOriginal = .late
        } else if let candidate = result.enhancedOriginal {
            enhancedOriginal = .ready(candidate.frame)
        } else {
            enhancedOriginal = .unavailable
        }
        completed.state = .ready(result, enhancedOriginal: enhancedOriginal)
        enhancementAttempt = completed
    }

    private func expireEnhancement(_ attempt: EnhancementAttempt) {
        var expired = attempt
        if case .pending = expired.midpoint {
            enhancementDiagnostics.noteInterpolationDeadline("Interpolation generation deadline")
            expired.midpoint = .resolved(admittedCount: 0, lastAdmitted: nil)
        } else if case let .draining(_, admittedCount, lastAdmitted) = expired.midpoint {
            expired.midpoint = .resolved(admittedCount: admittedCount, lastAdmitted: lastAdmitted)
            if attempt.canUpscale { enhancementDiagnostics.deadlinesMissed += 1 }
        } else if attempt.canUpscale {
            enhancementDiagnostics.deadlinesMissed += 1
        }
        if attempt.canUpscale { enhancementDiagnostics.superResolution.late += 1 }
        if attempt.admittedMidpointCount == 0 { postProcessor.noteBypass("Enhancement deadline") }
        bypassEnhancement(expired)
    }

    private func abandonEnhancementOutput() {
        guard var attempt = enhancementAttempt else { return }
        attempt.midpoint = .resolved(
            admittedCount: attempt.admittedMidpointCount,
            lastAdmitted: attempt.lastAdmittedMidpoint
        )
        bypassEnhancement(attempt)
    }

    private func bypassEnhancement(_ attempt: EnhancementAttempt) {
        var bypassed = attempt
        bypassed.state = .bypassed
        enhancementAttempt = bypassed
        if case .bypassed = attempt.state { return }
        cancelEnhancementDeadlineWake()
    }

    private func cancelEnhancementDeadlineWake() {
        enhancementDeadlineTarget = nil
        enhancementDeadlineTimer?.disarm()
    }

    private func clearEnhancementAttempt() {
        cancelEnhancementDeadlineWake()
        enhancementAttempt = nil
        clearBusyWaitState()
    }

    private func retireEnhancement(wakeWaitingDrain: Bool = false) {
        let waiting = enhancementAttempt.flatMap { attempt -> EnhancementAttempt? in
            if case .processing = attempt.state { return attempt }
            return nil
        }
        let busyWake = busyWaitState?.wake
        let pendingWake = pendingOutputDrainWake
        if enhancementAttempt != nil || enhancementReference != nil || busyWaitState != nil
            || !pendingEnhancedOutput.isEmpty {
            postProcessor.noteDiscontinuity()
        }
        enhancementBoundary &+= 1
        enhancementDiagnostics = EnhancementDiagnostics(lastReport: enhancementDiagnostics.lastReport)
        clearEnhancementAttempt()
        pendingEnhancedOutput.removeAll()
        pendingOutputDrainWake = nil
        syncNativeMediaDataRequest()
        enhancementReference = nil
        postProcessor.flush()
        if wakeWaitingDrain {
            if let waiting {
                Task { @MainActor in waiting.wake() }
            } else if let busyWake {
                Task { @MainActor in busyWake() }
            } else if let pendingWake {
                Task { @MainActor in pendingWake() }
            }
        }
    }

    private func resumeEnhancement(
        _ attempt: EnhancementAttempt,
        frame: MediaVideoFrame,
        mediaTime: TimeInterval,
        playbackRate: Double,
        renderer: AVSampleBufferVideoRenderer
    ) throws -> DemandFramePresentationResult {
        if VideoEnhancementGuardrails.isThermalThrottled() || VideoEnhancementGuardrails.isUnderMemoryPressure {
            let reason = VideoEnhancementGuardrails.isThermalThrottled() ? "Thermal throttling" : "Memory pressure"
            postProcessor.noteBypass(reason)
            if tracksSuperResolutionAdmissions {
                enhancementDiagnostics.superResolution.noteBypass(reason)
            }
            abandonEnhancementOutput()
            return try admitOriginal(frame, renderer: renderer, playbackRate: playbackRate)
        }
        guard let clock = enhancementClock(mediaTime: mediaTime, rate: playbackRate) else {
            if !attempt.midpoint.isResolved {
                enhancementDiagnostics.lastInterpolationBypass = "Playback clock unavailable"
            }
            if tracksSuperResolutionAdmissions {
                enhancementDiagnostics.superResolution.noteBypass("Playback clock unavailable")
            }
            abandonEnhancementOutput()
            return try admitOriginal(
                frame,
                renderer: renderer,
                playbackRate: playbackRate,
                activeOriginalDuration: attempt.activeOriginalDuration
            )
        }
        let originalDelay = enhancementDelay(pts: frame.pts, clock: clock, rate: playbackRate)
        let midpointDelay = attempt.committedPlan?.pts.first.flatMap {
            enhancementDelay(pts: $0, clock: clock, rate: playbackRate)
        }
        var current = attempt
        switch admitMidpointsIfUsable(
            &current,
            original: frame,
            reference: attempt.reference,
            clock: clock,
            playbackRate: playbackRate,
            renderer: renderer
        ) {
        case .completed:
            enhancementAttempt = current
        case .rendererFault:
            return try admitOriginal(
                frame,
                renderer: renderer,
                playbackRate: playbackRate,
                activeOriginalDuration: attempt.activeOriginalDuration
            )
        }
        switch current.state {
        case .processing:
            let delay = current.canUpscale ? originalDelay : midpointDelay
            if delay != nil, ContinuousClock.now < current.workDeadline { return .waitingOnEnhancement }
            expireEnhancement(current)
        case let .ready(result, enhancedOriginal):
            return try admitCompletedEnhancement(
                result,
                enhancedOriginal: enhancedOriginal,
                attempt: current,
                original: frame,
                originalDelay: originalDelay,
                playbackRate: playbackRate,
                renderer: renderer
            )
        case .bypassed:
            break
        }
        return try admitOriginal(
            frame,
            renderer: renderer,
            midpointCount: current.admittedMidpointCount,
            committedPlan: current.committedPlan,
            playbackRate: playbackRate,
            activeOriginalDuration: current.activeOriginalDuration
        )
    }

    @discardableResult
    private func drainPendingEnhancedOutput(
        renderer: AVSampleBufferVideoRenderer
    ) -> PendingOutputDrainOutcome {
        guard !pendingEnhancedOutput.isEmpty else { return .drained }
        if recoverFaultedRenderer(renderer) {
            return .rendererFault
        }
        let clock = displayClockSeconds
        let canDropLateMidpoints = clock.isFinite && displayRate > 0 && synchronizer.rate > 0
        var headIndex = 0
        defer {
            if headIndex > 0 {
                if headIndex >= pendingEnhancedOutput.count {
                    pendingEnhancedOutput.removeAll(keepingCapacity: true)
                } else {
                    pendingEnhancedOutput.removeFirst(headIndex)
                }
            }
        }
        while headIndex < pendingEnhancedOutput.count {
            let item = pendingEnhancedOutput[headIndex]
            if item.isMidpoint, !item.commitsPresentationProgress,
               canDropLateMidpoints, item.frame.pts < clock - 0.004 {
                enhancementDiagnostics.noteInterpolationDeadline("Interpolation presentation deadline")
                headIndex += 1
                continue
            }
            guard renderer.isReadyForMoreMediaData else {
                return .blocked
            }
            if let fallbackOriginal = item.fallbackOriginal {
                switch enqueueOptionalFrame(
                    item.frame,
                    renderer: renderer,
                    isMidpoint: item.isMidpoint,
                    sampleDurationOverride: item.sampleDurationOverride,
                    commitsProgress: item.commitsPresentationProgress
                ) {
                case .enqueued:
                    headIndex += 1
                case .blocked:
                    return .blocked
                case .rendererFault:
                    headIndex = 0
                    return .rendererFault
                case nil:
                    enhancementDiagnostics.superResolution.rejected += 1
                    pendingEnhancedOutput[headIndex] = PendingEnhancedFrame(
                        frame: fallbackOriginal,
                        isMidpoint: false,
                        sampleDurationOverride: item.sampleDurationOverride,
                        fallbackOriginal: nil,
                        commitsPresentationProgress: true
                    )
                    switch enqueueOptionalFrame(
                        fallbackOriginal,
                        renderer: renderer,
                        isMidpoint: false,
                        sampleDurationOverride: item.sampleDurationOverride,
                        commitsProgress: true
                    ) {
                    case .enqueued:
                        headIndex += 1
                    case .blocked:
                        return .blocked
                    case .rendererFault:
                        headIndex = 0
                        return .rendererFault
                    case nil:
                        headIndex += 1
                    }
                }
            } else {
                switch enqueueOptionalFrame(
                    item.frame,
                    renderer: renderer,
                    isMidpoint: item.isMidpoint,
                    sampleDurationOverride: item.sampleDurationOverride,
                    commitsProgress: item.commitsPresentationProgress
                ) {
                case .enqueued:
                    headIndex += 1
                case .blocked:
                    return .blocked
                case .rendererFault:
                    headIndex = 0
                    return .rendererFault
                case nil:
                    headIndex += 1
                }
            }
        }
        return .drained
    }

    private func admitMidpointsIfUsable(
        _ attempt: inout EnhancementAttempt,
        original: MediaVideoFrame,
        reference: MediaVideoFrame,
        clock: TimeInterval,
        playbackRate: Double,
        renderer: AVSampleBufferVideoRenderer
    ) -> MidpointDrainOutcome {
        guard case let .draining(remaining, initialAdmittedCount, initialLastAdmitted) = attempt.midpoint else {
            return .completed
        }
        var admittedCount = initialAdmittedCount
        var lastAdmitted = initialLastAdmitted
        var newlyAdmitted = 0
        for item in remaining {
            let midpoint = item.frame
            let basePreviousPTS = lastAdmitted?.pts ?? reference.pts
            let previousPTS = lastQueuedPTS.map { max(basePreviousPTS, $0) } ?? basePreviousPTS
            guard isUsableMidpoint(midpoint, after: previousPTS, before: original.pts) else { continue }
            guard isMidpointTimely(midpoint, clock: clock, playbackRate: playbackRate) else { continue }
            pendingEnhancedOutput.append(PendingEnhancedFrame(
                frame: midpoint,
                isMidpoint: true,
                sampleDurationOverride: nil,
                fallbackOriginal: nil,
                commitsPresentationProgress: false
            ))
            admittedCount += 1
            newlyAdmitted += 1
            lastAdmitted = midpoint
        }
        attempt.midpoint = .resolved(admittedCount: admittedCount, lastAdmitted: lastAdmitted)
        if newlyAdmitted > 0 {
            if drainPendingEnhancedOutput(renderer: renderer) == .rendererFault {
                return .rendererFault
            }
            syncNativeMediaDataRequest()
            if let lastAdmitted {
                enhancementDiagnostics.midpointsEnqueued += newlyAdmitted
                postProcessor.noteMidpointAccepted(
                    lastAdmitted,
                    previous: reference,
                    original: original,
                    acceptedCount: admittedCount,
                    plan: attempt.committedPlan
                )
            }
        }
        return .completed
    }

    private func isMidpointTimely(
        _ midpoint: MediaVideoFrame,
        clock: TimeInterval,
        playbackRate: Double
    ) -> Bool {
        guard enhancementDelay(pts: midpoint.pts, clock: clock, rate: playbackRate) != nil else {
            enhancementDiagnostics.noteInterpolationDeadline("Interpolation presentation deadline")
            return false
        }
        return true
    }

    private func admitCompletedEnhancement(
        _ result: VideoFrameEnhancementResult,
        enhancedOriginal: EnhancedOriginalAdmission,
        attempt: EnhancementAttempt,
        original: MediaVideoFrame,
        originalDelay: TimeInterval?,
        playbackRate: Double,
        renderer: AVSampleBufferVideoRenderer
    ) throws -> DemandFramePresentationResult {
        if attempt.committedPlan?.emitsOriginal == false,
           attempt.admittedMidpointCount > 0,
           let lastMidpoint = attempt.lastAdmittedMidpoint {
            return completeMidpointOnlyEnhancement(
                original: original,
                lastMidpoint: lastMidpoint,
                result: result,
                midpointCount: attempt.admittedMidpointCount,
                committedPlan: attempt.committedPlan,
                playbackRate: playbackRate,
                renderer: renderer
            )
        }
        var candidate = enhancedOriginal
        if case .ready = enhancedOriginal {
            if !attempt.canUpscale {
                candidate = .unavailable
            } else if originalDelay == nil || ContinuousClock.now >= attempt.deadlines.original {
                candidate = .late
            }
        }
        let outcome = try admitOriginal(
            original,
            renderer: renderer,
            enhancedOriginal: candidate,
            result: result,
            midpointCount: attempt.admittedMidpointCount,
            committedPlan: attempt.committedPlan,
            playbackRate: playbackRate,
            activeOriginalDuration: attempt.activeOriginalDuration
        )
        if case .blockedOnASBD = outcome, case .ready = enhancedOriginal {
            switch candidate {
            case .ready:
                break
            case .late, .unavailable:
                var updated = attempt
                updated.state = .ready(result, enhancedOriginal: candidate)
                enhancementAttempt = updated
            }
        }
        return outcome
    }

    private func completeMidpointOnlyEnhancement(
        original: MediaVideoFrame,
        lastMidpoint: MediaVideoFrame,
        result: VideoFrameEnhancementResult,
        midpointCount: Int,
        committedPlan: VideoFrameInterpolationPlan?,
        playbackRate: Double,
        renderer: AVSampleBufferVideoRenderer
    ) -> DemandFramePresentationResult {
        let boundary = enhancementBoundary
        let lastPendingIndex = pendingEnhancedOutput.indices.last
        let lastMidpointStillPending = lastPendingIndex.map { idx in
            let item = pendingEnhancedOutput[idx]
            return item.isMidpoint && item.frame.pts == lastMidpoint.pts
        } ?? false
        if lastMidpointStillPending, let lastPendingIndex {
            pendingEnhancedOutput[lastPendingIndex].commitsPresentationProgress = true
            syncNativeMediaDataRequest()
        } else {
            consecutiveRendererFaultCount = 0
            if let end = finitePresentationIntervalEnd(start: lastMidpoint.pts, duration: lastMidpoint.duration) {
                maxEnqueuedPresentationEnd = max(maxEnqueuedPresentationEnd, end)
            }
            presentCount += 1
            lastEnqueuedPTS = lastMidpoint.pts
            presentationProgressSerial &+= 1
            if presentationProgressSerial == 0 { presentationProgressSerial = 1 }
            lastPresentationProgressUptime = ProcessInfo.processInfo.systemUptime
            if presentationProofState.isAwaiting {
                reduceAndPublishPresentationProof(
                    framePTS: lastMidpoint.pts,
                    frameDuration: lastMidpoint.duration,
                    surfaceReadiness: currentPresentationSurfaceReadiness(),
                    rendererHealthy: renderer.status != .failed
                        && !renderer.requiresFlushToResumeDecoding,
                    expectedHoldID: presentationImageHoldState?.id
                )
            }
        }
        if enhancementBoundary == boundary {
            recordOriginalAdmission(
                original,
                result: result,
                midpointCount: midpointCount,
                upscaled: nil,
                emittedOriginal: false,
                committedPlan: committedPlan,
                playbackRate: playbackRate
            )
        }
        return .enqueued
    }

    private func recordSkippedOriginalAdmission(
        _ original: MediaVideoFrame,
        committedPlan: VideoFrameInterpolationPlan,
        playbackRate: Double
    ) {
        clearEnhancementAttempt()
        postProcessor.noteOriginalPresented(
            original,
            result: nil,
            midpointCount: 0,
            upscaled: nil,
            emittedOriginal: false,
            committedPlan: committedPlan,
            playbackRate: playbackRate
        )
        guard tracksEnhancementAdmissions else { return }
        enhancementReference = original
        postProcessor.prewarmIfNeeded(with: original, playbackRate: playbackRate)
        reportEnhancementDiagnosticsIfNeeded()
    }

    private func isUsableMidpoint(
        _ midpoint: MediaVideoFrame, after previousPTS: TimeInterval, before originalPTS: TimeInterval
    ) -> Bool {
        guard finitePresentationIntervalEnd(start: midpoint.pts, duration: midpoint.duration) != nil,
              midpoint.pts + 1e-9 >= max(demandOutputFloor, presentationProofFloor ?? 0),
              midpoint.pts > previousPTS, midpoint.pts < originalPTS else { return false }
        let nativeTime = CMTime(seconds: midpoint.pts, preferredTimescale: mediaTimescale)
        let previousTime = CMTime(seconds: max(0, previousPTS), preferredTimescale: mediaTimescale)
        let originalTime = CMTime(seconds: max(0, originalPTS), preferredTimescale: mediaTimescale)
        return nativeTime > previousTime && nativeTime < originalTime
    }

    private func enqueueOptionalFrame(
        _ frame: MediaVideoFrame,
        renderer: AVSampleBufferVideoRenderer,
        isMidpoint: Bool,
        sampleDurationOverride: TimeInterval? = nil,
        commitsProgress: Bool? = nil
    ) -> NativeFrameAdmission? {
        do {
            return try enqueueSingleFrame(
                frame,
                renderer: renderer,
                isMidpoint: isMidpoint,
                sampleDurationOverride: sampleDurationOverride,
                commitsProgress: commitsProgress
            )
        } catch {
            postProcessor.noteBypass("Invalid enhancement output")
            return nil
        }
    }

    private func invalidateEnhancedOriginalCandidate() {
        guard var attempt = enhancementAttempt,
              case let .ready(result, .ready) = attempt.state else { return }
        attempt.state = .ready(result, enhancedOriginal: .unavailable)
        enhancementAttempt = attempt
    }

    private func admitOriginal(
        _ original: MediaVideoFrame,
        renderer: AVSampleBufferVideoRenderer,
        enhancedOriginal: EnhancedOriginalAdmission = .unavailable,
        result: VideoFrameEnhancementResult? = nil,
        midpointCount: Int = 0,
        committedPlan: VideoFrameInterpolationPlan? = nil,
        playbackRate: Double? = nil,
        activeOriginalDuration: TimeInterval? = nil
    ) throws -> DemandFramePresentationResult {
        let boundary = enhancementBoundary
        let effectiveRate = playbackRate ?? (displayRate > 0 ? Double(displayRate) : 1.0)
        let sampleDurationOverride: TimeInterval?
        if let committedPlan,
           committedPlan.outputFrameDuration.isFinite,
           committedPlan.outputFrameDuration > 0,
           committedPlan.outputFrameDuration < original.duration {
            sampleDurationOverride = committedPlan.outputFrameDuration
        } else if let activeOriginalDuration,
                  activeOriginalDuration.isFinite,
                  activeOriginalDuration > 0,
                  activeOriginalDuration < original.duration {
            sampleDurationOverride = activeOriginalDuration
        } else {
            sampleDurationOverride = nil
        }

        let shouldQueueForPipeline = !pendingEnhancedOutput.isEmpty
            || (!renderer.isReadyForMoreMediaData && tracksEnhancementAdmissions && (result != nil || midpointCount > 0))
        if shouldQueueForPipeline {
            let pendingItem: PendingEnhancedFrame
            let admittedEnhancedOriginal: MediaVideoFrame?
            if case let .ready(candidate) = enhancedOriginal {
                pendingItem = PendingEnhancedFrame(
                    frame: candidate,
                    isMidpoint: false,
                    sampleDurationOverride: sampleDurationOverride,
                    fallbackOriginal: original,
                    commitsPresentationProgress: true
                )
                admittedEnhancedOriginal = candidate
            } else {
                pendingItem = PendingEnhancedFrame(
                    frame: original,
                    isMidpoint: false,
                    sampleDurationOverride: sampleDurationOverride,
                    fallbackOriginal: nil,
                    commitsPresentationProgress: true
                )
                admittedEnhancedOriginal = nil
            }
            pendingEnhancedOutput.append(pendingItem)
            if drainPendingEnhancedOutput(renderer: renderer) == .rendererFault {
                return recordRendererFault(renderer, reason: "ASBD fault draining pending enhancement output")
            }
            syncNativeMediaDataRequest()
            if enhancementBoundary == boundary {
                if case .late = enhancedOriginal {
                    enhancementDiagnostics.superResolution.late += 1
                }
                recordOriginalAdmission(
                    original,
                    result: result,
                    midpointCount: midpointCount,
                    upscaled: admittedEnhancedOriginal,
                    emittedOriginal: true,
                    committedPlan: committedPlan,
                    playbackRate: effectiveRate
                )
            }
            return .enqueued
        }

        var admittedEnhancedOriginal: MediaVideoFrame?
        if case let .ready(candidate) = enhancedOriginal {
            switch enqueueOptionalFrame(
                candidate,
                renderer: renderer,
                isMidpoint: false,
                sampleDurationOverride: sampleDurationOverride
            ) {
            case .enqueued: admittedEnhancedOriginal = candidate
            case .blocked: return noteNativeWait()
            case .rendererFault: return recordRendererFault(renderer, reason: "ASBD fault on enhanced frame")
            case nil:
                enhancementDiagnostics.superResolution.rejected += 1
                invalidateEnhancedOriginalCandidate()
            }
        }
        if admittedEnhancedOriginal == nil {
            switch try enqueueSingleFrame(
                original,
                renderer: renderer,
                isMidpoint: false,
                sampleDurationOverride: sampleDurationOverride
            ) {
            case .enqueued: break
            case .blocked: return noteNativeWait()
            case .rendererFault: return recordRendererFault(renderer, reason: "ASBD fault on original frame")
            }
        }
        if enhancementBoundary == boundary {
            if case .late = enhancedOriginal {
                enhancementDiagnostics.superResolution.late += 1
            }
            recordOriginalAdmission(
                original,
                result: result,
                midpointCount: midpointCount,
                upscaled: admittedEnhancedOriginal,
                emittedOriginal: true,
                committedPlan: committedPlan,
                playbackRate: effectiveRate
            )
        }
        return .enqueued
    }

    private var tracksEnhancementAdmissions: Bool {
        postProcessor.configuration.isRequested && !postProcessor.configuration.isLiveStream
    }

    private var tracksSuperResolutionAdmissions: Bool {
        let config = postProcessor.configuration
        return config.superResolutionMode != .off && !config.isLiveStream
    }

    private func recordOriginalAdmission(
        _ original: MediaVideoFrame,
        result: VideoFrameEnhancementResult?,
        midpointCount: Int,
        upscaled: MediaVideoFrame?,
        emittedOriginal: Bool = true,
        committedPlan: VideoFrameInterpolationPlan? = nil,
        playbackRate: Double = 1.0
    ) {
        clearEnhancementAttempt()
        postProcessor.noteOriginalPresented(
            original,
            result: result,
            midpointCount: midpointCount,
            upscaled: upscaled,
            emittedOriginal: emittedOriginal,
            committedPlan: committedPlan,
            playbackRate: playbackRate
        )
        guard tracksEnhancementAdmissions else { return }
        enhancementReference = original
        postProcessor.prewarmIfNeeded(with: original, playbackRate: playbackRate)
        if emittedOriginal {
            enhancementDiagnostics.originalsEnqueued += 1
        }
        if let upscaled {
            enhancementDiagnostics.superResolution.noteEnqueued(
                input: original.pixelBuffer, output: upscaled.pixelBuffer
            )
        } else if !emittedOriginal, midpointCount > 0, result?.midpointsUpscaled == true,
                  let midpointBuffer = result?.midpoints.first?.frame.pixelBuffer {
            enhancementDiagnostics.superResolution.noteEnqueued(
                input: original.pixelBuffer, output: midpointBuffer
            )
        }
        reportEnhancementDiagnosticsIfNeeded()
    }

    private func noteNativeWait() -> DemandFramePresentationResult {
        if tracksEnhancementAdmissions {
            enhancementDiagnostics.nativeWaits += 1
            reportEnhancementDiagnosticsIfNeeded()
        }
        return .blockedOnASBD
    }

    private func reportEnhancementDiagnosticsIfNeeded() {
        guard PlayerLog.isCapturing else { return }
        let now = ContinuousClock.now
        if let last = enhancementDiagnostics.lastReport, last.duration(to: now) < .seconds(1) { return }
        let value = enhancementDiagnostics
        enhancementDiagnostics = EnhancementDiagnostics(lastReport: now)
        let config = postProcessor.configuration
        let interpolation = config.frameInterpolationEnabled ? postProcessor.interpolationLabel : "Off"
        PlayerLog.log(
            "[PathA][enhancement] rendererID=\(debugRendererID) fi=\(interpolation) " +
                "submit=\(value.submissions) " +
                "complete=\(value.completions) generated=\(value.midpointsGenerated) " +
                "deadline=\(value.deadlinesMissed) workerBusy=\(value.workerBusy) nativeWait=\(value.nativeWaits) " +
                "original=\(value.originalsEnqueued) midpoint=\(value.midpointsEnqueued) " +
                "fiBypass=\(value.lastInterpolationBypass ?? "none") " +
                value.superResolution.summary(configuredMode: config.superResolutionMode)
        )
    }
}

/// Single reusable main-queue `DispatchSourceTimer` for enhancement deadline wakeups,
/// eliminating per-frame `Task` + `ContinuousClock.sleep` allocation and cancellation storms.
@MainActor
private final class EnhancementDeadlineTimer {
    private let source: DispatchSourceTimer

    init(onFire: @escaping @MainActor () -> Void) {
        let timer = DispatchSource.makeTimerSource(flags: [], queue: .main)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler {
            MainActor.assumeIsolated {
                onFire()
            }
        }
        timer.resume()
        source = timer
    }

    deinit {
        source.cancel()
    }

    func arm(until deadline: ContinuousClock.Instant) {
        let remaining = ContinuousClock.now.duration(to: deadline)
        if remaining <= .zero {
            source.schedule(deadline: .now(), repeating: .never, leeway: .milliseconds(1))
            return
        }
        let secs = min(Int64(60), remaining.components.seconds)
        let nanos = secs * 1_000_000_000 + remaining.components.attoseconds / 1_000_000_000
        source.schedule(
            deadline: .now() + .nanoseconds(Int(clamping: max(1, nanos))),
            repeating: .never,
            leeway: .milliseconds(2)
        )
    }

    func disarm() {
        source.schedule(deadline: .distantFuture)
    }
}

private struct SuperResolutionDiagnostics {
    private typealias Dimensions = (width: Int, height: Int)

    var originalsProcessed = 0
    var late = 0
    var rejected = 0
    private var originalsEnqueued = 0
    private var bypasses = 0
    private var lastBypass: String?
    private var lastEnqueuedSize: (input: Dimensions, output: Dimensions)?

    mutating func noteBypass(_ reason: String) {
        bypasses += 1
        lastBypass = reason
    }

    mutating func noteEnqueued(input: CVPixelBuffer, output: CVPixelBuffer) {
        originalsEnqueued += 1
        lastEnqueuedSize = (
            (CVPixelBufferGetWidth(input), CVPixelBufferGetHeight(input)),
            (CVPixelBufferGetWidth(output), CVPixelBufferGetHeight(output))
        )
    }

    func summary(configuredMode: VideoSuperResolutionMode) -> String {
        let size = lastEnqueuedSize.map {
            "\($0.input.width)x\($0.input.height)→\($0.output.width)x\($0.output.height)"
        } ?? "none"
        let output = originalsEnqueued > 0 ? configuredMode.rawValue : "none"
        return "srConfigured=\(configuredMode.rawValue) srOutput=\(output) " +
            "srOriginalProcessed=\(originalsProcessed) srOriginalEnqueued=\(originalsEnqueued) srSize=\(size) " +
            "srBypass=\(bypasses) srLate=\(late) srRejected=\(rejected) srLastBypass=\"\(lastBypass ?? "none")\""
    }
}

@MainActor
final class SampleBufferDisplayView: UIView {
    var onPresentationSurfaceChanged: (() -> Void)?

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onPresentationSurfaceChanged?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onPresentationSurfaceChanged?()
    }

    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }
}

@MainActor
final class PresentationImageHoldView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }
}

enum EnginePiPLeaseEvent: String, Sendable, Equatable {
    case didStart
    case didStop
    case failedToStart
}

extension EnginePiPLeaseEvent {
    var nativeTransition: DemandPiPNativeEvent {
        switch self {
        case .didStart: .didStart
        case .didStop: .didStop
        case .failedToStart: .failedToStart
        }
    }
}

struct EnginePiPLeaseState: Sendable, Equatable {
    private(set) var isActive = false

    mutating func apply(_ event: EnginePiPLeaseEvent) -> Bool {
        let next = event == .didStart
        guard next != isActive else { return false }
        isActive = next
        return true
    }

    mutating func reset() {
        isActive = false
    }
}

enum EnginePiPTransportEvent: Sendable, Equatable {
    case transportIntent(
        operation: UInt64,
        playing: Bool,
        sessionGeneration: UInt64,
        pipBindingGeneration: UInt64?,
        ownerLeaseGeneration: UInt64
    )
    case seekSettled(
        operation: UInt64,
        position: TimeInterval,
        sessionGeneration: UInt64,
        pipBindingGeneration: UInt64?,
        ownerLeaseGeneration: UInt64
    )
}

@MainActor
final class EnginePiPTransportCompletion {
    private let handler: () -> Void
    private var didComplete = false

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func complete() {
        guard !didComplete else { return }
        didComplete = true
        handler()
    }
}

@MainActor
protocol EnginePiPTransportDelegate: AnyObject {
    func setPlayingFromPiP(_ playing: Bool)
    func skipFromPiP(
        by interval: TimeInterval,
        completion: EnginePiPTransportCompletion
    )
}

@MainActor
final class EnginePiPPlaybackDelegate: NSObject, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPaused = true
    weak var transportDelegate: (any EnginePiPTransportDelegate)?
    private weak var currentController: AVPictureInPictureController?

    var hasTransportDelegate: Bool { transportDelegate != nil }

    func bind(to controller: AVPictureInPictureController?) {
        currentController = controller
    }

    private func accepts(_ controller: AVPictureInPictureController) -> Bool {
        currentController === controller
    }

    func update(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        self.currentTime = max(0, currentTime.isFinite ? currentTime : 0)
        self.duration = max(0, duration.isFinite ? duration : 0)
        isPaused = !isPlaying
    }

    var playbackTimeRange: CMTimeRange {
        guard duration > 0 else {
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        guard accepts(pictureInPictureController) else { return }
        transportDelegate?.setPlayingFromPiP(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        playbackTimeRange
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        isPaused
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        guard accepts(pictureInPictureController) else { return true }
        return false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        _ = newRenderSize
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        guard accepts(pictureInPictureController) else {
            completionHandler()
            return
        }
        let seconds = CMTimeGetSeconds(skipInterval)
        guard seconds.isFinite else {
            PlayerLog.log("[PathA] PiP skip ignored — invalid interval")
            completionHandler()
            return
        }
        guard let transportDelegate else {
            PlayerLog.log("[PathA] PiP skip ignored — transport unavailable")
            completionHandler()
            return
        }
        transportDelegate.skipFromPiP(
            by: seconds,
            completion: EnginePiPTransportCompletion(completionHandler)
        )
    }
}
