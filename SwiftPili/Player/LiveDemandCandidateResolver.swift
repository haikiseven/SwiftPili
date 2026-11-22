import Foundation

/// The only host information retained by live candidate diagnostics. The
/// signed host/path itself stays on the selected URL handed to the backend and
/// is never part of a candidate summary or selection error.
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

/// Nearest-miss failure classification for Demand live stream admission:
/// reports the latest stage any candidate reached before refusal so container,
/// codec, device, and quality blocks are distinguished accurately.
enum LiveDemandSelectionFailureKind: String, Sendable, Equatable, CaseIterable {
    /// Nothing URL-bearing at all: no enumerable stream/format/codec tuple, or
    /// every tuple that existed lacked a usable absolute http(s) endpoint.
    case noCompatibleCandidate = "no-compatible-candidate"
    /// A URL-bearing tuple exists, but its transport or container is one the
    /// current Demand assembly cannot open, or fails the HLS/fMP4 playlist
    /// shape check.
    case unsupportedContainer = "unsupported-container"
    /// Demand can demux the container, but does not admit its codec combination.
    case unsupportedCodec = "unsupported-codec"
    /// Container and codec are both known, but THIS device's VideoToolbox
    /// probe says the decoder cannot open it.
    case unsupportedDeviceCodec = "unsupported-device-codec"
    /// Every tuple Demand could genuinely open advertises only qualities ABOVE
    /// the requested one.
    ///
    /// ⚠️ This says nothing about the room's CATALOGUE, only about the subset
    /// of it Demand can open, and the two genuinely differ: a room can list the
    /// requested rendition in `g_qn_desc`/`accept_qn` on a `ts` tuple while its
    /// `fmp4` tuple carries only a higher one. The nearest miss is then the
    /// quality gate (the fmp4 tuple cleared every earlier gate), so this is the
    /// right classification — but the message must not claim the room does not
    /// offer the rendition, because the picker the user chose it from was built
    /// from `accept_qn` and did offer it. See `errorDescription`.
    case unsupportedQuality = "unsupported-quality"

    /// Whether an explicit user Retry could plausibly change the answer.
    ///
    /// Exhaustive rather than defaulted, for the same reason
    /// `PlaybackUnavailability.isRetryable` is: the Retry affordance keys off
    /// this, and a new kind must be forced to choose. A Retry re-runs the
    /// identical play-info request at the identical qn against the identical
    /// engine, so a container/codec/quality answer is settled — offering Retry
    /// there is the permanent-answer loop `PlaybackUnavailability` was built to
    /// kill. `noCompatibleCandidate` is the one that can legitimately change:
    /// an empty topology is what an off-air or not-yet-started room looks like.
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
    /// How far this candidate got before refusal, and which failure identity it
    /// therefore votes for.
    ///
    /// `stage` exists only to pick the nearest miss across candidates; the
    /// absolute numbers carry no meaning beyond their order, which mirrors the
    /// order `enumerate` → `applyAdmission` → `qualityMatch` actually
    /// applies the gates in. libVLC's admission skips the container/codec
    /// stages entirely, so stages 2–4 are unreachable on that path — which is
    /// exactly why the routing policy prefers its verdict when both refuse. Exhaustive on purpose: a new rejection reason must
    /// state its stage rather than silently inherit one and be classified as
    /// something it is not.
    var admission: (stage: Int, kind: LiveDemandSelectionFailureKind) {
        switch self {
        case .missingURLInfo, .malformedURL:
            (0, .noCompatibleCandidate)
        // A non-http(s) scheme is a transport statement, not a broken URL, so
        // it belongs with the container/transport family the user is told
        // about — while staying distinguishable per candidate.
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

/// Privacy-safe projection of one API tuple. This is intentionally separate
/// from the URL-bearing resolver work: selection diagnostics can be retained
/// and tested without retaining signed `base_url`/`extra` values.
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

/// Bounded, privacy-safe projection of the nested live play-info topology.
/// It intentionally contains only normalized labels, quality numbers, URL
/// shape, path extension, and host classes. The original URL-bearing fields
/// never enter this value.
struct LiveDemandInputShapeSummary: Sendable, Equatable {
    let sanitizedSummary: String
}

/// Capability seam for the pure resolver. AVC is part of the existing Demand
/// parser/decoder contract. HEVC and AV1 use the caller's captured system
/// support facts; successful native decoder creation remains separate.
struct LiveDemandDeviceCapabilities: Sendable, Equatable {
    let supportsHLSFMP4: Bool
    let supportsProgressiveFMP4: Bool
    let supportsLibavformatLive: Bool
    let supportsAVC: Bool
    let supportsHEVC: Bool
    let supportsAV1: Bool
}

struct LiveDemandResolvedTuple: Sendable, Equatable {
    /// The signed URL is retained only for the immediate backend open. It is
    /// deliberately absent from `LiveDemandCandidateMetadata` and errors.
    let url: URL
    let metadata: LiveDemandCandidateMetadata
    let actualQn: Int
    /// Non-nil only for a tuple admitted by Demand. Native selection retains its own dispatch.
    let liveSourceKind: DemandLiveSourceKind?
    /// At most one other signed endpoint from the selected TS codec row.
    let hlsTSBackupPlaylistURL: URL?

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

/// Bounded, privacy-safe evidence carried by every selection failure.
///
/// Same rule as `LiveDemandCandidateMetadata`: normalized labels, quality
/// numbers and rejection tokens only. A signed URL, a `base_url` or an `extra`
/// cannot reach this value, which is why it is safe to log always-on and to
/// retain for the life of the load.
struct LiveDemandSelectionDiagnostics: Sendable, Equatable {
    let requestedQn: Int
    /// Normalized `protocol/format/codec` families the response advertised,
    /// deduped and capped. This is what the room OFFERED, not what refused.
    let availableFamilies: [String]
    /// Every distinct per-candidate rejection, deduped and capped. The headline
    /// classification is one of these; the rest stay here so a second blocker
    /// is never hidden behind the nearest miss.
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

/// Why Demand live could not open anything — one case per cause, never one
/// bucket. See `LiveDemandSelectionFailureKind` for how the case is chosen.
enum LiveStreamSelectionError: Error, LocalizedError, Sendable, Equatable {
    /// Nothing URL-bearing at all.
    case noCompatibleCandidate(LiveDemandSelectionDiagnostics)
    /// `containers` are the normalized transport/container labels that were
    /// offered and refused — `ts`, `flv`, an unknown protocol name.
    case unsupportedContainer(
        containers: [String],
        diagnostics: LiveDemandSelectionDiagnostics
    )
    /// `codecs` are the normalized codec labels Demand does not know.
    case unsupportedCodec(
        codecs: [String],
        diagnostics: LiveDemandSelectionDiagnostics
    )
    /// `codecs` are known to Demand but refused by this device's VT probe.
    case unsupportedDeviceCodec(
        codecs: [String],
        diagnostics: LiveDemandSelectionDiagnostics
    )
    /// `offeredQualities` are the qn values the openable tuples DO carry, all
    /// of them above the requested one (the resolver never upgrades).
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

    /// Whether Retry could plausibly change the answer — forwarded from the
    /// classification so there is exactly one place that decides it.
    var isRetryable: Bool { classification.isRetryable }

    /// User-facing, localized, and specific to the ACTUAL cause.
    ///
    /// This is what `PlayerViewModel.markTerminalOpenFailure` paints into the
    /// player overlay, so it must never name the requested quality unless the
    /// quality is what failed. Every interpolation is a normalized label or a
    /// qn number, so no signed URL can reach the screen through this path.
    var errorDescription: String? {
        switch self {
        case .noCompatibleCandidate:
            return String(localized: "This live room is not offering a stream this player can open.")
        case .unsupportedContainer(let containers, _):
            // Engine-neutral message: ordinary TS/FLV rooms are routed to libVLC by
            // `LiveEngineRoutePolicy`, so this surfaces only when pinned or refused by both.
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
            // Deliberately about the openable SET, not about the room. "This
            // live room does not offer 流畅" is false whenever the room lists
            // that rendition on a container Demand refused — and the live
            // quality picker is built from `accept_qn` across every format
            // (`LiveRoomViewModel.updateQualities`), so the user can reach
            // exactly that state by choosing a rendition the room really does
            // advertise. Telling them the room does not offer what the picker
            // just showed them is the same misreport this whole type exists to
            // end, one boundary further along.
            return String(
                format: String(localized: "No stream this player can open offers %@."),
                Self.qualityLabel(diagnostics.requestedQn)
            )
        }
    }

    /// Stable machine token for the always-on diagnostic line. Deliberately
    /// NOT the localized sentence: a log that changes with the device language
    /// cannot be grepped across two device captures.
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

    /// The labels that produced the headline: containers, codecs, or the qn
    /// values that were on offer. `none` when the cause carries no label.
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

    /// Container and codec labels are already normalized to lowercase ASCII by
    /// `safeLabel`; upper-casing them is presentation only. The `-` is
    /// unreachable in practice (a classification is only chosen when at least
    /// one candidate carried its label) and is language-neutral by design.
    private static func displayList(_ labels: [String]) -> String {
        let visible = labels.prefix(4).map { $0.uppercased() }
        return visible.isEmpty ? "-" : visible.joined(separator: ", ")
    }

    /// The room's own `g_qn_desc` is not consulted here on purpose: this type
    /// is built from the privacy-safe projection, not from the response, and
    /// the static live rendition table already names every qn the picker
    /// offers. A qn outside that table degrades to the number rather than to a
    /// wrong name.
    private static func qualityLabel(_ qn: Int) -> String {
        LiveQualityDescription.fallbackText(for: qn)
            ?? String(format: String(localized: "quality %lld"), qn)
    }
}

/// Records when a live tuple opened at a deterministic lower quality than requested.
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

    /// Non-nil only when something WAS selected and it is not the quality that
    /// was requested. `qualityMatch` never upgrades, so this is always a
    /// downgrade; it is expressed as requested-vs-actual rather than as a bare
    /// direction so the caller can name both numbers.
    var qualityFallback: LiveDemandQualityFallback? {
        guard let selected, selected.actualQn != requestedQn else { return nil }
        return LiveDemandQualityFallback(
            requestedQn: requestedQn,
            actualQn: selected.actualQn
        )
    }
}

/// Why a live load is running on an engine other than the selected one.
///
/// Every case names a BACKEND CAPABILITY, never a quality. That distinction is
/// the whole point of the routing: a room that streams qn 10000 as MPEG-TS is
/// not a qn-10000 problem, it is a "no MPEG-TS demuxer in `Player/Engine/`"
/// problem, and answering it by quietly serving qn 400 out of the room's fmp4
/// tuple trades the user's chosen rendition for the app's chosen engine.
enum LiveEngineHandoffReason: String, Sendable, Equatable, CaseIterable {
    /// Demand cannot demux the container the room streams — `ts`, `flv`, or a
    /// playlist shape its HLS reader does not accept.
    case container
    /// The container is demuxable but the elementary codec is not known.
    case codec
    /// Container and codec are known; this device's VideoToolbox probe refuses.
    case deviceCodec = "device-codec"
    /// Demand could have opened something — but only by DROPPING BELOW the
    /// requested rendition, while libVLC can open the requested one. Also the
    /// answer when Demand's openable subset carries no rendition at or under
    /// the request while the wider set does.
    case qualityPreservation = "quality-preservation"
    /// Demand found nothing openable at all.
    case noCandidate = "no-candidate"
}

/// Which engine opens this live load, and with which tuple.
///
/// The URL travels INSIDE the route rather than being re-derived by the caller.
/// A live topology can serve a different `current_qn` per container, so
/// "libVLC at the requested quality" is a statement about a specific tuple, not
/// about the first parseable URL in the response — the legacy first-match walk
/// would happily hand libVLC the room's fmp4 qn-400 entry while the qn-10000
/// entry sat one container further down the list.
enum LiveEngineRoute: Sendable, Equatable {
    case demand(LiveDemandResolvedTuple)
    case libVLC(LiveDemandResolvedTuple, reason: LiveEngineHandoffReason)
    case refused(LiveStreamSelectionError)
}

/// Quality outranks engine; engine breaks ties.
///
/// The policy is pure and total over two selections produced by the SAME
/// enumeration — `LiveDemandCandidateResolver.select` (Demand admission) and
/// `.selectNative` (libVLC admission) — which is what makes it decidable with
/// one comparison. Because `.selectNative` differs from `.select` only by NOT
/// applying the container/codec gate, every candidate Demand admits is also
/// admitted natively; `choose` maximises the qn within the admitted set; so
///
///     native.selected?.actualQn >= demand.selected?.actualQn
///
/// is an invariant, not a hope. The rule then reduces to: **run Demand when it
/// reaches the same rendition libVLC would, and libVLC whenever it reaches a
/// higher one.** That single line derives every row of the matrix this exists
/// for, including the one that motivated it (qn 10000 as `ts` beside qn 400 as
/// `fmp4` → libVLC at 10000, not Demand at 400).
enum LiveEngineRoutePolicy {
    static func route(
        demand: LiveDemandSelection,
        native: LiveDemandSelection,
        pinsPreferredEngine: Bool
    ) -> LiveEngineRoute {
        if pinsPreferredEngine {
            // The pin exists so the Demand gap stays VISIBLE and testable. With
            // routing on, a TS/FLV room silently becomes a libVLC room and
            // nothing on the device says Demand cannot demux it — which is how
            // an unimplemented demuxer comes to look like a finished one. So
            // the pinned path keeps the original contract exactly: Demand's own
            // verdict, refusal included.
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

        // Neither engine can open anything, so the verdict that reaches the
        // user must be the WIDER engine's. Demand's headline here would name
        // the container gate for a room whose real blocker is upstream of it
        // (its `ts` tuple never reaches Demand's quality gate at all, so its
        // nearest miss is stuck at the container stage) — the same
        // nearest-miss misreport `LiveDemandSelectionFailureKind` was built to
        // end, one layer up. libVLC applies no container gate, so its nearest
        // miss is the boundary that genuinely refused.
        return .refused(native.failure ?? demand.failure ?? .noCompatibleCandidate(
            LiveDemandSelectionDiagnostics(requestedQn: native.requestedQn)
        ))
    }

    /// Exhaustive on the classification for the same reason `isRetryable` is:
    /// a new failure kind must state which capability it means rather than
    /// inherit a label that would then be printed as the cause.
    private static func handoffReason(demand: LiveDemandSelection) -> LiveEngineHandoffReason {
        guard let failure = demand.failure else {
            // Demand DID select a tuple. The only way it loses the comparison
            // above is by having selected a lower rendition than libVLC can
            // serve, so the hand-off is buying back the requested quality.
            return .qualityPreservation
        }
        switch failure.classification {
        case .noCompatibleCandidate: return .noCandidate
        case .unsupportedContainer: return .container
        case .unsupportedCodec: return .codec
        case .unsupportedDeviceCodec: return .deviceCodec
        // Demand's openable subset offers nothing at or below the request while
        // the wider set does — a quality outcome, not a codec one.
        case .unsupportedQuality: return .qualityPreservation
        }
    }
}

/// Pure, deterministic admission and ordering for live candidates.
/// Network access begins only after a non-nil `selected` tuple is handed to
/// `PlayerViewModel.playURL`.
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
    /// Bound on the label list a failure carries. Same reason every other cap
    /// here exists: a malformed response must not be able to grow a log line
    /// or an error message without limit.
    private static let maxFailureLabels = 8

    private typealias ShapeCodec = LivePlayInfo.PlayurlInfo.Playurl.StreamInfo.FormatInfo.CodecInfo

    /// Whose demuxers the admission gate is speaking for.
    ///
    /// The two engines share the enumeration, the URL-validity gate, the
    /// quality rule and the ordering; they differ by exactly one stage, which
    /// is why it is a parameter and not a second resolver. Keeping it a
    /// parameter is also what makes `LiveEngineRoutePolicy`'s superset
    /// invariant provable rather than asserted.
    private enum EngineAdmission {
        /// The Demand demuxers in `Player/Engine/Demux/`: container, playlist
        /// shape and codec all gated, against a device capability probe.
        case demand(LiveDemandDeviceCapabilities)
        /// libVLC. No container or codec stage at all — see `applyAdmission`.
        case native
    }

    static func select(
        info: LivePlayInfo,
        requestedQn: Int,
        capabilities: LiveDemandDeviceCapabilities
    ) -> LiveDemandSelection {
        resolve(info: info, requestedQn: requestedQn, admission: .demand(capabilities))
    }

    /// What libVLC should be asked to open, and at what quality.
    ///
    /// Answers the second half of the routing question. libVLC needs no
    /// capability filtering — it demuxes fmp4, MPEG-TS and FLV natively — and
    /// live candidates deliberately bypass VOD CDN/host policy (live CDN is a
    /// different network from the upos pool, so the VOD allowlist would reject
    /// working streams). So the only admission left is the structural one live
    /// has always applied and `enumerate` already applies: a parseable absolute
    /// http(s) endpoint.
    ///
    /// The quality rule is deliberately the SAME `qualityMatch` the Demand path
    /// uses, so the two answers are comparable numbers rather than two
    /// engines' opinions. Note what this buys over the legacy live URL walk
    /// (`PlayerViewModel.resolveLiveURL`), which ranks by container and returns
    /// the first parseable entry with no quality matching whatsoever: against a
    /// room offering qn 10000 as `ts` and qn 400 as `fmp4`, that walk hands
    /// libVLC the qn-400 fmp4 URL. Falling back through it would have thrown
    /// away the very rendition the fallback exists to preserve.
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
            hlsTSBackupPlaylistURL: backupPlaylistURL(for: selected, among: admitted)
        )
        return LiveDemandSelection(
            requestedQn: requestedQn,
            inputShape: inputShape,
            candidates: evaluated.map(\.metadata),
            selected: selectedTuple,
            failure: nil
        )
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
        // Shape diagnostics must stay cheap even if a malformed server field
        // is unexpectedly enormous. Candidate selection still receives the
        // original signed value; only this metadata projection is bounded.
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
                            // There is no URL-bearing field to try. Keep the
                            // tuple in diagnostics without manufacturing a
                            // host or treating an empty base URL as usable.
                            urlReason = .missingURLInfo
                        } else {
                            // A base_url-only response is accepted only when
                            // base_url is already a complete signed endpoint.
                            // Relative URLs must not be resolved against an
                            // invented host or have URLInfo extras appended.
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
                // The libVLC admission is the ABSENCE of this stage, and that
                // absence is the feature: applying Demand's container/codec
                // gate to the fallback engine is precisely what would make the
                // fallback pointless. Everything upstream still holds — the
                // candidate reached here only by clearing `endpointReason`
                // (absolute http(s) URL, real host, no whitespace) — and
                // everything downstream still holds: `qualityMatch` and
                // `choose` are shared, unchanged.
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

        // An explicit accepted exact quality wins even when the API's
        // current_qn field describes a lower rendition currently being
        // advertised by the same tuple.
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
        if current == nil, accepted.isEmpty, requested > 0 {
            // Older responses omitted both fields. Preserve the URL-bearing
            // path, but make the requested qn the explicit actual value.
            return QualityMatch(actualQn: requested, isExact: true)
        }
        return nil
    }

    // For equally ranked new live inputs, FLV can supply a keyframe without
    // waiting for a TS media playlist and a subsequent segment request.
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
        // URL(string:) is intentionally permissive and accepts literal spaces
        // in path components. Signed API data must already be a valid URL;
        // percent-encoding it here could change the signature, so reject such
        // input and continue to the next URL-bearing candidate.
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
        // Structural validity only. Live CDN hosts are not the VOD CDN pool,
        // so no host-admission decision is made here: the upstream-provided
        // candidate is used as-is.
        return nil
    }

    /// Turn the evaluated candidate set into ONE typed cause.
    ///
    /// The nearest miss wins (see `LiveDemandSelectionFailureKind`): the
    /// candidate that cleared the most admission gates names the boundary the
    /// user is told about. Everything else survives in `rejectionReasons`.
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
            // Every candidate was admitted and yet none was chosen. `choose`
            // cannot return nil for a non-empty admitted set, so reaching here
            // means the admitted set was empty for a reason no candidate
            // recorded. Fail closed on the one answer the evidence supports
            // rather than inventing a container or a quality to blame.
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

    /// What the room streamed in, from the candidates the container/transport
    /// gate refused. A protocol refusal names the protocol (`rtmp`), a format
    /// or playlist-shape refusal names the format (`ts`, `flv`) — the label
    /// that identifies the thing Demand has no demuxer for.
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

    /// The qualities the openable-but-wrong-qn tuples actually carry. Both
    /// `accept_qn` and `current_qn` count: a tuple can advertise a rendition
    /// list while currently serving one of them.
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

    /// Dedupe preserving the candidates' existing rank order, then cap. The
    /// order is already deterministic, so the label list is too.
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
