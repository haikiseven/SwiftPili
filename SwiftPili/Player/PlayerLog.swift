import Foundation
import os
import Synchronization

/// Centralized debug logging gate. All diagnostic output — app-level
/// prints, os_log messages, and the VLC vendor log level — is
/// controlled by a single "Debug Logging" toggle in Settings → Playback.
/// When the toggle is off (the default), nothing is emitted.
///
/// Hot-path call sites use `@autoclosure` so string interpolation is
/// skipped entirely when logging is disabled — zero per-frame cost.
///
/// O2: every emitted line is scrubbed for phone numbers, captcha fields,
/// and signed CDN query tokens before it hits the console.
enum PlayerLog {
    static let subsystem = "com.swiftpili.app"
    private static let logger = Logger(subsystem: subsystem, category: "Player")

    /// Separate category so a soak can be captured WITHOUT the per-frame
    /// firehose: `log stream --predicate 'category == "Diagnostic"'` yields
    /// only the lines below. Mixing these into "Player" is what makes a
    /// device capture unreadable.
    static let diagnosticCategory = "Diagnostic"
    private static let diagnosticLogger = Logger(subsystem: subsystem, category: diagnosticCategory)

    #if DEBUG
    /// Offload `print()` onto a serial utility queue so Xcode's synchronous stdout capture cannot stall MainActor.
    private static let sink = DispatchQueue(label: "com.swiftpili.playerlog", qos: .utility)
    #endif

    private static let consoleEnabled = Atomic<Bool>(false)

    /// Compatibility writes apply a runtime projection; saved choices remain in
    /// their existing preference owner. Every consumer still checks permission.
    static var isEnabled: Bool {
        get { ExperimentalSettingsPolicy.diagnosticsEnabled && consoleEnabled.load(ordering: .acquiring) }
        set { consoleEnabled.store(newValue && ExperimentalSettingsPolicy.diagnosticsEnabled, ordering: .releasing) }
    }

    @MainActor
    static func setEnabled(_ enabled: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        UserDefaults.standard.set(enabled, forKey: "debug_logging_enabled")
        isEnabled = enabled
        PowerProfiler.shared.setStreaming(isEnabled)
    }

    /// Policy restoration must not write the saved choice or reset a capture.
    @MainActor
    static func applyExperimentalPolicy(activateCollectors: Bool = true) {
        isEnabled = UserDefaults.standard.bool(forKey: "debug_logging_enabled") || debugRequestedAtLaunch
        if activateCollectors { PowerProfiler.shared.setStreaming(isEnabled) }
    }

    /// Process-wide launch request for diagnostics, independent of the sticky
    /// Settings toggle. Env is preferred for `devicectl`, which eats dashed
    /// arguments; both argument spellings are kept for older capture scripts.
    nonisolated static let debugRequestedAtLaunch: Bool = {
        let info = ProcessInfo.processInfo
        return info.environment["PLAYER_DEBUG"] == "1"
            || info.arguments.contains("-player-debug")
            || info.arguments.contains("player-debug=1")
    }()

    /// True when any consumer wants diagnostic lines BUILT: the console /
    /// os_log path (`isEnabled`) or the on-device playback report ring
    /// (`PlaybackDebugRecorder.isEnabled`). Emitters that pre-gate a whole
    /// formatting block on `isEnabled` must gate on THIS instead — otherwise
    /// a report captured with Debug Logging off silently misses the very
    /// lines it exists for.
    static var isCapturing: Bool { isEnabled || PlaybackDebugRecorder.isEnabled }

    /// Log a diagnostic message when debug logging is enabled; no-op
    /// otherwise.  `@autoclosure` defers string construction so hot-path
    /// call sites pay nothing when disabled.
    ///
    /// DEBUG: `print()` for Xcode console **and** `os.Logger` so USB
    /// `idevicesyslog` / Console.app can capture device soaks without an
    /// attached debugger (print alone is invisible on device). Release:
    /// `os.Logger` only. Xcode may show both when attached — acceptable for soak.
    static func log(_ message: @autoclosure () -> String) {
        // Playback-report tap sits BEFORE the console gate: the recorder can
        // capture with Debug Logging off (ring only — no print, no os_log).
        // Same redaction path; the ring must never be the copy of a signed URL.
        let report = PlaybackDebugRecorder.isEnabled
        guard isEnabled || report,
              let access = ExperimentalSettingsPolicy.captureAccess(.diagnostics) else { return }
        let msg = redact(message())
        guard access.isValid else { return }
        // Freeze forensics tap. Inside the gate, so it costs nothing when
        // nothing is capturing, and after `redact`, so the line the freeze
        // report prints and PERSISTS is the scrubbed one. It answers "what was
        // the app doing immediately before this froze" without the watchdog
        // having to reach back into MainActor state it cannot touch.
        FreezeWatchdog.noteLogLine(msg)
        if report { PlaybackDebugRecorder.shared.record(msg) }
        guard isEnabled else { return }
        #if DEBUG
        sink.async {
            guard access.isValid, isEnabled else { return }
            print(msg)
        }
        #endif
        logger.log("\(msg, privacy: .public)")
    }

    /// Always-on post-mortem marker for invariant failures or silent stalls,
    /// redacted and persisted at `.error` level regardless of `isEnabled`.
    static func diagnostic(_ message: @autoclosure () -> String) {
        let msg = redact(message())
        FreezeWatchdog.noteLogLine(msg)
        if PlaybackDebugRecorder.isEnabled {
            PlaybackDebugRecorder.shared.record("⚠️ \(msg)")
        }
        #if DEBUG
        sink.async { print("⚠️ \(msg)") }
        #endif
        diagnosticLogger.error("\(msg, privacy: .public)")
    }

    /// One redaction rule, plus the cheap precondition that admits it.
    ///
    /// The precondition is not a heuristic: each `Gate` is a NECESSARY condition
    /// for the pattern to match at all, so skipping a rule whose gate is closed
    /// cannot change the output. See `redact` for why that matters.
    private struct RedactionRule {
        enum Gate {
            /// The pattern contains a literal `?`.
            case query
            /// The pattern needs eleven consecutive digits.
            case phoneRun
            /// The pattern is `<key>=`, so the lowercased key must appear
            /// immediately before an `=`.
            case keyword([UInt8])

            var isQuery: Bool { if case .query = self { true } else { false } }
            var isPhoneRun: Bool { if case .phoneRun = self { true } else { false } }
        }

        let gate: Gate
        let regex: NSRegularExpression
        let template: String
    }

    /// Redaction rules, compiled once. `replacingOccurrences(options:
    /// .regularExpression)` recompiles its pattern on every call, and redact
    /// runs per emitted line on the log-forwarding path — with `--verbose=2`
    /// active that was hundreds of compilations per second during seeks.
    /// NSRegularExpression is immutable, documented thread-safe, and Sendable,
    /// so this static constant safely shares the compiled instances.
    private static let redactionRules: [RedactionRule] = {
        var rules: [RedactionRule] = []
        // Signed CDN / auth query blobs: keep scheme+host+path, drop `?...`.
        // bilivideo / upos / akamai style URLs carry exp/sign/token in the query.
        rules.append(RedactionRule(
            gate: .query,
            regex: try! NSRegularExpression(pattern: #"(https?://[^\s\"']+)\?[^\s\"']+"#),
            template: "$1?<redacted>"
        ))
        // Phone-like runs (CN mobile 1[3-9]… or bare 11-digit); leave short numbers.
        rules.append(RedactionRule(
            gate: .phoneRun,
            regex: try! NSRegularExpression(pattern: #"\b1[3-9]\d{9}\b"#),
            template: "<phone>"
        ))
        // Captcha / session tokens as key=value (query, form, or Cookie pairs).
        // Stop at whitespace, &, quotes, or `;` so `Cookie: SESSDATA=x; bili_jct=y`
        // redacts each cookie rather than swallowing the rest of the header.
        for key in [
            "challenge", "validate", "seccode", "captcha", "geetest",
            "token", "refresh_token", "access_key",
            "SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5",
        ] {
            rules.append(RedactionRule(
                gate: .keyword(Array(key.lowercased().utf8)),
                regex: try! NSRegularExpression(
                    pattern: #"\#(key)=[^\s&\"';]+"#,
                    options: [.caseInsensitive]
                ),
                template: "\(key)=<redacted>"
            ))
        }
        return rules
    }()

    /// Strip secrets that commonly land in player / network debug lines when
    /// Debug Logging is on (O2). Pure and side-effect free so tests can pin it.
    ///
    /// **Why there is an admission pass in front of the rules.** This runs on
    /// the CALLER's thread for every emitted line, and the caller is routinely
    /// the main thread mid-scroll — `[cover]` fires once per resolved cover,
    /// `[hitch]` once per frame-pacing window, `[Power]` and the player's 1Hz
    /// instruments from the main actor. `stringByReplacingMatches` costs a full
    /// UTF-16 bridge of the subject plus a freshly allocated result *even when
    /// it replaces nothing*, so running all fourteen rules unconditionally meant
    /// fourteen scans and fourteen string copies of every line the app has ever
    /// logged. Measured off-device on the representative `[cover]` line: 15.2µs
    /// before, 0.24µs after — a 60× cut on the app's highest-volume log path,
    /// with byte-identical output over the redaction test corpus plus 40,000
    /// randomised inputs, non-ASCII spellings included (see the warning below —
    /// the FIRST version of these gates was not byte-identical, and the corpus
    /// is what caught it).
    ///
    /// The saving is real precisely because each gate is a NECESSARY condition
    /// for its pattern, established in one pass over the UTF-8 bytes with no
    /// allocation: the URL rule cannot match without a literal `?`, the phone
    /// rule cannot match without eleven consecutive digits, and a `key=` rule
    /// cannot match unless that key sits immediately before an `=`. A line that
    /// admits nothing is returned unchanged, which is the overwhelmingly common
    /// case and now genuinely free.
    ///
    /// ⚠️ **Necessary means necessary for what ICU actually matches, not for the
    /// pattern as it reads in ASCII.** The first version of these gates decided
    /// both digits and letters as ASCII, and that made two of them sufficient
    /// rather than necessary — a differential run against the ungated rules
    /// found real leaks, six in a 28-line corpus and 14 in 40,000 randomised
    /// inputs:
    ///
    ///  - `\d` in `NSRegularExpression` is Unicode `Nd`, not `[0-9]`. So
    ///    `13٠١٢٣٤٥٦٧٨` (ASCII `13` + nine ARABIC-INDIC digits) matches the
    ///    phone rule, while an ASCII-only digit run counts 2 and closes the
    ///    gate.
    ///  - `.caseInsensitive` is FULL Unicode case folding, not A–Z. So
    ///    `toKen=` with U+212A KELVIN SIGN, `SEſSDATA=` with U+017F, and
    ///    `geeteﬅ=` with the U+FB05 ligature all match their `key=` rules,
    ///    while a byte-wise A–Z fold rejects them.
    ///
    /// Both gates therefore treat a byte ≥ 0x80 as UNDECIDABLE and admit: any
    /// non-ASCII `Nd` digit occupies at least two UTF-8 bytes, and any
    /// non-ASCII character that folds into a key is at least as long in bytes
    /// as the ASCII it folds to, so in both cases the run/window the gate
    /// inspects necessarily contains a byte ≥ 0x80. That keeps the gates
    /// necessary by construction rather than by inspection — and the phone gate
    /// additionally requires an ASCII digit inside the run (the pattern's own
    /// `1[3-9]` prefix is ASCII), which is what keeps CJK text from opening it:
    /// measured off-device, `[cover]` 15.2µs → 0.24µs, and a CJK or emoji line
    /// stays at 0.06–0.09µs.
    ///
    /// It is deliberately NOT a "does this line look sensitive" heuristic —
    /// that would be a guess about content, and this function's whole job is to
    /// be unable to guess wrong.
    static func redact(_ raw: String) -> String {
        let admitted = redactionAdmissions(raw)
        guard admitted != 0 else { return raw }
        var s = raw
        for (index, rule) in redactionRules.enumerated() where admitted & (1 << UInt32(index)) != 0 {
            s = rule.regex.stringByReplacingMatches(
                in: s,
                range: NSRange(s.startIndex..., in: s),
                withTemplate: rule.template
            )
        }
        return s
    }

    // Gate lookup tables, derived from `redactionRules` so they cannot drift out
    // of step with the rule order, and flattened so the byte scan below never
    // unwraps an enum payload or walks a rule it cannot use.

    private static let redactionQueryMask: UInt32 = ruleMask { $0.gate.isQuery }
    private static let redactionPhoneMask: UInt32 = ruleMask { $0.gate.isPhoneRun }

    /// `(bit, lowercase key bytes)` for every keyword rule.
    private static let redactionKeywords: [(bit: UInt32, needle: [UInt8])] = {
        var out: [(bit: UInt32, needle: [UInt8])] = []
        for (index, rule) in redactionRules.enumerated() {
            guard case let .keyword(needle) = rule.gate else { continue }
            out.append((UInt32(1) << UInt32(index), needle))
        }
        return out
    }()

    private static func ruleMask(_ matches: (RedactionRule) -> Bool) -> UInt32 {
        var mask: UInt32 = 0
        for (index, rule) in redactionRules.enumerated() where matches(rule) {
            mask |= UInt32(1) << UInt32(index)
        }
        return mask
    }

    /// Bitmask of `redactionRules` indices whose gate the line opens. One pass
    /// over the UTF-8 bytes; no allocation, no bridging, no regex.
    ///
    /// `withUTF8` rather than iterating `raw.utf8`: the keyword check needs to
    /// look BACKWARDS from an `=`, which wants random access into a contiguous
    /// buffer. It is `mutating` on `String`, hence the local copy — free for the
    /// native contiguous strings every interpolated log line produces.
    private static func redactionAdmissions(_ raw: String) -> UInt32 {
        var subject = raw
        return subject.withUTF8 { bytes -> UInt32 in
            var mask: UInt32 = 0
            var digitRun = 0
            var digitRunHasASCIIDigit = false
            for index in 0..<bytes.count {
                let byte = bytes[index]
                let isASCIIDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
                // A byte ≥ 0x80 continues the run because `\d` is Unicode `Nd`,
                // not `[0-9]` — see `redact`. Every non-ASCII `Nd` digit is at
                // least two UTF-8 bytes, so eleven of them are at least eleven
                // consecutive bytes here, and the run stays a necessary
                // condition. The ASCII-digit requirement comes from the
                // pattern's own `1[3-9]` prefix, which is ASCII by construction,
                // and is what stops a run of CJK from opening this gate.
                if isASCIIDigit || byte >= 0x80 {
                    digitRun += 1
                    if isASCIIDigit { digitRunHasASCIIDigit = true }
                    // Eleven is the phone pattern's own length; a longer run
                    // contains one, so this stays a necessary condition.
                    if digitRun >= 11, digitRunHasASCIIDigit { mask |= redactionPhoneMask }
                    continue
                }
                digitRun = 0
                digitRunHasASCIIDigit = false
                if byte == UInt8(ascii: "?") {
                    mask |= redactionQueryMask
                    continue
                }
                guard byte == UInt8(ascii: "=") else { continue }
                for entry in redactionKeywords where mask & entry.bit == 0 {
                    if keyword(entry.needle, endsBefore: index, in: bytes) {
                        mask |= entry.bit
                    }
                }
            }
            return mask
        }
    }

    /// Whether `needle` (already lowercase ASCII) occupies the bytes ending just
    /// before `end`. Folds A–Z only — the keys contain `_`, and a blanket
    /// `| 0x20` would map that to `0x7f` and never match.
    ///
    /// A byte ≥ 0x80 inside the window ADMITS rather than rejects, because ICU's
    /// `.caseInsensitive` is full Unicode case folding and this loop cannot
    /// perform it: `toKen=` spelled with U+212A KELVIN SIGN folds to `token=`
    /// and matched the rule while an A–Z fold rejected it (see `redact`). The
    /// closure is sound because a character that folds into an ASCII key is
    /// never SHORTER in UTF-8 than the ASCII it produces, so any such spelling
    /// leaves a byte ≥ 0x80 inside the `needle.count` bytes examined here.
    private static func keyword(
        _ needle: [UInt8],
        endsBefore end: Int,
        in bytes: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        guard end >= needle.count else { return false }
        var cursor = end - 1
        var position = needle.count - 1
        while position >= 0 {
            let byte = bytes[cursor]
            guard byte < 0x80 else { return true }
            let folded = (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ? byte + 32 : byte
            guard folded == needle[position] else { return false }
            cursor -= 1
            position -= 1
        }
        return true
    }
}
