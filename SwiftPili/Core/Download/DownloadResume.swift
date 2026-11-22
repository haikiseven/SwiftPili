import Foundation

/// Resumable-download state and the pure policies that decide what a partial
/// transfer may do next.
///
/// The split here is deliberate and is what makes resume safe across a process
/// death: the **manifest is a plan**, and the **partial file's own length is the
/// progress**. Nothing writes a byte counter to disk alongside the media, so a
/// crash between a media write and a bookkeeping write cannot desynchronize the
/// two — the next launch stats the file and learns exactly how far it got.

// MARK: - Manifest

/// The plan for one download, persisted beside its partial media.
///
/// Fields are learned in two waves: the identity/presentation wave is known at
/// `startDownload`, and the resolved-stream wave (`resolvedQuality`, `codecs`,
/// `hasSeparateAudio`, `expectedBytes`) is filled in as the server answers. A
/// manifest missing the second wave is still resumable — the plan simply has to
/// re-derive it, and `matchesResolvedStream` is what forbids appending bytes
/// from a different encode onto the partial file.
struct DownloadManifest: Codable, Equatable, Sendable {
    static let fileName = "manifest.json"
    /// Bumped only for a change that makes an older manifest unsafe to resume.
    /// An unrecognized version is discarded, never guessed at.
    static let currentVersion = 1

    var version: Int
    let contentID: String
    let aid: Int
    let bvid: String
    let cid: Int
    let title: String
    let coverURL: String
    let ownerName: String
    let durationSeconds: Int
    /// What the user asked for. A URL refresh requests this again, not the
    /// resolved value, so the server's own fallback rules stay in charge.
    let requestedQuality: Int
    /// What the server actually resolved. A refreshed playurl must return this
    /// same (quality, codecs) pair or the partial bytes belong to a different
    /// encode and must be discarded rather than appended to.
    var resolvedQuality: Int?
    var codecs: String?
    var hasSeparateAudio: Bool?
    /// Absolute total length per stage, keyed by `DownloadStage.rawValue`.
    /// This is the completion criterion — not a progress-display value.
    var expectedBytes: [String: Int64]
    /// Optional for backward-compatible decoding of older manifests.
    var userPaused: Bool?

    var allowsAutomaticResume: Bool { userPaused != true }

    init(
        version: Int = DownloadManifest.currentVersion,
        contentID: String,
        aid: Int,
        bvid: String,
        cid: Int,
        title: String,
        coverURL: String,
        ownerName: String,
        durationSeconds: Int,
        requestedQuality: Int,
        resolvedQuality: Int? = nil,
        codecs: String? = nil,
        hasSeparateAudio: Bool? = nil,
        expectedBytes: [String: Int64] = [:]
    ) {
        self.version = version
        self.contentID = contentID
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.title = title
        self.coverURL = coverURL
        self.ownerName = ownerName
        self.durationSeconds = durationSeconds
        self.requestedQuality = requestedQuality
        self.resolvedQuality = resolvedQuality
        self.codecs = codecs
        self.hasSeparateAudio = hasSeparateAudio
        self.userPaused = nil
        self.expectedBytes = expectedBytes
    }

    func expected(_ stage: DownloadStage) -> Int64? {
        guard let value = expectedBytes[stage.rawValue], value > 0 else { return nil }
        return value
    }

    mutating func setExpected(_ stage: DownloadStage, bytes: Int64) {
        guard bytes > 0 else { return }
        expectedBytes[stage.rawValue] = bytes
    }

    /// Stage-keyed view of the recorded totals, for the completeness gate.
    var expectedBytesByStage: [DownloadStage: Int64] {
        var mapped: [DownloadStage: Int64] = [:]
        for (key, value) in expectedBytes {
            guard let stage = DownloadStage(rawValue: key), value > 0 else { continue }
            mapped[stage] = value
        }
        return mapped
    }

    /// Whole-asset expected length, or nil until every REQUIRED stage is known.
    /// `hasSeparateAudio` is what makes "every required stage" answerable; before
    /// the stream is resolved the answer is honestly unknown rather than a
    /// video-only undercount that a progress bar would render as near-complete.
    var totalExpectedBytes: Int64? {
        guard let hasSeparateAudio else { return nil }
        let required: [DownloadStage] = hasSeparateAudio ? [.video, .audio] : [.video]
        var total: Int64 = 0
        for stage in required {
            guard let value = expected(stage) else { return nil }
            total += value
        }
        return total
    }

    /// Whether a freshly resolved stream may continue this manifest's partial
    /// bytes. An unresolved manifest (nothing downloaded under it yet) admits
    /// anything; a resolved one demands the identical encode.
    func matchesResolvedStream(quality: Int, codecs: String) -> Bool {
        guard let resolvedQuality, let existingCodecs = self.codecs else { return true }
        return resolvedQuality == quality && existingCodecs == codecs
    }

    var isCurrentVersion: Bool { version == Self.currentVersion }
}

/// Revocable authority for foreground/relaunch continuation.
///
/// The manager takes one ID immediately before it starts that transfer. Keeping
/// the remaining IDs here, instead of in a captured array, lets an explicit
/// pause or cancel revoke a later item while an earlier download is awaiting.
struct DownloadAutomaticResumeQueue: Equatable, Sendable {
    private var ids: Set<String> = []

    var isEmpty: Bool { ids.isEmpty }

    mutating func enqueue<S: Sequence>(_ newIDs: S) where S.Element == String {
        ids.formUnion(newIDs)
    }

    mutating func revoke(_ id: String) {
        ids.remove(id)
    }

    mutating func takeNext(isBackgrounded: Bool) -> String? {
        guard !isBackgrounded, let id = ids.min() else { return nil }
        ids.remove(id)
        return id
    }
}

// MARK: - Stage planning

/// What a stage should do given the bytes already sitting in its partial file.
enum DownloadStagePlan: Equatable, Sendable {
    /// The partial file already holds every expected byte.
    case complete
    /// Nothing usable on disk — request the whole object.
    case restart
    /// Continue from this absolute offset.
    case resume(fromByte: Int64)
}

enum DownloadResumePolicy {
    static func stagePlan(bytesOnDisk: Int64, expectedBytes: Int64?) -> DownloadStagePlan {
        let onDisk = max(0, bytesOnDisk)
        guard onDisk > 0 else { return .restart }
        guard let expectedBytes, expectedBytes > 0 else {
            // No known total: the bytes are still real and a range request can
            // continue them. The completeness gate — not this policy — decides
            // whether an unverifiable stage may commit.
            return .resume(fromByte: onDisk)
        }
        if onDisk >= expectedBytes {
            // `>` means the file is longer than the object it claims to be, so
            // it is not this object's bytes at all. Restarting is the only
            // honest repair; appending would compound the corruption.
            return onDisk == expectedBytes ? .complete : .restart
        }
        return .resume(fromByte: onDisk)
    }
}

// MARK: - Content-Range

/// A parsed `Content-Range: bytes first-last/total` header.
struct DownloadContentRange: Equatable, Sendable {
    let firstByte: Int64
    let lastByte: Int64
    let totalLength: Int64?

    /// Parses the byte-unit form only. A `bytes */1234` unsatisfied-range form
    /// has no first/last pair and is deliberately not representable here.
    static func parse(_ header: String?) -> DownloadContentRange? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst("bytes ".count)
            .trimmingCharacters(in: .whitespaces)
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let rangePart = parts.first else { return nil }
        let bounds = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let first = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let last = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              first >= 0,
              last >= first
        else { return nil }

        let totalText = parts[1].trimmingCharacters(in: .whitespaces)
        let total: Int64?
        if totalText == "*" {
            total = nil
        } else {
            guard let parsed = Int64(totalText), parsed > last else { return nil }
            total = parsed
        }
        guard last < Int64.max else { return nil }
        return DownloadContentRange(firstByte: first, lastByte: last, totalLength: total)
    }
}

// MARK: - Range response admission

/// What the transport may do with the body that is about to arrive.
enum DownloadRangeVerdict: Equatable, Sendable {
    /// Append the body at this absolute offset. `totalLength` is the whole
    /// object's length when the response stated it.
    case append(atByte: Int64, totalLength: Int64?)
    /// The server ignored the range: discard
    /// what is on disk and take this body from byte 0.
    case replaceFromZero(totalLength: Int64?)
    /// Reject this suffix and issue a bounded fresh request at zero.
    case restartRequest
    /// Not a usable body.
    case reject(DownloadTransferError)
}

enum DownloadRangeResponsePolicy {
    /// `requestedOffset` is the offset the request asked to continue from; 0
    /// means the request carried no range at all.
    static func verdict(
        statusCode: Int,
        contentRange: String?,
        contentLength: Int64?,
        requestedOffset: Int64,
        knownTotalLength: Int64?,
        host: String
    ) -> DownloadRangeVerdict {
        if statusCode == 416 {
            // An error representation is never media, even when our old total
            // equals the requested offset. Revalidate with a fresh request.
            return requestedOffset > 0 ? .restartRequest
                : .reject(.httpStatus(host: host, code: statusCode))
        }
        if statusCode == 200 {
            let stated = contentLength.flatMap { $0 > 0 ? $0 : nil }
            // A resumed 200 whose length is not the object already on disk is
            // not a full replacement. Adopting it would truncate the prefix.
            if requestedOffset > 0, let stated, let knownTotalLength, knownTotalLength > 0,
               stated != knownTotalLength {
                return .restartRequest
            }
            return .replaceFromZero(totalLength: stated ?? knownTotalLength)
        }
        guard statusCode == 206 else {
            return .reject(.httpStatus(host: host, code: statusCode))
        }
        guard let range = DownloadContentRange.parse(contentRange),
              contentLength == nil || contentLength == range.lastByte - range.firstByte + 1
        else { return .reject(.rangeNotHonoured(host: host)) }
        // A 206 is explicitly a partial representation. Without either a
        // stated total or retained total, one response cannot prove the open
        // ended request reached EOF, so it must not become a committed asset.
        guard range.totalLength != nil || knownTotalLength != nil else {
            return .reject(.rangeNotHonoured(host: host))
        }
        let total = range.totalLength ?? knownTotalLength
        if let total, range.lastByte >= total {
            return .reject(.rangeNotHonoured(host: host))
        }
        if requestedOffset > 0, let knownTotalLength,
           let stated = range.totalLength, stated != knownTotalLength {
            return .restartRequest
        }
        guard range.firstByte == requestedOffset else {
            // The server answered a different window than we asked for. Splicing
            // it at our offset would leave a hole; only a from-zero body is safe.
            guard range.firstByte == 0 else {
                return .reject(.rangeNotHonoured(host: host))
            }
            return .replaceFromZero(totalLength: total)
        }
        return .append(atByte: range.firstByte, totalLength: total)
    }
}

// MARK: - Completeness

/// Whether a staged asset may be committed as a finished download.
enum DownloadCompletenessVerdict: Equatable, Sendable {
    case complete(totalBytes: Int64)
    case short(stage: DownloadStage, onDisk: Int64, expected: Int64)
    case missing(stage: DownloadStage)
    /// Origin stated no length; admitted as non-empty but unverified.
    case unverifiable(stage: DownloadStage, onDisk: Int64)

    var isVerified: Bool {
        switch self {
        case .complete: true
        case .unverifiable, .short, .missing: false
        }
    }
}

enum DownloadCompletenessPolicy {
    /// `stages` is the required set in order; `bytesOnDisk` and `expected` are
    /// keyed by stage. The first stage that fails decides the verdict, so a log
    /// names one concrete reason rather than a summary.
    static func verdict(
        stages: [DownloadStage],
        bytesOnDisk: [DownloadStage: Int64],
        expected: [DownloadStage: Int64]
    ) -> DownloadCompletenessVerdict {
        var total: Int64 = 0
        var unverifiable: DownloadCompletenessVerdict?
        for stage in stages {
            let onDisk = bytesOnDisk[stage] ?? 0
            guard onDisk > 0 else { return .missing(stage: stage) }
            total += onDisk
            guard let expectedBytes = expected[stage], expectedBytes > 0 else {
                // Remember the first unverifiable stage but keep checking: a
                // later stage that is provably short is the better answer.
                if unverifiable == nil {
                    unverifiable = .unverifiable(stage: stage, onDisk: onDisk)
                }
                continue
            }
            guard onDisk == expectedBytes else {
                return .short(stage: stage, onDisk: onDisk, expected: expectedBytes)
            }
        }
        return unverifiable ?? .complete(totalBytes: total)
    }
}

// MARK: - Staging identity

/// Content-derived staging folder naming so interrupted downloads are discoverable across relaunches.
enum DownloadStagingIdentity {
    static func folderName(contentID: String) -> String { contentID }

    /// Whether a staging folder name belongs to this content.
    static func matches(folderName: String, contentID: String) -> Bool {
        folderName == contentID
    }
}
