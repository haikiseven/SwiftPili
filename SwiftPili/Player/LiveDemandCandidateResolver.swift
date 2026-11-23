import Foundation

enum LiveDemandHostClass: String, Sendable, Equatable {
    case bilibili
    case knownCDN = "known-cdn"
    case other
    case missing
}

enum LiveDemandCandidateRejectionReason: String, Sendable, Equatable {
    case missingURLInfo = "missing-url-info"
    case malformedURL = "malformed-url"
    case unsupportedProtocol = "unsupported-protocol"
    case unsupportedFormat = "unsupported-format"
    case unsupportedCodec = "unsupported-codec"
    case unsupportedDeviceCodec = "unsupported-device-codec"
    case unsupportedPlaylistShape = "unsupported-playlist-shape"
    case qualityUnavailable = "quality-unavailable"
}

enum LiveDemandSelectionFailureKind: String, Sendable, Equatable, CaseIterable {
    case noCompatibleCandidate = "no-compatible-candidate"
    case unsupportedContainer = "unsupported-container"
    case unsupportedCodec = "unsupported-codec"
    case unsupportedDeviceCodec = "unsupported-device-codec"
    case unsupportedQuality = "unsupported-quality"

    var isRetryable: Bool {
        switch self {
        case .noCompatibleCandidate:
            true
        case .unsupportedContainer, .unsupportedCodec,
             .unsupportedDeviceCodec, .unsupportedQuality:
            false
        }
    }
}

extension LiveDemandCandidateRejectionReason {
    var admission: (stage: Int, kind: LiveDemandSelectionFailureKind) {
        switch self {
        case .missingURLInfo, .malformedURL:
            (0, .noCompatibleCandidate)
        case .unsupportedProtocol:
            (1, .unsupportedContainer)
        case .unsupportedFormat, .unsupportedPlaylistShape:
            (2, .unsupportedContainer)
        case .unsupportedCodec:
            (3, .unsupportedCodec)
        case .unsupportedDeviceCodec:
            (4, .unsupportedDeviceCodec)
        case .qualityUnavailable:
            (5, .unsupportedQuality)
        }
    }
}

struct LiveDemandCandidateMetadata: Sendable, Equatable {
    let protocolName: String
    let formatName: String
    let codecName: String
    let currentQn: Int?
    let acceptQn: [Int]
    let hostClass: LiveDemandHostClass
    let rejectionReason: LiveDemandCandidateRejectionReason?

    var tupleFamily: String {
        "\(protocolName)/\(formatName)/\(codecName)"
    }

    var sanitizedSummary: String {
        let current = currentQn.map(String.init) ?? "-"
        let accepted: String
        if acceptQn.isEmpty {
            accepted = "-"
        } else {
            let visible = acceptQn.prefix(8).map(String.init).joined(separator: ",")
            accepted = acceptQn.count > 8 ? "\(visible),+\(acceptQn.count - 8)" : visible
        }
        let reason = rejectionReason.map { " reason=\($0.rawValue)" } ?? ""
        return "\(tupleFamily) currentQn=\(current) acceptQn=\(accepted) " +
            "hostClass=\(hostClass.rawValue)\(reason)"
    }
}

struct LiveDemandInputShapeSummary: Sendable, Equatable {
    let sanitizedSummary: String
}

struct LiveDemandDeviceCapabilities: Sendable, Equatable {
    let supportsHLSFMP4: Bool
    let supportsProgressiveFMP4: Bool
    let supportsLibavformatLive: Bool
    let supportsAVC: Bool
    let supportsHEVC: Bool
    let supportsAV1: Bool
}

struct LiveDemandResolvedTuple: Sendable, Equatable {
    let url: URL
    let metadata: LiveDemandCandidateMetadata
    let actualQn: Int
    let liveSourceKind: DemandLiveSourceKind?
    let hlsTSBackupPlaylistURL: URL?
    let backupURLs: [URL]

    init(
        url: URL,
        metadata: LiveDemandCandidateMetadata,
        actualQn: Int,
        liveSourceKind: DemandLiveSourceKind?,
        hlsTSBackupPlaylistURL: URL?,
        backupURLs: [URL] = []
    ) {
        self.url = url
        self.metadata = metadata
        self.actualQn = actualQn
        self.liveSourceKind = liveSourceKind
        self.hlsTSBackupPlaylistURL = hlsTSBackupPlaylistURL
        self.backupURLs = backupURLs
    }

    func demandSource(for ownerLease: PlayerOwnerLease?) -> DemandLiveSource? {
        liveSourceKind.map {
            DemandLiveSource(kind: $0, ownerLease: ownerLease, hlsTSBackupPlaylistURL: hlsTSBackupPlaylistURL)
        }
    }

    var codecFourCC: String {
        switch metadata.codecName {
        case "avc": "avc1"
        case "hevc": "hvc1"
        case "av1": "av01"
        default: metadata.codecName
        }
    }
}

struct LiveDemandSelectionDiagnostics: Sendable, Equatable {
    let requestedQn: Int
    let availableFamilies: [String]
    let rejectionReasons: [LiveDemandCandidateRejectionReason]

    init(
        requestedQn: Int,
        availableFamilies: [String] = [],
        rejectionReasons: [LiveDemandCandidateRejectionReason] = []
    ) {
        self.requestedQn = requestedQn
        self.availableFamilies = availableFamilies
        self.rejectionReasons = rejectionReasons
    }
}

enum LiveStreamSelectionError: Error, LocalizedError, Sendable, Equatable {
    case noCompatibleCandidate(LiveDemandSelectionDiagnostics)
    case unsupportedContainer(
        containers: [String],
        diagnostics: LiveDemandSelectionDiagnostics
    )
    case unsupportedCodec(
        codecs: [String],
        diagnostics: LiveDemandSelectionDiagnostics
    )
    case unsupportedDeviceCodec(
        codecs: [String],
        diagnostics: LiveDemandSelectionDiagnostics
    )
    case unsupportedQuality(
        offeredQualities: [Int],
        diagnostics: LiveDemandSelectionDiagnostics
    )

    var classification: LiveDemandSelectionFailureKind {
        switch self {
        case .noCompatibleCandidate: .noCompatibleCandidate
        case .unsupportedContainer: .unsupportedContainer
        case .unsupportedCodec: .unsupportedCodec
        case .unsupportedDeviceCodec: .unsupportedDeviceCodec
        case .unsupportedQuality: .unsupportedQuality
        }
    }

    var diagnostics: LiveDemandSelectionDiagnostics {
        switch self {
        case .noCompatibleCandidate(let diagnostics): diagnostics
        case .unsupportedContainer(_, let diagnostics): diagnostics
        case .unsupportedCodec(_, let diagnostics): diagnostics
        case .unsupportedDeviceCodec(_, let diagnostics): diagnostics
        case .unsupportedQuality(_, let diagnostics): diagnostics
        }
    }

    var requestedQn: Int { diagnostics.requestedQn }

    var rejectionReasons: [LiveDemandCandidateRejectionReason] {
        diagnostics.rejectionReasons
    }

    var isRetryable: Bool { classification.isRetryable }

    var errorDescription: String? {
        switch self {
        case .noCompatibleCandidate:
            return String(localized: "This live room is not offering a stream this player can open.")
        case .unsupportedContainer(let containers, _):
            return String(
                format: String(localized: "This live room streams only %@, which this player cannot open."),
                Self.displayList(containers)
            )
        case .unsupportedCodec(let codecs, _):
            return String(
                format: String(localized: "This live room's video codec (%@) is not supported."),
                Self.displayList(codecs)
            )
        case .unsupportedDeviceCodec(let codecs, _):
            return String(
                format: String(localized: "This device cannot decode this live room's video (%@)."),
                Self.displayList(codecs)
            )
        case .unsupportedQuality(_, let diagnostics):
            return String(
                format: String(localized: "No stream this player can open offers %@."),
                Self.qualityLabel(diagnostics.requestedQn)
            )
        }
    }

    var rejectionReasonSummary: String {
        let reasons = diagnostics.rejectionReasons
        return reasons.isEmpty
            ? classification.rawValue
            : reasons.map(\.rawValue).joined(separator: ",")
    }

    var availableFamiliesForLogging: String {
        let families = diagnostics.availableFamilies
        return families.isEmpty ? "none" : families.joined(separator: ",")
    }

    var blockingLabelsForLogging: String {
        switch self {
        case .noCompatibleCandidate:
            "none"
        case .unsupportedContainer(let containers, _):
            containers.isEmpty ? "none" : containers.joined(separator: ",")
        case .unsupportedCodec(let codecs, _), .unsupportedDeviceCodec(let codecs, _):
            codecs.isEmpty ? "none" : codecs.joined(separator: ",")
        case .unsupportedQuality(let qualities, _):
            qualities.isEmpty ? "none" : qualities.map(String.init).joined(separator: ",")
        }
    }

    private static func displayList(_ labels: [String]) -> String {
        let visible = labels.prefix(4).map { $0.uppercased() }
        return visible.isEmpty ? "-" : visible.joined(separator: ", ")
    }

    private static func qualityLabel(_ qn: Int) -> String {
        LiveQualityDescription.fallbackText(for: qn)
            ?? String(format: String(localized: "quality %lld"), qn)
    }
}

struct LiveDemandQualityFallback: Sendable, Equatable {
    let requestedQn: Int
    let actualQn: Int
}

struct LiveDemandSelection: Sendable, Equatable {
    let requestedQn: Int
    let inputShape: LiveDemandInputShapeSummary
    let candidates: [LiveDemandCandidateMetadata]
    let selected: LiveDemandResolvedTuple?
    let failure: LiveStreamSelectionError?

    var candidateCount: Int { candidates.count }

    var qualityFallback: LiveDemandQualityFallback? {
        guard let selected, selected.actualQn != requestedQn else { return nil }
        return LiveDemandQualityFallback(
            requestedQn: requestedQn,
            actualQn: selected.actualQn
        )
    }
}

enum LiveEngineHandoffReason: String, Sendable, Equatable, CaseIterable {
    case container
    case codec
    case deviceCodec = "device-codec"
    case qualityPreservation = "quality-preservation"
    case noCandidate = "no-candidate"
}

enum LiveEngineRoute: Sendable, Equatable {
    case demand(LiveDemandResolvedTuple)
    case libVLC(LiveDemandResolvedTuple, reason: LiveEngineHandoffReason)
    case refused(LiveStreamSelectionError)
}

enum LiveEngineRoutePolicy {
    static func route(
        demand: LiveDemandSelection,
        native: LiveDemandSelection,
        pinsPreferredEngine: Bool
    ) -> LiveEngineRoute {
        if pinsPreferredEngine {
            guard let selected = demand.selected else {
                return .refused(demand.failure ?? .noCompatibleCandidate(
                    LiveDemandSelectionDiagnostics(requestedQn: demand.requestedQn)
                ))
            }
            return .demand(selected)
        }

        if let selected = demand.selected,
           selected.actualQn >= (native.selected?.actualQn ?? 0) {
            return .demand(selected)
        }
        if let selected = native.selected {
            return .libVLC(selected, reason: handoffReason(demand: demand))
        }

        return .refused(native.failure ?? demand.failure ?? .noCompatibleCandidate(
            LiveDemandSelectionDiagnostics(requestedQn: native.requestedQn)
        ))
    }

    private static func handoffReason(demand: LiveDemandSelection) -> LiveEngineHandoffReason {
        guard let failure = demand.failure else {
            return .qualityPreservation
        }
        switch failure.classification {
        case .noCompatibleCandidate: return .noCandidate
        case .unsupportedContainer: return .container
        case .unsupportedCodec: return .codec
        case .unsupportedDeviceCodec: return .deviceCodec
        case .unsupportedQuality: return .qualityPreservation
        }
    }
}

enum LiveDemandCandidateResolver {
    private struct Candidate {
        let metadata: LiveDemandCandidateMetadata
        let url: URL?
        let sourceOrder: Int
        let codecRowStartOrder: Int
        let tupleRank: Int
        var actualQn: Int?
        var isExactQn = false
        var liveSourceKind: DemandLiveSourceKind?
    }

    private struct QualityMatch {
        let actualQn: Int
        let isExact: Bool
    }

    private static let protocolOrder = ["http_hls", "http_stream"]
    private static let formatOrder = ["fmp4", "ts", "flv"]
    private static let codecOrder = ["avc", "hevc", "av1"]
    private static let maxShapeStreams = 8
    private static let maxShapeFormatsPerStream = 8
    private static let maxShapeCodecTuples = 16
    private static let maxShapeAcceptQn = 8
    private static let maxShapeHostClasses = 8
    private static let maxFailureLabels = 8

    private typealias ShapeCodec = LivePlayInfo.PlayurlInfo.Playurl.StreamInfo.FormatInfo.CodecInfo

    private enum EngineAdmission {
        case demand(LiveDemandDeviceCapabilities)
        case native
    }

    static func select(
        info: LivePlayInfo,
        requestedQn: Int,
        capabilities: LiveDemandDeviceCapabilities
    ) -> LiveDemandSelection {
        resolve(info: info, requestedQn: requestedQn, admission: .demand(capabilities))
    }

    static func selectNative(
        info: LivePlayInfo,
        requestedQn: Int
    ) -> LiveDemandSelection {
        resolve(info: info, requestedQn: requestedQn, admission: .native)
    }

    private static func resolve(
        info: LivePlayInfo,
        requestedQn: Int,
        admission: EngineAdmission
    ) -> LiveDemandSelection {
        let inputShape = inputShapeSummary(for: info)
        let rawCandidates = applyAdmission(
            enumerate(info: info),
            admission: admission
        )
        guard !rawCandidates.isEmpty else {
            return LiveDemandSelection(
                requestedQn: requestedQn,
                inputShape: inputShape,
                candidates: [],
                selected: nil,
                failure: .noCompatibleCandidate(
                    LiveDemandSelectionDiagnostics(requestedQn: requestedQn)
                )
            )
        }

        var evaluated = rawCandidates
        for index in evaluated.indices {
            guard evaluated[index].metadata.rejectionReason == nil else { continue }
            guard let quality = qualityMatch(
                currentQn: evaluated[index].metadata.currentQn,
                acceptQn: evaluated[index].metadata.acceptQn,
                requestedQn: requestedQn
            ) else {
                evaluated[index] = withRejection(
                    evaluated[index],
                    reason: .qualityUnavailable
                )
                continue
            }
            evaluated[index].actualQn = quality.actualQn
            evaluated[index].isExactQn = quality.isExact
        }

        let admitted = evaluated.filter {
            $0.metadata.rejectionReason == nil && $0.url != nil && $0.actualQn != nil
        }
        guard let selected = choose(from: admitted) else {
            let failure = classifiedFailure(requestedQn: requestedQn, from: evaluated)
            return LiveDemandSelection(
                requestedQn: requestedQn,
                inputShape: inputShape,
                candidates: evaluated.map(\.metadata),
                selected: nil,
                failure: failure
            )
        }

        let selectedTuple = LiveDemandResolvedTuple(
            url: selected.url!,
            metadata: selected.metadata,
            actualQn: selected.actualQn!,
            liveSourceKind: selected.liveSourceKind,
            hlsTSBackupPlaylistURL: backupPlaylistURL(for: selected, among: admitted),
            backupURLs: backupURLs(for: selected, among: admitted)
        )
        return LiveDemandSelection(
            requestedQn: requestedQn,
            inputShape: inputShape,
            candidates: evaluated.map(\.metadata),
            selected: selectedTuple,
            failure: nil
        )
    }

    private static func backupURLs(for selected: Candidate, among admitted: [Candidate]) -> [URL] {
        guard let selectedURL = selected.url else { return [] }
        let selectedHost = playlistHost(selectedURL)
        let siblings = admitted
            .filter { candidate in
                candidate.codecRowStartOrder == selected.codecRowStartOrder
                    && candidate.actualQn == selected.actualQn
                    && candidate.sourceOrder != selected.sourceOrder
            }
            .sorted { $0.sourceOrder < $1.sourceOrder }
        var seenURLs: Set<URL> = [selectedURL]
        var distinctHostURLs: [URL] = []
        var sameHostURLs: [URL] = []
        for candidate in siblings {
            guard let url = candidate.url,
                  DemandLiveHTTPTransport.isHTTPURL(url),
                  seenURLs.insert(url).inserted else { continue }
            if let selectedHost, let candidateHost = playlistHost(url), candidateHost != selectedHost {
                distinctHostURLs.append(url)
            } else {
                sameHostURLs.append(url)
            }
        }
        return distinctHostURLs + sameHostURLs
    }

    private static func backupPlaylistURL(for selected: Candidate, among admitted: [Candidate]) -> URL? {
        guard selected.liveSourceKind == .hlsMPEGTS, let host = playlistHost(selected.url) else { return nil }
        return admitted.first { candidate in
            guard candidate.codecRowStartOrder == selected.codecRowStartOrder,
                  candidate.actualQn == selected.actualQn,
                  let otherHost = playlistHost(candidate.url) else { return false }
            return otherHost != host
        }?.url
    }

    private static func playlistHost(_ url: URL?) -> String? {
        guard let url, DemandLiveHTTPTransport.isHTTPURL(url) else { return nil }
        return url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func inputShapeSummary(for info: LivePlayInfo) -> LiveDemandInputShapeSummary {
        var fields = [
            "playurlInfo=\(info.playurlInfo == nil ? "nil" : "present")",
        ]

        guard let playurlInfo = info.playurlInfo else {
            fields.append(contentsOf: [
                "playurl=missing",
                "stream=missing",
                "streamCount=0",
                "streams=[]",
                "codecShapes=[]",
            ])
            return LiveDemandInputShapeSummary(sanitizedSummary: fields.joined(separator: " "))
        }

        guard let playurl = playurlInfo.playurl else {
            fields.append(contentsOf: [
                "playurl=nil",
                "stream=missing",
                "streamCount=0",
                "streams=[]",
                "codecShapes=[]",
            ])
            return LiveDemandInputShapeSummary(sanitizedSummary: fields.joined(separator: " "))
        }

        guard let streams = playurl.stream else {
            fields.append(contentsOf: [
                "playurl=present",
                "stream=nil",
                "streamCount=0",
                "streams=[]",
                "codecShapes=[]",
            ])
            return LiveDemandInputShapeSummary(sanitizedSummary: fields.joined(separator: " "))
        }

        fields.append("playurl=present")
        fields.append("stream=\(streams.isEmpty ? "empty" : "count=\(streams.count)")")
        fields.append("streamCount=\(streams.count)")

        guard !streams.isEmpty else {
            fields.append(contentsOf: ["streams=[]", "codecShapes=[]"])
            return LiveDemandInputShapeSummary(sanitizedSummary: fields.joined(separator: " "))
        }

        let sortedStreams = streams.enumerated().sorted { left, right in
            let leftRank = rank(left.element.protocolName, in: protocolOrder)
            let rightRank = rank(right.element.protocolName, in: protocolOrder)
            return leftRank == rightRank
                ? left.offset < right.offset
                : leftRank < rightRank
        }
        let visibleStreams = Array(sortedStreams.prefix(maxShapeStreams))
        var streamSummaries: [String] = []
        var codecSummaries: [String] = []

        for (_, stream) in visibleStreams {
            let sortedFormats = stream.format.enumerated().sorted { left, right in
                let leftRank = rank(left.element.formatName, in: formatOrder)
                let rightRank = rank(right.element.formatName, in: formatOrder)
                return leftRank == rightRank
                    ? left.offset < right.offset
                    : leftRank < rightRank
            }
            let visibleFormats = Array(sortedFormats.prefix(maxShapeFormatsPerStream))
            let formatSummaries = visibleFormats.map { (_, format) in
                "format=\(normalizedFormat(format.formatName)) codecCount=\(format.codec.count)"
            }
            let formatList = boundedList(
                formatSummaries,
                totalCount: stream.format.count,
                limit: maxShapeFormatsPerStream
            )
            streamSummaries.append(
                "protocol=\(normalizedProtocol(stream.protocolName)) " +
                    "formatCount=\(stream.format.count) formats=\(formatList)"
            )

            codecTupleLoop: for (_, format) in visibleFormats {
                let sortedCodecs = format.codec.enumerated().sorted { left, right in
                    let leftRank = rank(left.element.codecName, in: codecOrder)
                    let rightRank = rank(right.element.codecName, in: codecOrder)
                    return leftRank == rightRank
                        ? left.offset < right.offset
                        : leftRank < rightRank
                }
                for (_, codec) in sortedCodecs {
                    guard codecSummaries.count < maxShapeCodecTuples else {
                        break codecTupleLoop
                    }
                    codecSummaries.append(shapeCodec(
                        protocolName: normalizedProtocol(stream.protocolName),
                        formatName: normalizedFormat(format.formatName),
                        codec: codec
                    ))
                }
            }
        }

        let streamList = boundedList(
            streamSummaries,
            totalCount: streams.count,
            limit: maxShapeStreams
        )
        let totalCodecCount = streams.reduce(0) { total, stream in
            total + stream.format.reduce(0) { formatTotal, format in
                formatTotal + format.codec.count
            }
        }
        let codecList = boundedList(
            codecSummaries,
            totalCount: totalCodecCount,
            limit: maxShapeCodecTuples
        )
        fields.append("streams=\(streamList)")
        fields.append("codecShapes=\(codecList)")
        return LiveDemandInputShapeSummary(sanitizedSummary: fields.joined(separator: " "))
    }

    private static func shapeCodec(
        protocolName: String,
        formatName: String,
        codec: ShapeCodec
    ) -> String {
        let base = baseURLShape(codec.baseUrl)
        let hostClasses: [LiveDemandHostClass]
        let urlInfoState: String
        switch codec.urlInfo {
        case nil:
            urlInfoState = "nil"
            hostClasses = base.absoluteHostClass.map { [$0] } ?? [.missing]
        case let .some(urlInfos) where urlInfos.isEmpty:
            urlInfoState = "empty"
            hostClasses = base.absoluteHostClass.map { [$0] } ?? [.missing]
        case let .some(urlInfos):
            urlInfoState = "count=\(urlInfos.count)"
            var classes = Set<LiveDemandHostClass>()
            for urlInfo in urlInfos.prefix(maxShapeHostClasses) {
                let parsedHost = URL(string: urlInfo.host)?.host ?? urlInfo.host
                classes.insert(hostClass(for: parsedHost))
            }
            hostClasses = classes.isEmpty ? [.missing] : classes.sorted { $0.rawValue < $1.rawValue }
        }

        let currentQn = normalizedCurrentQn(codec.currentQn).map(String.init) ?? "-"
        return "protocol=\(protocolName) format=\(formatName) " +
            "codec=\(normalizedCodec(codec.codecName)) currentQn=\(currentQn) " +
            "acceptQn=\(shapeAcceptQn(codec.acceptQn)) " +
            "urlInfo=\(urlInfoState) baseURLShape=\(base.shape) " +
            "pathExtension=\(base.pathExtension) hostClass=\(shapeHostClasses(hostClasses))"
    }

    private static func shapeAcceptQn(_ values: [Int]?) -> String {
        guard let values else { return "nil" }
        let normalized = normalizedQn(values)
        guard !normalized.isEmpty else { return "empty" }
        let visible = normalized.prefix(maxShapeAcceptQn).map(String.init).joined(separator: ",")
        let omitted = normalized.count - min(normalized.count, maxShapeAcceptQn)
        return omitted > 0 ? "\(visible),+\(omitted)" : visible
    }

    private static func baseURLShape(_ rawURL: String) -> (
        shape: String,
        pathExtension: String,
        absoluteHostClass: LiveDemandHostClass?
    ) {
        let trimmed = String(rawURL.prefix(512))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("empty", "-", nil)
        }

        let parsed = URL(string: trimmed)
        let pathExtension = if let extensionName = parsed?.pathExtension, !extensionName.isEmpty {
            safeLabel(extensionName)
        } else {
            "-"
        }
        guard let parsed, parsed.scheme != nil, let host = parsed.host, !host.isEmpty else {
            return ("relative", pathExtension, nil)
        }
        return ("absolute", pathExtension, hostClass(for: host))
    }

    private static func shapeHostClasses(_ classes: [LiveDemandHostClass]) -> String {
        let unique = Array(Set(classes)).sorted { $0.rawValue < $1.rawValue }
        let visible = unique.prefix(maxShapeHostClasses).map(\.rawValue).joined(separator: ",")
        let omitted = unique.count - min(unique.count, maxShapeHostClasses)
        let suffix = omitted > 0 ? ",+\(omitted)" : ""
        return "[\(visible)\(suffix)]"
    }

    private static func boundedList(
        _ values: [String],
        totalCount: Int,
        limit: Int
    ) -> String {
        let visible = values.prefix(limit).joined(separator: "|")
        let omitted = max(0, totalCount - values.prefix(limit).count)
        let suffix = omitted > 0 ? "\(visible.isEmpty ? "" : "|")+\(omitted)" : ""
        return "[\(visible)\(suffix)]"
    }

    private static func enumerate(info: LivePlayInfo) -> [Candidate] {
        guard let streams = info.playurlInfo?.playurl?.stream else { return [] }

        var result: [Candidate] = []
        var sourceOrder = 0
        for (_, stream) in streams.enumerated().sorted(by: { lhs, rhs in
            let left = rank(lhs.element.protocolName, in: protocolOrder)
            let right = rank(rhs.element.protocolName, in: protocolOrder)
            return left == right ? lhs.offset < rhs.offset : left < right
        }) {
            for (_, format) in stream.format.enumerated().sorted(by: { lhs, rhs in
                let left = rank(lhs.element.formatName, in: formatOrder)
                let right = rank(rhs.element.formatName, in: formatOrder)
                return left == right ? lhs.offset < rhs.offset : left < right
            }) {
                for (_, codec) in format.codec.enumerated().sorted(by: { lhs, rhs in
                    let left = rank(lhs.element.codecName, in: codecOrder)
                    let right = rank(rhs.element.codecName, in: codecOrder)
                    return left == right ? lhs.offset < rhs.offset : left < right
                }) {
                    let protocolName = normalizedProtocol(stream.protocolName)
                    let formatName = normalizedFormat(format.formatName)
                    let codecName = normalizedCodec(codec.codecName)
                    let acceptQn = normalizedQn(codec.acceptQn ?? [])
                    let codecRowStartOrder = sourceOrder
                    let baseMetadata = LiveDemandCandidateMetadata(
                        protocolName: protocolName,
                        formatName: formatName,
                        codecName: codecName,
                        currentQn: normalizedCurrentQn(codec.currentQn),
                        acceptQn: acceptQn,
                        hostClass: .missing,
                        rejectionReason: nil
                    )

                    guard let urlInfos = codec.urlInfo, !urlInfos.isEmpty else {
                        let rawURL = codec.baseUrl
                        let parsedURL = URL(string: rawURL)
                        let urlReason: LiveDemandCandidateRejectionReason?
                        if rawURL.isEmpty {
                            urlReason = .missingURLInfo
                        } else {
                            urlReason = endpointReason(
                                rawURL: rawURL,
                                parsedURL: parsedURL
                            )
                        }
                        result.append(Candidate(
                            metadata: LiveDemandCandidateMetadata(
                                protocolName: protocolName,
                                formatName: formatName,
                                codecName: codecName,
                                currentQn: baseMetadata.currentQn,
                                acceptQn: acceptQn,
                                hostClass: hostClass(for: parsedURL?.host ?? ""),
                                rejectionReason: urlReason
                            ),
                            url: parsedURL,
                            sourceOrder: sourceOrder,
                            codecRowStartOrder: codecRowStartOrder,
                            tupleRank: tupleRank(
                                protocolName: protocolName,
                                formatName: formatName,
                                codecName: codecName
                            ),
                            actualQn: nil
                        ))
                        sourceOrder += 1
                        continue
                    }

                    for urlInfo in urlInfos {
                        let rawURL = urlInfo.host + codec.baseUrl + urlInfo.extra
                        let parsedURL = URL(string: rawURL)
                        let hostClass = hostClass(for: parsedURL?.host ?? urlInfo.host)
                        let urlReason = endpointReason(rawURL: rawURL, parsedURL: parsedURL)
                        result.append(Candidate(
                            metadata: LiveDemandCandidateMetadata(
                                protocolName: protocolName,
                                formatName: formatName,
                                codecName: codecName,
                                currentQn: baseMetadata.currentQn,
                                acceptQn: acceptQn,
                                hostClass: hostClass,
                                rejectionReason: urlReason
                            ),
                            url: parsedURL,
                            sourceOrder: sourceOrder,
                            codecRowStartOrder: codecRowStartOrder,
                            tupleRank: tupleRank(
                                protocolName: protocolName,
                                formatName: formatName,
                                codecName: codecName
                            ),
                            actualQn: nil
                        ))
                        sourceOrder += 1
                    }
                }
            }
        }
        return result
    }

    private static func applyAdmission(
        _ candidates: [Candidate],
        admission: EngineAdmission
    ) -> [Candidate] {
        candidates.map { candidate in
            guard candidate.metadata.rejectionReason == nil else { return candidate }
            guard let url = candidate.url else {
                return withRejection(candidate, reason: .malformedURL)
            }
            guard case .demand(let capabilities) = admission else {
                return candidate
            }
            let kind: DemandLiveSourceKind
            switch (candidate.metadata.protocolName, candidate.metadata.formatName) {
            case ("http_hls", "fmp4"): kind = .hlsFMP4
            case ("http_stream", "fmp4"): kind = .progressiveFMP4
            case ("http_hls", "ts"): kind = .hlsMPEGTS
            case ("http_stream", "flv"): kind = .httpFLV
            case ("http_hls", _), ("http_stream", _):
                return withRejection(candidate, reason: .unsupportedFormat)
            default:
                return withRejection(candidate, reason: .unsupportedProtocol)
            }
            if let reason = capabilityReason(
                kind, codecName: candidate.metadata.codecName, url: url, capabilities: capabilities
            ) {
                return withRejection(candidate, reason: reason)
            }
            var admitted = candidate
            admitted.liveSourceKind = kind
            return admitted
        }
    }

    private static func withRejection(
        _ candidate: Candidate,
        reason: LiveDemandCandidateRejectionReason
    ) -> Candidate {
        Candidate(
            metadata: LiveDemandCandidateMetadata(
                protocolName: candidate.metadata.protocolName,
                formatName: candidate.metadata.formatName,
                codecName: candidate.metadata.codecName,
                currentQn: candidate.metadata.currentQn,
                acceptQn: candidate.metadata.acceptQn,
                hostClass: candidate.metadata.hostClass,
                rejectionReason: reason
            ),
            url: candidate.url,
            sourceOrder: candidate.sourceOrder,
            codecRowStartOrder: candidate.codecRowStartOrder,
            tupleRank: candidate.tupleRank,
            actualQn: candidate.actualQn,
            isExactQn: candidate.isExactQn
        )
    }

    private static func choose(from candidates: [Candidate]) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        let exact = candidates.filter(\.isExactQn)
        let pool = exact.isEmpty ? candidates : exact
        return pool.sorted { left, right in
            if exact.isEmpty, left.actualQn != right.actualQn {
                return (left.actualQn ?? 0) > (right.actualQn ?? 0)
            }
            if let leftKind = left.liveSourceKind, let rightKind = right.liveSourceKind,
               let leftRank = demandFormatOrder.firstIndex(of: leftKind),
               let rightRank = demandFormatOrder.firstIndex(of: rightKind), leftRank != rightRank {
                return leftRank < rightRank
            }
            if left.tupleRank != right.tupleRank {
                return left.tupleRank < right.tupleRank
            }
            return left.sourceOrder < right.sourceOrder
        }.first
    }

    private static func qualityMatch(
        currentQn: Int?,
        acceptQn: [Int],
        requestedQn: Int
    ) -> QualityMatch? {
        let requested = max(0, requestedQn)
        let accepted = Set(acceptQn.filter { $0 > 0 })
        let current = currentQn.flatMap { $0 > 0 ? $0 : nil }

        if accepted.contains(requested) {
            return QualityMatch(actualQn: requested, isExact: true)
        }
        if let current {
            if current == requested {
                guard accepted.isEmpty || accepted.contains(current) else { return nil }
                return QualityMatch(actualQn: current, isExact: true)
            }
            if current < requested, accepted.isEmpty || accepted.contains(current) {
                return QualityMatch(actualQn: current, isExact: false)
            }
        }

        if let lower = accepted.filter({ $0 < requested }).max() {
            return QualityMatch(actualQn: lower, isExact: false)
        }
        if let higher = accepted.filter({ $0 > requested }).min() {
            return QualityMatch(actualQn: higher, isExact: false)
        }
        if let current, current > requested, accepted.isEmpty {
            return QualityMatch(actualQn: current, isExact: false)
        }
        if current == nil, accepted.isEmpty, requested > 0 {
            return QualityMatch(actualQn: requested, isExact: true)
        }
        return nil
    }

    private static let demandFormatOrder: [DemandLiveSourceKind] = [
        .hlsFMP4, .progressiveFMP4, .httpFLV, .hlsMPEGTS,
    ]

    private static func capabilityReason(
        _ kind: DemandLiveSourceKind,
        codecName: String,
        url: URL,
        capabilities: LiveDemandDeviceCapabilities
    ) -> LiveDemandCandidateRejectionReason? {
        switch kind {
        case .hlsFMP4:
            guard capabilities.supportsHLSFMP4 else { return .unsupportedFormat }
            guard url.pathExtension.lowercased() == "m3u8" else { return .unsupportedPlaylistShape }
        case .progressiveFMP4:
            guard capabilities.supportsProgressiveFMP4 else { return .unsupportedFormat }
        case .hlsMPEGTS, .httpFLV:
            guard capabilities.supportsLibavformatLive else { return .unsupportedFormat }
            guard codecName == "avc" else { return .unsupportedCodec }
        }

        switch codecName {
        case "avc":
            return capabilities.supportsAVC ? nil : .unsupportedDeviceCodec
        case "hevc":
            return capabilities.supportsHEVC ? nil : .unsupportedDeviceCodec
        case "av1":
            return capabilities.supportsAV1 ? nil : .unsupportedDeviceCodec
        default:
            return .unsupportedCodec
        }
    }

    private static func endpointReason(
        rawURL: String,
        parsedURL: URL?
    ) -> LiveDemandCandidateRejectionReason? {
        guard !rawURL.unicodeScalars.contains(where: { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                CharacterSet.controlCharacters.contains(scalar)
        }) else {
            return .malformedURL
        }
        guard let url = parsedURL else {
            return .malformedURL
        }
        guard let scheme = url.scheme?.lowercased() else { return .malformedURL }
        guard scheme == "http" || scheme == "https" else {
            return .unsupportedProtocol
        }
        guard let host = url.host, !host.isEmpty else { return .malformedURL }
        return nil
    }

    private static func classifiedFailure(
        requestedQn: Int,
        from candidates: [Candidate]
    ) -> LiveStreamSelectionError {
        let diagnostics = LiveDemandSelectionDiagnostics(
            requestedQn: requestedQn,
            availableFamilies: boundedFamilies(from: candidates),
            rejectionReasons: boundedReasons(from: candidates)
        )
        let nearestMiss = candidates
            .compactMap(\.metadata.rejectionReason)
            .map { $0.admission }
            .max { $0.stage < $1.stage }

        guard let nearestMiss else {
            return .noCompatibleCandidate(diagnostics)
        }

        switch nearestMiss.kind {
        case .noCompatibleCandidate:
            return .noCompatibleCandidate(diagnostics)
        case .unsupportedContainer:
            return .unsupportedContainer(
                containers: containerLabels(from: candidates),
                diagnostics: diagnostics
            )
        case .unsupportedCodec:
            return .unsupportedCodec(
                codecs: codecLabels(from: candidates, matching: .unsupportedCodec),
                diagnostics: diagnostics
            )
        case .unsupportedDeviceCodec:
            return .unsupportedDeviceCodec(
                codecs: codecLabels(from: candidates, matching: .unsupportedDeviceCodec),
                diagnostics: diagnostics
            )
        case .unsupportedQuality:
            return .unsupportedQuality(
                offeredQualities: offeredQualities(from: candidates),
                diagnostics: diagnostics
            )
        }
    }

    private static func containerLabels(from candidates: [Candidate]) -> [String] {
        boundedLabels(candidates.compactMap { candidate in
            guard let reason = candidate.metadata.rejectionReason,
                  reason.admission.kind == .unsupportedContainer else { return nil }
            return reason == .unsupportedProtocol
                ? candidate.metadata.protocolName
                : candidate.metadata.formatName
        })
    }

    private static func codecLabels(
        from candidates: [Candidate],
        matching reason: LiveDemandCandidateRejectionReason
    ) -> [String] {
        boundedLabels(candidates.compactMap { candidate in
            candidate.metadata.rejectionReason == reason
                ? candidate.metadata.codecName
                : nil
        })
    }

    private static func offeredQualities(from candidates: [Candidate]) -> [Int] {
        var offered = Set<Int>()
        for candidate in candidates
            where candidate.metadata.rejectionReason == .qualityUnavailable {
            offered.formUnion(candidate.metadata.acceptQn)
            if let current = candidate.metadata.currentQn {
                offered.insert(current)
            }
        }
        return Array(offered.sorted(by: >).prefix(maxFailureLabels))
    }

    private static func boundedLabels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for value in values where seen.insert(value).inserted {
            labels.append(value)
            if labels.count == maxFailureLabels { break }
        }
        return labels
    }

    private static func boundedFamilies(from candidates: [Candidate]) -> [String] {
        var seen = Set<String>()
        var families: [String] = []
        for candidate in candidates where seen.insert(candidate.metadata.tupleFamily).inserted {
            families.append(candidate.metadata.tupleFamily)
            if families.count == 16 { break }
        }
        return families
    }

    private static func boundedReasons(from candidates: [Candidate]) -> [LiveDemandCandidateRejectionReason] {
        var seen = Set<LiveDemandCandidateRejectionReason>()
        var reasons: [LiveDemandCandidateRejectionReason] = []
        for reason in candidates.compactMap(\.metadata.rejectionReason)
            where seen.insert(reason).inserted {
            reasons.append(reason)
            if reasons.count == 8 { break }
        }
        return reasons
    }

    private static func hostClass(for rawHost: String) -> LiveDemandHostClass {
        let host = String(rawHost.prefix(256))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !host.isEmpty else { return .missing }
        if host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
            return .bilibili
        }
        if host.contains("bilivideo") ||
            host.contains("aliyun") || host.contains("aliyuncs") ||
            host.contains("myqcloud") {
            return .knownCDN
        }
        return .other
    }

    private static func tupleRank(
        protocolName: String,
        formatName: String,
        codecName: String
    ) -> Int {
        rank(protocolName, in: protocolOrder) * 100 +
            rank(formatName, in: formatOrder) * 10 +
            rank(codecName, in: codecOrder)
    }

    private static func rank(_ value: String, in order: [String]) -> Int {
        order.firstIndex(of: String(value.prefix(128)).lowercased()) ?? order.count
    }

    private static func normalizedProtocol(_ value: String) -> String {
        safeLabel(value)
    }

    private static func normalizedFormat(_ value: String) -> String {
        safeLabel(value)
    }

    private static func normalizedCodec(_ value: String) -> String {
        let normalized = safeLabel(value)
        if normalized.hasPrefix("avc") || normalized.hasPrefix("h264") { return "avc" }
        if normalized.hasPrefix("hev") || normalized.hasPrefix("hvc") || normalized.hasPrefix("dvh") {
            return "hevc"
        }
        if normalized.hasPrefix("av01") || normalized.hasPrefix("av1") { return "av1" }
        return normalized
    }

    private static func safeLabel(_ value: String) -> String {
        let lowercased = String(value.prefix(128))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let filtered = lowercased.filter { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
        let result = String(filtered.prefix(32))
        return result.isEmpty ? "unknown" : result
    }

    private static func normalizedQn(_ values: [Int]) -> [Int] {
        Array(Set(values.filter { $0 > 0 })).sorted(by: >)
    }

    private static func normalizedCurrentQn(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
