import Foundation
import MetricKit

final class HangDiagnosticsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static func start() {
        _ = shared
    }

    private static let shared: HangDiagnosticsReporter = {
        let reporter = HangDiagnosticsReporter()
        MXMetricManager.shared.add(reporter)
        return reporter
    }()

    private nonisolated(unsafe) static let stampFormatter = ISO8601DateFormatter()

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for hang in payload.hangDiagnostics ?? [] {
                report(hang, begin: payload.timeStampBegin, end: payload.timeStampEnd)
            }
            for crash in payload.crashDiagnostics ?? [] {
                report(crash, begin: payload.timeStampBegin, end: payload.timeStampEnd)
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exitMetric = payload.applicationExitMetrics else { continue }
            reportAppExit(exitMetric, begin: payload.timeStampBegin, end: payload.timeStampEnd)
        }
    }

    private func report(_ hang: MXHangDiagnostic, begin: Date, end: Date) {
        let seconds = hang.hangDuration.converted(to: .seconds).value
        let meta = hang.metaData
        var lines: [String] = []
        lines.append(
            "[HangReport] main thread hung \(String(format: "%.2f", seconds))s " +
                "(payload window \(Self.stampFormatter.string(from: begin)) → " +
                "\(Self.stampFormatter.string(from: end)), " +
                "os \(meta.osVersion), build \(meta.applicationBuildVersion))"
        )

        let frames = HangCallStackParser.attributedThreadFrames(
            fromJSON: hang.callStackTree.jsonRepresentation()
        )
        lines.append(contentsOf: Self.frameLines(prefix: "[HangReport]", frames: frames))

        for line in lines {
            PlayerLog.diagnostic(line)
        }
        HangReportStore.shared.append(text: PlayerLog.redact(lines.joined(separator: "\n")))
    }

    private func report(_ crash: MXCrashDiagnostic, begin: Date, end: Date) {
        let meta = crash.metaData
        var lines: [String] = []
        lines.append(
            "[CrashReport] app crashed (payload window \(Self.stampFormatter.string(from: begin)) → " +
                "\(Self.stampFormatter.string(from: end)), " +
                "os \(meta.osVersion), build \(meta.applicationBuildVersion))"
        )
        lines.append("[CrashReport] exceptionType \(Self.describe(crash.exceptionType))")
        lines.append("[CrashReport] exceptionCode \(Self.describe(crash.exceptionCode))")
        lines.append("[CrashReport] signal \(Self.describe(crash.signal))")
        lines.append("[CrashReport] terminationReason \(Self.describe(crash.terminationReason))")
        lines.append(
            "[CrashReport] virtualMemoryRegionInfo \(Self.describe(crash.virtualMemoryRegionInfo))"
        )

        let frames = HangCallStackParser.attributedThreadFrames(
            fromJSON: crash.callStackTree.jsonRepresentation()
        )
        lines.append(contentsOf: Self.frameLines(prefix: "[CrashReport]", frames: frames))

        for line in lines {
            PlayerLog.diagnostic(line)
        }
        HangReportStore.shared.append(text: PlayerLog.redact(lines.joined(separator: "\n")))
    }

    private func reportAppExit(_ metric: MXAppExitMetric, begin: Date, end: Date) {
        let fg = metric.foregroundExitData
        var lines: [String] = []
        lines.append(
            "[ExitReport] foreground exit counts (payload window " +
                "\(Self.stampFormatter.string(from: begin)) → " +
                "\(Self.stampFormatter.string(from: end)))"
        )
        lines.append("[ExitReport] normal \(fg.cumulativeNormalAppExitCount)")
        lines.append("[ExitReport] abnormal \(fg.cumulativeAbnormalExitCount)")
        lines.append("[ExitReport] watchdog \(fg.cumulativeAppWatchdogExitCount)")
        lines.append(
            "[ExitReport] memoryResourceLimit \(fg.cumulativeMemoryResourceLimitExitCount)"
        )
        lines.append("[ExitReport] badAccess \(fg.cumulativeBadAccessExitCount)")
        lines.append("[ExitReport] illegalInstruction \(fg.cumulativeIllegalInstructionExitCount)")

        for line in lines {
            PlayerLog.diagnostic(line)
        }
        HangReportStore.shared.append(text: PlayerLog.redact(lines.joined(separator: "\n")))
    }

    private static func frameLines(prefix: String, frames: [HangCallStackParser.Frame]) -> [String] {
        guard !frames.isEmpty else {
            return ["\(prefix) payload carried no attributed call stack"]
        }
        var lines: [String] = []
        for (index, frame) in frames.reversed().enumerated() {
            lines.append(
                "\(prefix) #\(index) \(frame.binaryName) + " +
                    "0x\(String(frame.offsetIntoBinaryTextSegment, radix: 16))"
            )
        }
        var listed = Set<String>()
        for frame in frames where listed.insert(frame.binaryName).inserted {
            lines.append("\(prefix) binary \(frame.binaryName) uuid \(frame.binaryUUID)")
        }
        return lines
    }

    private static func describe(_ value: NSNumber?) -> String {
        guard let value else { return "absent" }
        return value.stringValue
    }

    private static func describe(_ value: String?) -> String {
        value ?? "absent"
    }
}
