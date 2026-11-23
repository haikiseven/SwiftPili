import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Pure, simulator-testable dimension and pixel-format negotiation helpers for VideoToolbox ML SR.
enum VTSRNegotiation {
    static let preferredFallbackFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]

    /// Extracts pixel formats listed under `kCVPixelBufferPixelFormatTypeKey` (single value or array).
    static func attributeFormats(from attributes: [String: Any]) -> [OSType] {
        let key = kCVPixelBufferPixelFormatTypeKey as String
        if let values = attributes[key] as? [NSNumber] { return values.map(\.uint32Value) }
        if let values = attributes[key] as? [OSType] { return values }
        if let value = attributes[key] as? NSNumber { return [value.uint32Value] }
        if let value = attributes[key] as? OSType { return [value] }
        return []
    }

    /// Resolves destination dimensions from `destinationAttributes` when explicit `Width`/`Height`
    /// are provided and exceed the input; otherwise computes even-aligned `input * scale`.
    static func resolveOutputDimensions(
        inputWidth: Int,
        inputHeight: Int,
        scale: Float,
        destinationAttributes: [String: Any]
    ) -> (width: Int, height: Int)? {
        guard inputWidth > 0, inputHeight > 0, scale.isFinite, scale > 1 else { return nil }
        let widthKey = kCVPixelBufferWidthKey as String
        let heightKey = kCVPixelBufferHeightKey as String
        let explicitWidth = (destinationAttributes[widthKey] as? NSNumber)?.intValue
        let explicitHeight = (destinationAttributes[heightKey] as? NSNumber)?.intValue
        if let explicitWidth, let explicitHeight {
            guard explicitWidth > inputWidth, explicitHeight > inputHeight else { return nil }
            return (explicitWidth, explicitHeight)
        }
        func evenNearest(_ value: Double) -> Int { max(2, Int((value / 2.0).rounded()) * 2) }
        let width = explicitWidth ?? evenNearest(Double(inputWidth) * Double(scale))
        let height = explicitHeight ?? evenNearest(Double(inputHeight) * Double(scale))
        guard width > inputWidth, height > inputHeight else { return nil }
        return (width, height)
    }

    /// Returns all preferred formats in priority order that satisfy `nativeSupported` (when non-empty)
    /// and `attributeFormats` (when non-empty).
    static func candidateFormats(
        preferred: [OSType],
        nativeSupported: [OSType],
        attributeFormats: [OSType]
    ) -> [OSType] {
        var ordered: [OSType] = []
        for format in preferred where !ordered.contains(format) {
            ordered.append(format)
        }
        return ordered.filter { format in
            let matchesNative = nativeSupported.isEmpty || nativeSupported.contains(format)
            let matchesAttributes = attributeFormats.isEmpty || attributeFormats.contains(format)
            return matchesNative && matchesAttributes
        }
    }

    /// Selects the highest-priority pixel format compatible with `nativeSupported` and `attributeFormats`.
    static func selectFormat(
        preferred: [OSType],
        nativeSupported: [OSType],
        attributeFormats: [OSType]
    ) -> OSType? {
        candidateFormats(
            preferred: preferred, nativeSupported: nativeSupported, attributeFormats: attributeFormats
        ).first
    }

    static func sourceFormatPriority(for inputFormat: OSType) -> [OSType] {
        [inputFormat] + preferredFallbackFormats
    }

    static func destinationFormatPriority(for sourceFormat: OSType) -> [OSType] {
        [sourceFormat] + preferredFallbackFormats
    }

    static func fourCC(_ format: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: format >> $0) }
        let hex = "0x\(String(format, radix: 16))"
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return hex }
        return String(bytes: bytes, encoding: .ascii) ?? hex
    }

    static func formatsDescription(_ formats: [OSType]) -> String {
        formats.isEmpty ? "unspecified" : formats.map(fourCC).joined(separator: ",")
    }
}

final class VideoToolboxSuperResolutionBackend {
    #if !targetEnvironment(simulator)
    private var contextStorage: AnyObject?
    #endif

    func flush() {
        #if !targetEnvironment(simulator)
        if #available(iOS 26.0, *) { (contextStorage as? VTSRContext)?.flush() }
        #endif
    }

    func tearDown() {
        #if !targetEnvironment(simulator)
        if #available(iOS 26.0, *) { (contextStorage as? VTSRContext)?.tearDown() }
        contextStorage = nil
        #endif
    }

    func upscale(
        pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        maxScale: Float = 2,
        hasTimeRemaining: @Sendable () -> Bool = { true }
    ) async -> VideoEnhancementBackendOutcome {
        #if targetEnvironment(simulator)
        return .bypassed(reason: "Simulator unsupported")
        #else
        guard #available(iOS 26.0, *) else { return .bypassed(reason: "Requires iOS 26") }
        do {
            try VTSRFailure.checkDeadline(hasTimeRemaining)
            guard pts.isNumeric else { throw VTSRFailure("VT SR timestamp invalid") }
            guard maxScale.isFinite, maxScale > 1 else { throw VTSRFailure("VT SR scale cap \(maxScale)x") }
            let output = try await upscaleIOS26(
                pixelBuffer, pts: pts, maxScale: maxScale, hasTimeRemaining: hasTimeRemaining
            )
            return .processed(output)
        } catch {
            flush()
            if Task.isCancelled || !hasTimeRemaining() {
                return .bypassed(reason: VTSRFailure.deadline.reason)
            }
            let reason = (error as? VTSRFailure)?.reason ?? (error as? VideoSuperResolutionPool.Failure)?.reason
                ?? "VT SR buffer preparation failed"
            return .bypassed(reason: reason)
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    @available(iOS 26.0, *)
    private func upscaleIOS26(
        _ input: CVPixelBuffer, pts: CMTime, maxScale: Float, hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        let inputRaster = VTInterpolationRaster(input)
        let context: VTSRContext
        if let current = contextStorage as? VTSRContext, current.raster == inputRaster {
            context = current
        } else {
            (contextStorage as? VTSRContext)?.tearDown()
            context = VTSRContext(raster: inputRaster, maxScale: maxScale)
        }
        contextStorage = context
        context.updateScaleCap(maxScale)
        return try await context.upscale(input, pts: pts, hasTimeRemaining: hasTimeRemaining)
    }
    #endif
}

#if !targetEnvironment(simulator)
@available(iOS 26.0, *)
private final class VTSRContext {
    let raster: VTInterpolationRaster
    private var maxScale: Float
    private var candidates: [VTSRConfiguration]
    private var configurationFailure: String
    private var session: VTSRSession?
    private let pixelConverter = MetalNV12PixelConverter()
    private var nativeRejections: [VTSRConfiguration.Identifier: String] = [:]
    private var nextModelDownloadRequests: [VTSRConfiguration.Identifier: ContinuousClock.Instant] = [:]

    init(raster: VTInterpolationRaster, maxScale: Float) {
        self.raster = raster
        self.maxScale = maxScale
        (candidates, configurationFailure) = VTSRConfiguration.candidates(for: raster, maxScale: maxScale)
    }

    deinit {
        tearDown()
    }

    func updateScaleCap(_ maxScale: Float) {
        guard self.maxScale != maxScale else { return }
        self.maxScale = maxScale
        (candidates, configurationFailure) = VTSRConfiguration.candidates(for: raster, maxScale: maxScale)
        if let session, !candidates.contains(where: { $0.id == session.configuration.id }) {
            self.session = nil
        }
    }

    func flush() {
        session?.flush()
        pixelConverter.flush()
    }

    func tearDown() {
        session = nil
        pixelConverter.tearDown()
    }

    func upscale(
        _ input: CVPixelBuffer, pts: CMTime, hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        var bypassReason = configurationFailure
        var modelBypassReason: String?
        for candidate in orderedCandidates() {
            try VTSRFailure.checkDeadline(hasTimeRemaining)
            if let rejection = nativeRejections[candidate.id] {
                bypassReason = rejection
                continue
            }
            let targetFormat = candidate.source.raster.format
            let isDirect = candidate.source.accepts(input)
            let canStage = VTSRSession.canStage(inputFormat: raster.format, targetFormat: targetFormat)
            guard isDirect || canStage else {
                bypassReason = "VT SR decoded buffer layout unsupported (\(raster.description))"
                continue
            }
            if session?.canReuse(candidate.id, at: pts) != true,
               let reason = legacyModelBypassReason(for: candidate) {
                modelBypassReason = modelBypassReason ?? reason
                continue
            }
            if case .lowLatency = candidate.id {
                triggerBackgroundLegacyDownloadIfNeeded()
            }
            if session?.configuration.id != candidate.id { session = nil }
            let active = session ?? VTSRSession(configuration: candidate)
            session = active
            do {
                return try await active.upscale(
                    input, pts: pts, isDirect: isDirect, pixelConverter: pixelConverter,
                    hasTimeRemaining: hasTimeRemaining
                )
            } catch let failure as VTSRFailure where failure.rejectsConfiguration {
                PlayerLog.log("[VT SR] rejected at runtime id=\(candidate.id.diagnosticLabel) reason=\(failure.reason)")
                session = nil
                nativeRejections[candidate.id] = failure.reason
                bypassReason = failure.reason
            }
        }
        throw VTSRFailure(modelBypassReason ?? bypassReason)
    }

    /// Priority order:
    /// 1. Full ML (`VTSuperResolutionScalerConfiguration`) whose model is already `.ready`
    /// 2. Low-latency ML (`VTLowLatencySuperResolutionScalerConfiguration`, zero download wait)
    /// 3. Full ML needing or performing a background model download
    private func orderedCandidates() -> [VTSRConfiguration] {
        var readyLegacy: [VTSRConfiguration] = []
        var lowLatency: [VTSRConfiguration] = []
        var pendingLegacy: [VTSRConfiguration] = []
        for candidate in candidates {
            if let legacy = candidate.native as? VTSuperResolutionScalerConfiguration {
                if legacy.configurationModelStatus == .ready {
                    readyLegacy.append(candidate)
                } else {
                    pendingLegacy.append(candidate)
                }
            } else {
                lowLatency.append(candidate)
            }
        }
        return readyLegacy + lowLatency + pendingLegacy
    }

    private func triggerBackgroundLegacyDownloadIfNeeded() {
        for candidate in candidates where nativeRejections[candidate.id] == nil {
            guard let legacy = candidate.native as? VTSuperResolutionScalerConfiguration,
                  legacy.configurationModelStatus == .downloadRequired else { continue }
            requestModelDownload(for: candidate.id, configuration: legacy)
            return
        }
    }

    private func requestModelDownload(
        for id: VTSRConfiguration.Identifier, configuration: VTSuperResolutionScalerConfiguration
    ) {
        let now = ContinuousClock.now
        guard nextModelDownloadRequests[id].map({ now >= $0 }) ?? true else { return }
        nextModelDownloadRequests[id] = now.advanced(by: .seconds(30))
        let label = id.diagnosticLabel
        PlayerLog.log("[VT SR] requesting background model download id=\(label)")
        configuration.downloadConfigurationModel { error in
            if let error {
                PlayerLog.log("[VT SR] model download failed id=\(label) error=\(error)")
            } else {
                PlayerLog.log("[VT SR] model download completed id=\(label)")
            }
        }
    }

    private func legacyModelBypassReason(for candidate: VTSRConfiguration) -> String? {
        guard let legacy = candidate.native as? VTSuperResolutionScalerConfiguration else { return nil }
        switch legacy.configurationModelStatus {
        case .ready:
            return nil
        case .downloading:
            return "VT SR legacy model downloading"
        case .downloadRequired:
            requestModelDownload(for: candidate.id, configuration: legacy)
            return "VT SR legacy model download required"
        @unknown default:
            return "VT SR legacy model unavailable"
        }
    }
}

private struct VTSRFailure: Error {
    static let deadline = Self("VT SR deadline")
    let reason: String
    let rejectsConfiguration: Bool

    init(_ reason: String, rejectsConfiguration: Bool = false) {
        self.reason = reason
        self.rejectsConfiguration = rejectsConfiguration
    }

    static func checkDeadline(_ hasTimeRemaining: @Sendable () -> Bool) throws {
        guard !Task.isCancelled, hasTimeRemaining() else { throw deadline }
    }
}

private extension VTInterpolationRaster {
    init(width: Int, height: Int, format: OSType) {
        self.width = width
        self.height = height
        self.format = format
    }
}

@available(iOS 26.0, *)
private struct VTSRConfiguration {
    enum Identifier: Hashable, Sendable {
        case lowLatency(Float)
        case legacyVideo(Int)
        case legacyImage(Int)

        var scale: Float {
            switch self {
            case let .lowLatency(scale): scale
            case let .legacyVideo(scale), let .legacyImage(scale): Float(scale)
            }
        }

        var diagnosticLabel: String {
            switch self {
            case let .lowLatency(scale): "lowLatency(\(scale)x)"
            case let .legacyVideo(scale): "legacyVideo(\(scale)x)"
            case let .legacyImage(scale): "legacyImage(\(scale)x)"
            }
        }
    }

    let id: Identifier
    let native: any VTFrameProcessorConfiguration
    let source: VTInterpolationBufferRequirements
    let destination: VTInterpolationBufferRequirements

    private enum CandidateRejection: String, Error {
        case scaleCap = "VT SR output exceeds scale cap"
        case rasterBudget = "VT SR output exceeds raster budget"
        case raster = "VT SR native raster unsupported"
        case format = "VT SR native format/layout unsupported"
    }

    static func candidates(for raster: VTInterpolationRaster, maxScale: Float) -> ([Self], String) {
        let lowLatency = VTLowLatencySuperResolutionScalerConfiguration.isSupported
        let legacy = VTSuperResolutionScalerConfiguration.isSupported
        guard lowLatency || legacy else { return ([], "VT SR unsupported on this device") }

        let rawLowLatency = lowLatency ? VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
            frameWidth: raster.width, frameHeight: raster.height
        ) : []
        let rawLegacy = legacy ? VTSuperResolutionScalerConfiguration.supportedScaleFactors : []
        let llMin = lowLatency
            ? configurationMinimumDimensions(VTLowLatencySuperResolutionScalerConfiguration.self) : nil
        let llMax = lowLatency
            ? configurationMaximumDimensions(VTLowLatencySuperResolutionScalerConfiguration.self) : nil
        PlayerLog.log(
            "[VT SR] input=\(raster.description) maxScale=\(maxScale)x " +
            "llSupported=\(lowLatency) llDims=\(dimensionsText(llMin))..\(dimensionsText(llMax)) " +
            "rawLowLatency=\(rawLowLatency) legacySupported=\(legacy) rawLegacy=\(rawLegacy)"
        )

        let legacyIDs = Set(rawLegacy.filter { $0 > 1 }).sorted(by: >).flatMap {
            [Identifier.legacyVideo($0), .legacyImage($0)]
        }
        let lowLatencyIDs = Set(rawLowLatency.filter { $0.isFinite && $0 > 1 }).sorted(by: >).map(Identifier.lowLatency)
        let ids = legacyIDs + lowLatencyIDs
        guard !ids.isEmpty else { return ([], "No native VT SR scale (\(raster.description))") }
        let admitted = ids.filter { $0.scale <= maxScale + 0.001 }
        guard !admitted.isEmpty else {
            return ([], "VT SR native scales exceed \(maxScale)x cap (\(raster.description))")
        }

        var rejections: Set<CandidateRejection> = []
        let configurations = admitted.compactMap { id -> Self? in
            do throws(CandidateRejection) {
                return try makeConfiguration(id, raster: raster, maxScale: maxScale)
            } catch {
                rejections.insert(error)
                return nil
            }
        }
        logAcceptedSummary(configurations, raster: raster)
        let rejection = [CandidateRejection.format, .rasterBudget, .raster, .scaleCap].first(where: rejections.contains)
        let failure = "\((rejection ?? .raster).rawValue) (\(raster.description))"
        return (configurations, failure)
    }

    private static func makeConfiguration(
        _ id: Identifier, raster: VTInterpolationRaster, maxScale: Float
    ) throws(CandidateRejection) -> Self {
        let (native, nativeSupported) = try makeNativeConfiguration(id, raster: raster)
        let source = native.sourcePixelBufferAttributes
        let destination = native.destinationPixelBufferAttributes
        let sourceAttrFormats = VTSRNegotiation.attributeFormats(from: source)
        let destAttrFormats = VTSRNegotiation.attributeFormats(from: destination)

        func logRejection(_ detail: String) {
            PlayerLog.log(
                "[VT SR] reject id=\(id.diagnosticLabel) input=\(raster.description) maxScale=\(maxScale)x " +
                "supported=\(VTSRNegotiation.formatsDescription(nativeSupported)) " +
                "srcAttrs=\(VTSRNegotiation.formatsDescription(sourceAttrFormats)) " +
                "dstAttrs=\(VTSRNegotiation.formatsDescription(destAttrFormats)) reason=\(detail)"
            )
        }

        let widthKey = kCVPixelBufferWidthKey as String
        let heightKey = kCVPixelBufferHeightKey as String
        let sourceWidth = (source[widthKey] as? NSNumber)?.intValue ?? raster.width
        let sourceHeight = (source[heightKey] as? NSNumber)?.intValue ?? raster.height
        guard sourceWidth == raster.width, sourceHeight == raster.height else {
            logRejection("source attrs dims \(sourceWidth)x\(sourceHeight) != input")
            throw .raster
        }
        guard let outputSize = VTSRNegotiation.resolveOutputDimensions(
            inputWidth: raster.width, inputHeight: raster.height,
            scale: id.scale, destinationAttributes: destination
        ) else {
            logRejection("dest dims invalid for scale \(id.scale)x")
            throw .raster
        }
        guard VideoSuperResolutionRasterBudget.contains(width: outputSize.width, height: outputSize.height) else {
            logRejection("dest \(outputSize.width)x\(outputSize.height) exceeds raster budget")
            throw .rasterBudget
        }
        guard Double(outputSize.width) <= Double(raster.width) * Double(maxScale) + 2.0,
              Double(outputSize.height) <= Double(raster.height) * Double(maxScale) + 2.0 else {
            logRejection("dest \(outputSize.width)x\(outputSize.height) exceeds maxScale \(maxScale)x")
            throw .scaleCap
        }

        let (inputReq, outputReq) = try resolveBufferRequirements(
            source: source, destination: destination,
            nativeSupported: nativeSupported,
            sourceAttrFormats: sourceAttrFormats, destAttrFormats: destAttrFormats,
            raster: raster, outputSize: outputSize, logRejection: logRejection
        )
        return Self(id: id, native: native, source: inputReq, destination: outputReq)
    }

    private static func makeNativeConfiguration(
        _ id: Identifier, raster: VTInterpolationRaster
    ) throws(CandidateRejection) -> (any VTFrameProcessorConfiguration, [OSType]) {
        switch id {
        case let .lowLatency(scale):
            let config = VTLowLatencySuperResolutionScalerConfiguration(
                frameWidth: raster.width, frameHeight: raster.height, scaleFactor: scale
            )
            return (config, config.supportedPixelFormats)
        case let .legacyVideo(scale), let .legacyImage(scale):
            let inputType: VTSuperResolutionScalerConfiguration.InputType = switch id {
            case .legacyVideo: .video
            default: .image
            }
            guard let config = VTSuperResolutionScalerConfiguration(
                frameWidth: raster.width, frameHeight: raster.height, scaleFactor: scale, inputType: inputType,
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: VTSuperResolutionScalerConfiguration.defaultRevision
            ) else {
                PlayerLog.log(
                    "[VT SR] reject id=\(id.diagnosticLabel) input=\(raster.description) reason=init returned nil"
                )
                throw .raster
            }
            return (config, config.supportedPixelFormats)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func resolveBufferRequirements(
        source: [String: Any],
        destination: [String: Any],
        nativeSupported: [OSType],
        sourceAttrFormats: [OSType],
        destAttrFormats: [OSType],
        raster: VTInterpolationRaster,
        outputSize: (width: Int, height: Int),
        logRejection: (String) -> Void
    ) throws(CandidateRejection) -> (VTInterpolationBufferRequirements, VTInterpolationBufferRequirements) {
        let sourceCandidates = VTSRNegotiation.candidateFormats(
            preferred: VTSRNegotiation.sourceFormatPriority(for: raster.format),
            nativeSupported: nativeSupported,
            attributeFormats: sourceAttrFormats
        )
        var lastSourceStatus: CVReturn = kCVReturnInvalidPixelFormat
        var resolvedSource: VTInterpolationBufferRequirements?
        for format in sourceCandidates {
            let candidateRaster = VTInterpolationRaster(width: raster.width, height: raster.height, format: format)
            let result = VTInterpolationBufferRequirements.resolve(source, for: candidateRaster)
            lastSourceStatus = result.status
            if let requirements = result.requirements {
                resolvedSource = requirements
                break
            }
        }
        guard let inputReq = resolvedSource else {
            let desc = VTSRNegotiation.formatsDescription(sourceCandidates)
            logRejection("no compatible source format (candidates=\(desc) status=\(lastSourceStatus))")
            throw .format
        }

        let destCandidates = VTSRNegotiation.candidateFormats(
            preferred: VTSRNegotiation.destinationFormatPriority(for: inputReq.raster.format),
            nativeSupported: destAttrFormats.isEmpty ? nativeSupported : [],
            attributeFormats: destAttrFormats
        )
        var lastDestStatus: CVReturn = kCVReturnInvalidPixelFormat
        var resolvedDest: VTInterpolationBufferRequirements?
        for format in destCandidates {
            let candidateRaster = VTInterpolationRaster(
                width: outputSize.width, height: outputSize.height, format: format
            )
            let result = VTInterpolationBufferRequirements.resolve(destination, for: candidateRaster)
            lastDestStatus = result.status
            if let requirements = result.requirements {
                resolvedDest = requirements
                break
            }
        }
        guard let outputReq = resolvedDest else {
            let desc = VTSRNegotiation.formatsDescription(destCandidates)
            logRejection("no compatible dest format (candidates=\(desc) status=\(lastDestStatus))")
            throw .format
        }
        return (inputReq, outputReq)
    }

    private static func logAcceptedSummary(_ configurations: [Self], raster: VTInterpolationRaster) {
        guard !configurations.isEmpty else { return }
        let summary = configurations.map { config in
            let modelStatus: String
            if let legacy = config.native as? VTSuperResolutionScalerConfiguration {
                switch legacy.configurationModelStatus {
                case .ready: modelStatus = "ready"
                case .downloading: modelStatus = "downloading"
                case .downloadRequired: modelStatus = "downloadRequired"
                @unknown default: modelStatus = "unknown"
                }
            } else {
                modelStatus = "builtin"
            }
            return "\(config.id.diagnosticLabel)[\(config.source.raster.description)->" +
                "\(config.destination.raster.description) model=\(modelStatus)]"
        }.joined(separator: ", ")
        PlayerLog.log("[VT SR] accepted for \(raster.description): \(summary)")
    }

    private static func configurationMaximumDimensions<T: VTFrameProcessorConfiguration>(
        _ type: T.Type
    ) -> CMVideoDimensions? {
        type.maximumDimensions
    }

    private static func configurationMinimumDimensions<T: VTFrameProcessorConfiguration>(
        _ type: T.Type
    ) -> CMVideoDimensions? {
        type.minimumDimensions
    }

    private static func dimensionsText(_ dimensions: CMVideoDimensions?) -> String {
        guard let dimensions else { return "nil" }
        return "\(dimensions.width)x\(dimensions.height)"
    }
}

@available(iOS 26.0, *)
private final class VTSRSession {
    private struct FramePair {
        let source: VTFrameProcessorFrame
        let output: VTFrameProcessorFrame
    }

    let configuration: VTSRConfiguration
    private var processor: VTFrameProcessor?
    private var lastSubmittedPTS: CMTime?
    private var history: FramePair?
    private var destinationPool: VideoSuperResolutionPool?
    private var stagingPool: VideoSuperResolutionPool?

    init(configuration: VTSRConfiguration) {
        self.configuration = configuration
    }

    deinit { endSession() }

    func flush() {
        history = nil
        lastSubmittedPTS = nil
    }

    func canReuse(_ id: VTSRConfiguration.Identifier, at pts: CMTime) -> Bool {
        configuration.id == id && processor != nil && (lastSubmittedPTS.map { pts > $0 } ?? true)
    }

    static func canStage(inputFormat: OSType, targetFormat: OSType) -> Bool {
        if MetalNV12PixelConverter.isNV12(inputFormat) {
            return MetalNV12PixelConverter.isNV12(targetFormat) || targetFormat == kCVPixelFormatType_32BGRA
        }
        if inputFormat == kCVPixelFormatType_32BGRA {
            return targetFormat == kCVPixelFormatType_32BGRA
        }
        return false
    }

    func upscale(
        _ input: CVPixelBuffer,
        pts: CMTime,
        isDirect: Bool,
        pixelConverter: MetalNV12PixelConverter,
        hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        if let lastSubmittedPTS, pts <= lastSubmittedPTS { endSession() }
        let pair = try await prepareFrames(
            input, pts: pts, isDirect: isDirect, pixelConverter: pixelConverter, hasTimeRemaining: hasTimeRemaining
        )
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        guard let parameters = makeParameters(pair) else { throw VTSRFailure("VT SR parameters invalid") }
        let processor = try startIfNeeded(hasTimeRemaining: hasTimeRemaining)
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        lastSubmittedPTS = pts
        do {
            try await Self.process(processor, parameters: parameters)
        } catch {
            throw handleNativeError(error, operation: "process")
        }
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let output = pair.output.buffer
        let outputColorSpace: ScaledVideoOutputMetadata.OutputColorSpace =
            configuration.destination.raster.format == kCVPixelFormatType_32BGRA ? .rgbConverted : .yuvSameAsSource
        ScaledVideoOutputMetadata.copy(from: input, to: output, colorSpace: outputColorSpace)
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        if case .legacyVideo = configuration.id { history = pair }
        return output
    }

    private func prepareFrames(
        _ input: CVPixelBuffer,
        pts: CMTime,
        isDirect: Bool,
        pixelConverter: MetalNV12PixelConverter,
        hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> FramePair {
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let source = if isDirect {
            input
        } else {
            try await stage(input, pixelConverter: pixelConverter, hasTimeRemaining: hasTimeRemaining)
        }
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let requirements = configuration.destination
        let pool = try destinationPool ?? VideoSuperResolutionPool(
            attributes: requirements.poolAttributes, label: "VT SR destination", followsDisplayLookahead: true,
            isCompatible: requirements.accepts
        )
        destinationPool = pool
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let output = try pool.allocate()
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: pts),
              let outputFrame = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: pts) else {
            throw VTSRFailure("VT SR frame parameters invalid")
        }
        return FramePair(source: sourceFrame, output: outputFrame)
    }

    private func stage(
        _ input: CVPixelBuffer,
        pixelConverter: MetalNV12PixelConverter,
        hasTimeRemaining: @Sendable () -> Bool
    ) async throws -> CVPixelBuffer {
        let requirements = configuration.source
        let inputFormat = CVPixelBufferGetPixelFormatType(input)
        let targetFormat = requirements.raster.format
        let sameNV12 = inputFormat == targetFormat && MetalNV12PixelConverter.isNV12(inputFormat)
        let pool = try stagingPool ?? makeStagingPool(requirements: requirements, needsMetal: !sameNV12)
        stagingPool = pool
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let staged = try pool.allocate()
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        if sameNV12 {
            do {
                try VTNV12StagingCopy.copy(from: input, to: staged)
            } catch {
                throw VTSRFailure("VT SR NV12 staging failed")
            }
            return staged
        }
        let converted = await pixelConverter.convert(from: input, to: staged)
        guard converted else {
            let srcCC = VTSRNegotiation.fourCC(inputFormat)
            let dstCC = VTSRNegotiation.fourCC(targetFormat)
            throw VTSRFailure("VT SR GPU staging failed (\(srcCC)->\(dstCC))")
        }
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        if !VTInterpolationPadding(staged).isEmpty {
            let status = CVPixelBufferFillExtendedPixels(staged)
            guard status == kCVReturnSuccess else {
                throw VTSRFailure("VT SR staging padding failed (\(status))")
            }
        }
        let stagedColorSpace: ScaledVideoOutputMetadata.OutputColorSpace =
            targetFormat == kCVPixelFormatType_32BGRA ? .rgbConverted : .yuvSameAsSource
        ScaledVideoOutputMetadata.copy(from: input, to: staged, colorSpace: stagedColorSpace)
        return staged
    }

    private func makeStagingPool(
        requirements: VTInterpolationBufferRequirements, needsMetal: Bool
    ) throws -> VideoSuperResolutionPool {
        if needsMetal {
            var resolved: CFDictionary?
            let metalAttrs = [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
            let status = CVPixelBufferCreateResolvedAttributesDictionary(
                kCFAllocatorDefault, [requirements.poolAttributes, metalAttrs] as CFArray, &resolved
            )
            if status == kCVReturnSuccess, let resolved,
               let pool = try? VideoSuperResolutionPool(
                attributes: resolved, label: "VT SR staging", limit: 6, isCompatible: requirements.accepts
               ) {
                return pool
            }
        }
        return try VideoSuperResolutionPool(
            attributes: requirements.poolAttributes, label: "VT SR staging", limit: 6,
            isCompatible: requirements.accepts
        )
    }

    private func makeParameters(_ pair: FramePair) -> (any VTFrameProcessorParameters)? {
        if case .lowLatency = configuration.id {
            return VTLowLatencySuperResolutionScalerParameters(sourceFrame: pair.source, destinationFrame: pair.output)
        }
        let previous = history.flatMap { reference in
            reference.source.presentationTimeStamp < pair.source.presentationTimeStamp
                && VideoFramePairFormat.matches(reference.source.buffer, pair.source.buffer) ? reference : nil
        }
        return VTSuperResolutionScalerParameters(
            sourceFrame: pair.source, previousFrame: previous?.source, previousOutputFrame: previous?.output,
            opticalFlow: nil, submissionMode: previous == nil ? .random : .sequential, destinationFrame: pair.output
        )
    }

    private func startIfNeeded(hasTimeRemaining: @Sendable () -> Bool) throws -> VTFrameProcessor {
        if let processor { return processor }
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        let newProcessor = VTFrameProcessor()
        try VTSRFailure.checkDeadline(hasTimeRemaining)
        do {
            try newProcessor.startSession(configuration: configuration.native)
        } catch {
            throw handleNativeError(error, operation: "start")
        }
        processor = newProcessor
        return newProcessor
    }

    private func endSession() {
        processor?.endSession()
        processor = nil
        lastSubmittedPTS = nil
        flush()
    }

    private func handleNativeError(_ error: Error, operation: String) -> VTSRFailure {
        let nsError = error as NSError
        let code = nsError.domain == VTFrameProcessorError.errorDomain
            ? VTFrameProcessorError.Code(rawValue: nsError.code) : nil
        switch code {
        case .unsupportedResolution, .revisionNotSupported:
            endSession()
            return VTSRFailure("VT SR native configuration rejected (\(nsError.code))", rejectsConfiguration: true)
        case .fatalError, .sessionLevelError, .sessionNotStarted, .invalidFrameTiming, .assetDownloadFailed:
            endSession()
        default:
            flush()
        }
        return VTSRFailure("VT SR \(operation) failed (\(nsError.code))")
    }

    private static func process(
        _ processor: VTFrameProcessor, parameters: any VTFrameProcessorParameters
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
#endif
