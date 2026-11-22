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
}

@MainActor
final class SampleBufferVideoRenderer: NSObject, MediaVideoPresentation, MediaPiPLeaseEventSource, @preconcurrency AVPictureInPictureControllerDelegate {
    private static var nextDebugRendererID: UInt64 = 0

    let hostViewController: UIViewController
    private let displayView: SampleBufferDisplayView
    private let presentationHoldView: PresentationImageHoldView
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let postProcessor = VideoFramePostProcessor()
    private var enhancementAttempt: EnhancementAttempt?
    private var enhancementDeadlineWake: Task<Void, Never>?
    private var nextEnhancementID: UInt64 = 0
    private var enhancementBoundary: UInt64 = 0
    private var enhancementReference: MediaVideoFrame?
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
    private let mediaTimescale: CMTimeScale = 600
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
        holdView.backgroundColor = .black
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

    // MARK: - A2-α display

    private struct DisplayNativeSample {
        let owner: MediaDisplayLease
        let presentationTime: CMTime
        let presentationDuration: CMTime
    }
    private var displayNative: [DisplayNativeSample] = []

    var videoEnhancementConfiguration: VideoEnhancementConfiguration {
        get { postProcessor.configuration }
        set {
            guard postProcessor.configuration != newValue else { return }
            postProcessor.configuration = newValue
            retireEnhancement(wakeWaitingDrain: true)
        }
    }

    var videoEnhancementTelemetry: VideoEnhancementTelemetry {
        postProcessor.telemetry
    }

    func setDisplayPlayback(rate: Float, mediaTime: TimeInterval) {
        displayNative.removeAll { ($0.owner.interval?.upper.seconds ?? mediaTime) <= mediaTime }
        let native = displayView.sampleBufferLayer.sampleBufferRenderer
        let rendererFault = native.status == .failed || native.requiresFlushToResumeDecoding
        if rendererFault { displayNative.removeAll() }
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
        let costSpan = UIHitchMonitor.beginSpan("render.present")
        defer { UIHitchMonitor.endSpan(costSpan) }
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
        displayNative.removeAll()
        renderer.flush()
        flushCount += 1
        presentationProofState.clearCandidate()
        return true
    }

    private func enqueueSingleFrame(
        _ frame: MediaVideoFrame,
        renderer: AVSampleBufferVideoRenderer,
        isMidpoint: Bool
    ) throws -> NativeFrameAdmission {
        let makeSpan = UIHitchMonitor.beginSpan("render.makeSample")
        let sample: CMSampleBuffer
        do {
            sample = try Self.makeSampleBuffer(
                pixelBuffer: frame.pixelBuffer,
                pts: frame.pts,
                duration: frame.duration,
                timescale: mediaTimescale
            )
        } catch {
            UIHitchMonitor.endSpan(makeSpan)
            throw error
        }
        UIHitchMonitor.endSpan(makeSpan)
        guard !recoverFaultedRenderer(renderer) else { return .rendererFault }
        let isReadyForMoreMediaData = renderer.isReadyForMoreMediaData
        guard isReadyForMoreMediaData else { return .blocked }

        UIHitchMonitor.measureCounted("render.enqueue") { renderer.enqueue(sample) }
        guard !recoverFaultedRenderer(renderer) else { return .rendererFault }
        latestAmbientPixelBuffer = frame.pixelBuffer
        guard !isMidpoint else {
            SurfaceMoveProbe.noteFrameEnqueued()
            return .enqueued
        }
        if let owner = frame.displayCoverage {
            displayNative.append(DisplayNativeSample(
                owner: owner, presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),
                presentationDuration: CMSampleBufferGetDuration(sample)
            ))
        }
        SurfaceMoveProbe.noteFrameEnqueued()
        presentCount += 1
        lastEnqueuedPTS = frame.pts
        presentationProgressSerial &+= 1
        if presentationProgressSerial == 0 { presentationProgressSerial = 1 }
        lastPresentationProgressUptime = ProcessInfo.processInfo.systemUptime
        reduceAndPublishPresentationProof(
            framePTS: frame.pts,
            frameDuration: frame.duration,
            surfaceReadiness: currentPresentationSurfaceReadiness(),
            rendererHealthy: renderer.status != .failed
                && !renderer.requiresFlushToResumeDecoding,
            expectedHoldID: presentationImageHoldState?.id
        )
        if !didLogFirstEnqueueDisplaySnapshot {
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

    func sampleDisplayClockAndRetireCompletedEvidence() -> TimeInterval {
        let displayTime = synchronizer.currentTime()
        let seconds = CMTimeGetSeconds(displayTime)
        guard displayTime.isValid, displayTime.isNumeric, seconds.isFinite else { return seconds }
        displayNative.removeAll { sample in
            let duration = sample.presentationDuration
            guard sample.presentationTime.isValid, sample.presentationTime.isNumeric,
                  sample.presentationTime.epoch == displayTime.epoch,
                  duration.isValid, duration.isNumeric, duration.epoch == 0,
                  duration.value > 0 else { return false }
            let end = CMTimeAdd(sample.presentationTime, duration)
            guard end.isValid, end.isNumeric, end.epoch == displayTime.epoch,
                  CMTimeGetSeconds(end).isFinite else { return false }
            return CMTimeCompare(end, displayTime) <= 0
        }
        return seconds
    }

    var isReadyForMoreMediaData: Bool {
        let costSpan = UIHitchMonitor.beginSpan("render.ready")
        defer { UIHitchMonitor.endSpan(costSpan) }
        attachSynchronizerIfNeeded()
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
        let costSpan = UIHitchMonitor.beginSpan("still.total")
        defer { UIHitchMonitor.endSpan(costSpan) }
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        let pixelBuffer = UIHitchMonitor.measureCounted("still.pixels") {
            frontmostNonWarmPresentationPixelBuffer()
                ?? renderer.displayedPixelBuffer()
        }
        guard let pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let maxDimension: CGFloat = 640
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let scaled = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let cgImage = UIHitchMonitor.measureCounted("still.image") {
            thumbnailContext.createCGImage(scaled, from: scaled.extent.integral)
        }
        guard let cgImage else {
            return nil
        }
        return UIImage(
            cgImage: cgImage,
            scale: UIScreen.main.scale,
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
        displayNative.removeAll()
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
            displayNative.removeAll()
            renderer.flush()
            flushCount += 1
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
        displayNative.removeAll()
        renderer.flush()
        flushCount += 1
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

    func requestMediaDataWhenReady(_ handler: @escaping () -> Void) {
        attachSynchronizerIfNeeded()
        mediaDataWhenReadyHandler = handler
        guard !isRequestingMediaData else { return }
        isRequestingMediaData = true
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        renderer.requestMediaDataWhenReady(on: DispatchQueue.main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.isRequestingMediaData else { return }
                self.mediaDataWhenReadyHandler?()
            }
        }
    }

    func stopRequestingMediaData() {
        mediaDataWhenReadyHandler = nil
        guard isRequestingMediaData else { return }
        isRequestingMediaData = false
        displayView.sampleBufferLayer.sampleBufferRenderer.stopRequestingMediaData()
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
        synchronizer.setRate(0, time: CMTime(
            seconds: lastDisplayMediaTime,
            preferredTimescale: mediaTimescale
        ))
        displayRate = 0
        displayNative.removeAll()
        latestAmbientPixelBuffer = nil
        flushRenderer(displayView.sampleBufferLayer.sampleBufferRenderer)
        flushCount += 1
        presentationProofState.clearCandidateAndFloor()
        presentationProofFloor = nil
        lastPresentationProgressUptime = nil
    }

    func invalidate() {
        retireEnhancement()
        postProcessor.tearDown()
        stopPiP()
        updatePiPPlaybackState(currentTime: 0, duration: 0, isPlaying: false)
        stopRequestingMediaData()
        clearPresentationImageHold()
        synchronizer.setRate(0, time: .zero)
        displayRate = 0
        lastDisplayMediaTime = 0
        displayNative.removeAll()
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
        case ready([PostProcessFrameBox])
        case resolved(admittedCount: Int)

        var isResolved: Bool {
            if case .resolved = self { return true }
            return false
        }
    }

    private enum EnhancedOriginalAdmission {
        case unavailable
        case late
        case ready(MediaVideoFrame)
    }

    private struct EnhancementAttempt {
        let id: UInt64
        let frame: EnhancementFrameIdentity
        let deadlines: VideoEnhancementDeadlines
        let canUpscale: Bool
        let wake: @MainActor () -> Void
        var state = EnhancementState.processing
        var midpoint: MidpointAdmission

        var workDeadline: ContinuousClock.Instant { deadlines.workDeadline(upscaling: canUpscale) }

        var admittedMidpointCount: Int {
            if case let .resolved(count) = midpoint { return count }
            return 0
        }
    }

    private struct EnhancementPresentation {
        let original: MediaVideoFrame
        let reference: MediaVideoFrame
        let mediaTime: TimeInterval
        let playbackRate: Double
        let canUpscale: Bool
        let originalDelay: TimeInterval?
        let hasInterpolationPlan: Bool
        let midpointDelay: TimeInterval?
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
        let costSpan = UIHitchMonitor.beginSpan("render.present")
        defer { UIHitchMonitor.endSpan(costSpan) }
        try validatePresentationFrame(frame)
        guard frame.pts + 1e-9 >= demandOutputFloor else {
            throw MediaEngineError.renderFailed("frame below current Demand output floor")
        }
        attachSynchronizerIfNeeded()
        let renderer = displayView.sampleBufferLayer.sampleBufferRenderer
        _ = recoverFaultedRenderer(renderer)
        discardEnhancementForReplacedHead(frame)
        guard renderer.isReadyForMoreMediaData else { return noteNativeWait() }
        guard let request = enhancementPresentation(frame, mediaTime: mediaTime, rate: playbackRate) else {
            return try admitOriginal(frame, renderer: renderer)
        }
        if let attempt = enhancementAttempt {
            return try resumeEnhancement(attempt, request: request, renderer: renderer)
        }
        guard let deadlines = enhancementDeadlines(for: request) else {
            return try admitOriginal(frame, renderer: renderer)
        }
        startEnhancement(request, deadlines: deadlines, wake: onEnhancementWake)
        return .waitingOnEnhancement
    }

    private func discardEnhancementForReplacedHead(_ frame: MediaVideoFrame) {
        guard let attempt = enhancementAttempt, attempt.frame != EnhancementFrameIdentity(frame) else { return }
        clearEnhancementAttempt()
        postProcessor.flush()
    }

    private func enhancementPresentation(
        _ frame: MediaVideoFrame, mediaTime: TimeInterval, rate: Double
    ) -> EnhancementPresentation? {
        let canProcess = postProcessor.canProcess(frame)
        guard canProcess, let reference = enhancementReference else {
            if tracksSuperResolutionAdmissions {
                let reason = canProcess ? "No accepted reference" : postProcessor.telemetry.bypassReason
                enhancementDiagnostics.superResolution.noteBypass(reason ?? "Enhancement disabled")
            }
            abandonEnhancementOutput()
            return nil
        }
        let earliestMidpointPTS = postProcessor.interpolationPlan(previous: reference, current: frame)?.pts.first
        guard let clock = enhancementClock(mediaTime: mediaTime, rate: rate) else {
            let canStillAdmitMidpoints = enhancementAttempt.map { !$0.midpoint.isResolved }
                ?? (earliestMidpointPTS != nil)
            if canStillAdmitMidpoints {
                enhancementDiagnostics.lastInterpolationBypass = "Playback clock unavailable"
            }
            if tracksSuperResolutionAdmissions {
                enhancementDiagnostics.superResolution.noteBypass("Playback clock unavailable")
            }
            abandonEnhancementOutput()
            return nil
        }
        return EnhancementPresentation(
            original: frame, reference: reference, mediaTime: mediaTime, playbackRate: rate,
            canUpscale: postProcessor.canUpscale(frame),
            originalDelay: enhancementDelay(pts: frame.pts, clock: clock, rate: rate),
            hasInterpolationPlan: earliestMidpointPTS != nil,
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
            if request.canUpscale || request.hasInterpolationPlan { postProcessor.notePerformanceMiss() }
            return nil
        }
        guard request.midpointDelay != nil || request.canUpscale else {
            let reason = request.hasInterpolationPlan ? generationDeadlineReason : "No eligible interpolation plan"
            if request.hasInterpolationPlan { postProcessor.notePerformanceMiss() }
            postProcessor.noteBypass(reason)
            return nil
        }
        guard !postProcessor.isBusy else {
            postProcessor.notePerformanceMiss()
            enhancementDiagnostics.workerBusy += 1
            if request.midpointDelay != nil {
                enhancementDiagnostics.lastInterpolationBypass = "Interpolation worker busy"
            }
            if request.canUpscale { enhancementDiagnostics.superResolution.noteBypass("Enhancement worker busy") }
            postProcessor.noteBypass("Enhancement worker busy")
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
        return delay.isFinite && delay > 0 ? min(delay, 0.3) : nil
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
            id: id, frame: EnhancementFrameIdentity(request.original), deadlines: deadlines,
            canUpscale: request.canUpscale, wake: wake,
            midpoint: deadlines.midpoint == nil ? .resolved(admittedCount: 0) : .pending
        )
        enhancementAttempt = attempt
        let workDeadline = attempt.workDeadline
        enhancementDiagnostics.submissions += 1
        postProcessor.submit(
            request.original, previous: request.reference, deadlines: deadlines
        ) { [weak self] update in
            guard let self, self.enhancementBoundary == boundary else { return }
            self.receiveEnhancementUpdate(update, id: id)
        }
        enhancementDeadlineWake = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(until: workDeadline)
            } catch { return }
            guard let self, !Task.isCancelled, self.enhancementBoundary == boundary,
                  let attempt = self.enhancementAttempt,
                  attempt.id == id, case .processing = attempt.state else { return }
            self.expireEnhancement(attempt)
            attempt.wake()
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
            attempt.midpoint = .ready(midpoints)
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
            completed.midpoint = result.midpoints.isEmpty ? .resolved(admittedCount: 0) : .ready(result.midpoints)
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
        postProcessor.notePerformanceMiss()
        var expired = attempt
        if case .pending = expired.midpoint {
            enhancementDiagnostics.noteInterpolationDeadline("Interpolation generation deadline")
            expired.midpoint = .resolved(admittedCount: 0)
        } else if attempt.canUpscale {
            enhancementDiagnostics.deadlinesMissed += 1
        }
        if attempt.canUpscale { enhancementDiagnostics.superResolution.late += 1 }
        if attempt.admittedMidpointCount == 0 { postProcessor.noteBypass("Enhancement deadline") }
        bypassEnhancement(expired)
    }

    private func abandonEnhancementOutput() {
        guard var attempt = enhancementAttempt else { return }
        attempt.midpoint = .resolved(admittedCount: attempt.admittedMidpointCount)
        bypassEnhancement(attempt)
    }

    private func bypassEnhancement(_ attempt: EnhancementAttempt) {
        var bypassed = attempt
        bypassed.state = .bypassed
        enhancementAttempt = bypassed
        if case .bypassed = attempt.state { return }
        cancelEnhancementDeadlineWake()
        postProcessor.flush()
    }

    private func cancelEnhancementDeadlineWake() {
        enhancementDeadlineWake?.cancel()
        enhancementDeadlineWake = nil
    }

    private func clearEnhancementAttempt() {
        cancelEnhancementDeadlineWake()
        enhancementAttempt = nil
    }

    private func retireEnhancement(wakeWaitingDrain: Bool = false) {
        let waiting = enhancementAttempt.flatMap { attempt -> EnhancementAttempt? in
            if case .processing = attempt.state { return attempt }
            return nil
        }
        if enhancementAttempt != nil || enhancementReference != nil { postProcessor.noteDiscontinuity() }
        enhancementBoundary &+= 1
        enhancementDiagnostics = EnhancementDiagnostics(lastReport: enhancementDiagnostics.lastReport)
        clearEnhancementAttempt()
        enhancementReference = nil
        postProcessor.flush()
        if wakeWaitingDrain, let waiting {
            Task { @MainActor in waiting.wake() }
        }
    }

    private func resumeEnhancement(
        _ attempt: EnhancementAttempt,
        request: EnhancementPresentation,
        renderer: AVSampleBufferVideoRenderer
    ) throws -> DemandFramePresentationResult {
        var current = attempt
        guard admitMidpointsIfUsable(&current, request: request, renderer: renderer) else {
            return try admitOriginal(request.original, renderer: renderer)
        }
        enhancementAttempt = current
        switch current.state {
        case .processing:
            let delay = request.canUpscale ? request.originalDelay : request.midpointDelay
            if delay != nil, ContinuousClock.now < current.workDeadline { return .waitingOnEnhancement }
            expireEnhancement(current)
        case let .ready(result, enhancedOriginal):
            return try admitCompletedEnhancement(
                result, enhancedOriginal: enhancedOriginal, attempt: current, request: request, renderer: renderer
            )
        case .bypassed:
            break
        }
        return try admitOriginal(request.original, renderer: renderer)
    }

    private func admitMidpointsIfUsable(
        _ attempt: inout EnhancementAttempt,
        request: EnhancementPresentation,
        renderer: AVSampleBufferVideoRenderer
    ) -> Bool {
        guard case let .ready(candidates) = attempt.midpoint else { return true }
        var admittedCount = 0
        var lastAdmitted: MediaVideoFrame?
        phases: for candidate in candidates {
            let midpoint = candidate.frame
            let previousPTS = lastAdmitted?.pts ?? request.reference.pts
            guard isUsableMidpoint(midpoint, after: previousPTS, before: request.original.pts) else { continue }
            guard isMidpointTimely(midpoint, request: request) else { continue }
            switch enqueueOptionalFrame(midpoint, renderer: renderer, isMidpoint: true) {
            case .enqueued:
                admittedCount += 1
                lastAdmitted = midpoint
            case .blocked:
                enhancementDiagnostics.nativeWaits += 1
                break phases
            case nil:
                continue
            case .rendererFault:
                return false
            }
        }
        attempt.midpoint = .resolved(admittedCount: admittedCount)
        enhancementDiagnostics.midpointsEnqueued += admittedCount
        if let lastAdmitted {
            postProcessor.noteMidpointAccepted(
                lastAdmitted, previous: request.reference, original: request.original, acceptedCount: admittedCount
            )
        }
        return true
    }

    private func isMidpointTimely(_ midpoint: MediaVideoFrame, request: EnhancementPresentation) -> Bool {
        guard let clock = enhancementClock(mediaTime: request.mediaTime, rate: request.playbackRate) else {
            enhancementDiagnostics.lastInterpolationBypass = "Playback clock unavailable"
            return false
        }
        guard enhancementDelay(pts: midpoint.pts, clock: clock, rate: request.playbackRate) != nil else {
            enhancementDiagnostics.noteInterpolationDeadline("Interpolation presentation deadline")
            return false
        }
        return true
    }

    private func admitCompletedEnhancement(
        _ result: VideoFrameEnhancementResult,
        enhancedOriginal: EnhancedOriginalAdmission,
        attempt: EnhancementAttempt,
        request: EnhancementPresentation,
        renderer: AVSampleBufferVideoRenderer
    ) throws -> DemandFramePresentationResult {
        var candidate = enhancedOriginal
        if case .ready = enhancedOriginal {
            var retry = EnhancedOriginalAdmission.unavailable
            if !request.canUpscale {
                candidate = .unavailable
            } else if request.originalDelay == nil || ContinuousClock.now >= attempt.deadlines.original {
                candidate = .late
                retry = .late
            }
            var consumed = attempt
            consumed.state = .ready(result, enhancedOriginal: retry)
            enhancementAttempt = consumed
        }
        return try admitOriginal(
            request.original, renderer: renderer, enhancedOriginal: candidate,
            result: result, midpointCount: attempt.admittedMidpointCount
        )
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
        _ frame: MediaVideoFrame, renderer: AVSampleBufferVideoRenderer, isMidpoint: Bool
    ) -> NativeFrameAdmission? {
        do {
            return try enqueueSingleFrame(frame, renderer: renderer, isMidpoint: isMidpoint)
        } catch {
            postProcessor.noteBypass("Invalid enhancement output")
            return nil
        }
    }

    private func admitOriginal(
        _ original: MediaVideoFrame,
        renderer: AVSampleBufferVideoRenderer,
        enhancedOriginal: EnhancedOriginalAdmission = .unavailable,
        result: VideoFrameEnhancementResult? = nil,
        midpointCount: Int = 0
    ) throws -> DemandFramePresentationResult {
        let boundary = enhancementBoundary
        var admittedEnhancedOriginal: MediaVideoFrame?
        if case let .ready(candidate) = enhancedOriginal {
            switch enqueueOptionalFrame(candidate, renderer: renderer, isMidpoint: false) {
            case .enqueued: admittedEnhancedOriginal = candidate
            case .blocked: return noteNativeWait()
            case .rendererFault, nil: enhancementDiagnostics.superResolution.rejected += 1
            }
        }
        if admittedEnhancedOriginal == nil {
            switch try enqueueSingleFrame(original, renderer: renderer, isMidpoint: false) {
            case .enqueued: break
            case .blocked: return noteNativeWait()
            case .rendererFault: throw MediaEngineError.renderFailed("ASBD fault during presentation")
            }
        }
        if enhancementBoundary == boundary {
            if case .late = enhancedOriginal {
                enhancementDiagnostics.superResolution.late += 1
                postProcessor.notePerformanceMiss()
            }
            recordOriginalAdmission(
                original, result: result, midpointCount: midpointCount, upscaled: admittedEnhancedOriginal
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
        upscaled: MediaVideoFrame?
    ) {
        clearEnhancementAttempt()
        if let result {
            postProcessor.noteAccepted(result, midpointCount: midpointCount, enhancedOriginal: upscaled != nil)
        }
        guard tracksEnhancementAdmissions else { return }
        enhancementReference = original
        enhancementDiagnostics.originalsEnqueued += 1
        if let upscaled {
            enhancementDiagnostics.superResolution.noteEnqueued(
                input: original.pixelBuffer, output: upscaled.pixelBuffer
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
                "degrade=\(postProcessor.degradationLevel) " +
                value.superResolution.summary(configuredMode: config.superResolutionMode)
        )
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
        SurfaceMoveProbe.noteWindowMembership(inWindow: window != nil, generation: -1)
        onPresentationSurfaceChanged?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        SurfaceMoveProbe.noteDisplaySized(bounds: bounds)
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
