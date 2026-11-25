import Foundation
import os
import Synchronization

enum PlayerLog {
    static let subsystem = "com.swiftpili.app"
    private static let logger = Logger(subsystem: subsystem, category: "Player")

    static let diagnosticCategory = "Diagnostic"
    private static let diagnosticLogger = Logger(subsystem: subsystem, category: diagnosticCategory)

    #if DEBUG
    private static let sink = DispatchQueue(label: "com.swiftpili.playerlog", qos: .utility)
    #endif

    private static let consoleEnabled = Atomic<Bool>(false)

    static var isEnabled: Bool {
        get { ExperimentalSettingsPolicy.diagnosticsEnabled && consoleEnabled.load(ordering: .acquiring) }
        set { consoleEnabled.store(newValue && ExperimentalSettingsPolicy.diagnosticsEnabled, ordering: .releasing) }
    }

    @MainActor
    static func setEnabled(_ enabled: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        UserDefaults.standard.set(enabled, forKey: "debug_logging_enabled")
        isEnabled = enabled
    }

    @MainActor
    static func applyExperimentalPolicy(activateCollectors _: Bool = true) {
        isEnabled = UserDefaults.standard.bool(forKey: "debug_logging_enabled") || debugRequestedAtLaunch
    }

    nonisolated static let debugRequestedAtLaunch: Bool = {
        let info = ProcessInfo.processInfo
        return info.environment["PLAYER_DEBUG"] == "1"
            || info.arguments.contains("-player-debug")
            || info.arguments.contains("player-debug=1")
    }()

    static var isCapturing: Bool { isEnabled }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled,
              let access = ExperimentalSettingsPolicy.captureAccess(.diagnostics) else { return }
        let msg = redact(message())
        guard access.isValid else { return }
        #if DEBUG
        sink.async {
            guard access.isValid, isEnabled else { return }
            print(msg)
        }
        #endif
        logger.log("\(msg, privacy: .public)")
    }

    static func diagnostic(_ message: @autoclosure () -> String) {
        let msg = redact(message())
        #if DEBUG
        sink.async { print("⚠️ \(msg)") }
        #endif
        diagnosticLogger.error("\(msg, privacy: .public)")
    }

    private struct RedactionRule {
        enum Gate {
            case query
            case phoneRun
            case keyword([UInt8])

            var isQuery: Bool { if case .query = self { true } else { false } }
            var isPhoneRun: Bool { if case .phoneRun = self { true } else { false } }
        }

        let gate: Gate
        let regex: NSRegularExpression
        let template: String
    }

    private static let redactionRules: [RedactionRule] = {
        var rules: [RedactionRule] = []
        rules.append(RedactionRule(
            gate: .query,
            regex: try! NSRegularExpression(pattern: #"(https?://[^\s\"']+)\?[^\s\"']+"#),
            template: "$1?<redacted>"
        ))
        rules.append(RedactionRule(
            gate: .phoneRun,
            regex: try! NSRegularExpression(pattern: #"\b1[3-9]\d{9}\b"#),
            template: "<phone>"
        ))
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

    private static let redactionQueryMask: UInt32 = ruleMask { $0.gate.isQuery }
    private static let redactionPhoneMask: UInt32 = ruleMask { $0.gate.isPhoneRun }

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

    private static func redactionAdmissions(_ raw: String) -> UInt32 {
        var subject = raw
        return subject.withUTF8 { bytes -> UInt32 in
            var mask: UInt32 = 0
            var digitRun = 0
            var digitRunHasASCIIDigit = false
            for index in 0..<bytes.count {
                let byte = bytes[index]
                let isASCIIDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
                if isASCIIDigit || byte >= 0x80 {
                    digitRun += 1
                    if isASCIIDigit { digitRunHasASCIIDigit = true }
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
