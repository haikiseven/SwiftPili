import Foundation

/// Integrity of what this pipeline hands VideoToolbox, observed at the one
/// place every compressed access unit enters a decode session.
///
/// Three independent facts, all of which render as the SAME symptom — moving
/// macroblock corruption that clears at the next keyframe — and none of which
/// any existing signal in this engine can see. Every liveness and proof signal
/// here counts frames (`framesProduced`, `displayedPictures`, presentation
/// proof, `DemandVideoLiveness`), so a session decoding garbage reports perfect
/// health: frames are produced, the clock advances, two distinct PTS prove the
/// surface. Correctness of the PICTURE is unobserved, which is why a corrupt
/// warm resume could survive every gate in the transaction that produced it.
///
/// 1. **Random access after a fresh session.** A new `VTDecompressionSession`
///    has an empty reference buffer, so a mid-GOP first submission decodes
///    against references that do not exist. libVLC's videotoolbox module
///    BLOCKS this (`STATE_BITSTREAM_WAITING_RAP` discards non-RAP frames after
///    every session restart) and this engine has no equivalent.
///
/// 2. **Decode-order continuity.** Consecutive submissions must be adjacent in
///    decode order; a gap breaks the reference chain even when every individual
///    sample is well formed. A candidate window's first/last PTS and packet
///    count cannot decide this — a contiguous decode-order window is
///    legitimately short by its reorder depth (device capture 2026-09-09:
///    `pts=20.100 dts=20.000` at 30 fps, so 3 frames are always in flight),
///    which is indistinguishable from a small hole in a summary line. Only a
///    per-submission check separates them.
///
/// 3. **NAL length-prefix tiling.** In avcC/hvcC form the length prefixes must
///    tile the access unit exactly. A walk that overruns or underruns is PROOF
///    the sample was mis-assembled before it reached the decoder — a
///    byte-range/assembly defect, not a decode defect. It is decidable from
///    the bytes alone: no container, no log correlation, no codec-specific
///    parsing. It costs one pointer read per NAL rather than a byte scan, so it
///    runs on every submission rather than a prefix of them (the corruption
///    this exists to catch appears seconds into a session, not at its first
///    frame).
///
/// ⚠️ **All three REPORT; none of them blocks a submission, deliberately.**
/// Rule 1 is the one that can never be legitimately violated, so blocking it
/// looks free — it is not, and this was evaluated and rejected rather than
/// assumed:
///
/// - Dropping until the next keyframe means dropping a whole GOP. `MediaEngine`
///   counts a submission that yields no frame in
///   `warmVideoSubmissionsWithoutOutput` against a limit of **64**
///   (`warmVideoNoOutputSubmissionLimit`), which is both a warm decode-loop
///   exit and a `.decoderPreparationExhausted` trigger. A 4–5 s GOP at 30 fps
///   is 120–150 frames, so a blocked rung would exhaust that limit and settle
///   as a user-visible Retry — strictly worse than the seconds of corruption it
///   replaces, which self-heal.
/// - The same silent stretch feeds `DemandVideoLiveness`, whose silent-video
///   fault spends boundary-1 decoder tickets; a recreate that lands mid-GOP
///   again would loop until the budget is exhausted, ending in the same Retry.
/// - `isKeyframe` can be systematically false: `PathAFMP4Parser` derives it
///   from `trun` sample flags and falls back to `false` when a fragment carries
///   neither per-sample flags, `first_sample_flags`, nor `tfhd`/`trex`
///   defaults. On such an input a blocking gate freezes video permanently where
///   today it plays.
///
/// So the enforcement half belongs WITH the producer fix (re-anchoring every
/// decoder replacement at a random access point), where the no-output
/// accounting can be made aware of an expected drop, and not before a device
/// log has shown which of the three facts is actually being violated. This
/// matches the project rule: accept a residual failure mode until a log proves
/// it, then fix it at its own producer.
///
/// Pure value type, `Foundation` only: it is compiled and RUN off-device on
/// Linux, the same way `RecoveryBudget` and `DecoderRecoveryAdmission` are.
struct VideoSubmissionIntegrity {

    // MARK: - Findings

    enum RandomAccess: Equatable {
        /// A sync sample has been submitted to this session, so later
        /// submissions decode against references that exist.
        case rooted
        /// No sync sample has reached this session yet: this submission is
        /// decoding against an empty reference buffer. Reported, not blocked.
        case unrooted(submissionsSinceOpen: Int)
    }

    enum Continuity: Equatable {
        /// First measurable submission of this session.
        case first
        case contiguous
        /// Decode order skipped forward: the reference chain is broken.
        case gap(previousEnd: TimeInterval, next: TimeInterval)
        /// Decode order went backward: submissions are out of order.
        case regression(previousEnd: TimeInterval, next: TimeInterval)
        /// No DTS, or no usable duration, so adjacency is not decidable. An
        /// unmeasured fact is never reported as a healthy one.
        case unmeasurable
    }

    enum Tiling: Equatable {
        case exact(nalCount: Int)
        /// The length-prefix size is not known for this format, so the walk is
        /// not attempted. Reported as unknown rather than as well formed —
        /// this is the state in which rule 3 is inert, and the session's
        /// `event=create … nalLen=` line is what makes that visible.
        case unknownLengthSize
        case empty
        /// Fewer bytes remain than a length prefix needs.
        case truncatedPrefix(offset: Int, remaining: Int)
        case zeroLength(offset: Int)
        /// A declared NAL length runs past the end of the access unit.
        case overrun(offset: Int, declared: Int, size: Int)

        var isMalformed: Bool {
            switch self {
            case .exact, .unknownLengthSize, .empty: false
            case .truncatedPrefix, .zeroLength, .overrun: true
            }
        }

        var diagnosticName: String {
            switch self {
            case .exact(let count): "exact(nals=\(count))"
            case .unknownLengthSize: "unknown-length-size"
            case .empty: "empty"
            case let .truncatedPrefix(offset, remaining):
                "truncated-prefix(at=\(offset) remaining=\(remaining))"
            case .zeroLength(let offset): "zero-length(at=\(offset))"
            case let .overrun(offset, declared, size):
                "overrun(at=\(offset) declared=\(declared) size=\(size))"
            }
        }
    }

    // MARK: - State

    private(set) var hasRandomAccess = false
    private(set) var submissionsBeforeRandomAccess = 0
    private(set) var observedSubmissions = 0
    private(set) var discontinuityCount = 0
    private(set) var malformedCount = 0
    private var previousDecodeEnd: TimeInterval?

    /// Adjacency tolerance. A single missing frame moves the next DTS a whole
    /// frame duration, so the threshold has to sit BELOW one frame; the floor
    /// absorbs timescale rounding (a 90 kHz or 12800-tick grid lands within a
    /// millisecond of the ideal boundary).
    static func tolerance(forDuration duration: TimeInterval) -> TimeInterval {
        max(duration * 0.25, 0.001)
    }

    /// A fresh native session. Every fact here is session-scoped: an empty
    /// reference buffer and an unknown decode position.
    mutating func reset() {
        self = VideoSubmissionIntegrity()
    }

    /// The decoder was flushed. Only the decode-order BASELINE is dropped:
    /// every flush in this engine precedes submissions from a different
    /// position — `MediaEngineSession`'s seek flushes both decoders after
    /// `clearPacketBuffers()`, and the warm path flushes a retained session
    /// before decoding a candidate rooted elsewhere — so keeping the baseline
    /// would report a gap on every seek and every retained-session warm
    /// resume. A false discontinuity is worse than none: it is exactly the
    /// misleading evidence this type exists to replace.
    ///
    /// `hasRandomAccess` deliberately SURVIVES. `VideoToolboxDecoder.flush()`
    /// waits for asynchronous frames; it does not invalidate the session or
    /// discard its reference chain, so "this session has been given a sync
    /// sample" is still true afterwards. Only `reset()` — a new native session
    /// — clears it.
    mutating func noteFlush() {
        previousDecodeEnd = nil
    }

    // MARK: - Rule 1

    /// Call once per submission, before it is handed to the decoder.
    mutating func noteRandomAccess(isKeyframe: Bool) -> RandomAccess {
        observedSubmissions += 1
        if isKeyframe { hasRandomAccess = true }
        guard hasRandomAccess else {
            submissionsBeforeRandomAccess += 1
            return .unrooted(submissionsSinceOpen: submissionsBeforeRandomAccess)
        }
        return .rooted
    }

    // MARK: - Rule 2

    /// Call once per submission, in submission order.
    mutating func noteDecodeOrder(
        dts: TimeInterval?,
        duration: TimeInterval
    ) -> Continuity {
        guard let dts, dts.isFinite, duration.isFinite, duration > 0 else {
            // Deliberately does not advance `previousDecodeEnd`: an
            // unmeasurable submission must not become the baseline that makes
            // the NEXT one look like a gap.
            return .unmeasurable
        }
        defer { previousDecodeEnd = dts + duration }
        guard let previousEnd = previousDecodeEnd, previousEnd.isFinite else {
            return .first
        }
        let tolerance = Self.tolerance(forDuration: duration)
        if dts > previousEnd + tolerance {
            discontinuityCount += 1
            return .gap(previousEnd: previousEnd, next: dts)
        }
        if dts < previousEnd - tolerance {
            discontinuityCount += 1
            return .regression(previousEnd: previousEnd, next: dts)
        }
        return .contiguous
    }

    /// Missing frames implied by a gap, for the log line. Reported as a count
    /// of frame slots because that is what the symptom is measured in.
    static func missingFrames(
        previousEnd: TimeInterval,
        next: TimeInterval,
        duration: TimeInterval
    ) -> Int? {
        guard duration.isFinite, duration > 0, next > previousEnd else { return nil }
        return Int(((next - previousEnd) / duration).rounded())
    }

    // MARK: - Rule 3

    mutating func note(tiling: Tiling) {
        if tiling.isMalformed { malformedCount += 1 }
    }

    static func tiling(of data: Data, nalLengthSize: Int?) -> Tiling {
        guard let nalLengthSize, (1...4).contains(nalLengthSize) else {
            return .unknownLengthSize
        }
        guard !data.isEmpty else { return .empty }
        return data.withUnsafeBytes { raw in
            tiling(of: raw, nalLengthSize: nalLengthSize)
        }
    }

    static func tiling(
        of raw: UnsafeRawBufferPointer,
        nalLengthSize: Int
    ) -> Tiling {
        guard (1...4).contains(nalLengthSize) else { return .unknownLengthSize }
        let size = raw.count
        guard size > 0 else { return .empty }
        var offset = 0
        var nalCount = 0
        while offset < size {
            guard size - offset >= nalLengthSize else {
                return .truncatedPrefix(offset: offset, remaining: size - offset)
            }
            var declared = 0
            for index in 0..<nalLengthSize {
                declared = (declared << 8) | Int(raw[offset + index])
            }
            guard declared > 0 else { return .zeroLength(offset: offset) }
            let next = offset + nalLengthSize + declared
            guard next <= size else {
                return .overrun(offset: offset, declared: declared, size: size)
            }
            offset = next
            nalCount += 1
        }
        return .exact(nalCount: nalCount)
    }
}
