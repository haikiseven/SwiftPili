import QuartzCore

/// One-shot "first time this happened" markers for placing cold-path costs on
/// the launch timeline behind the Debug Logging gate.
enum PerfLog {
    @MainActor private static var seen = Set<String>()

    @MainActor static func firstTime(_ label: String) {
        guard PlayerLog.isEnabled else { return }
        guard seen.insert(label).inserted else { return }
        PlayerLog.log("[Perf] first \(label) (t=\(String(format: "%.2f", CACurrentMediaTime())))")
    }
}
