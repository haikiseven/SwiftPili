import QuartzCore

enum PerfLog {
    @MainActor private static var seen = Set<String>()

    @MainActor static func firstTime(_ label: String) {
        guard PlayerLog.isEnabled else { return }
        guard seen.insert(label).inserted else { return }
        PlayerLog.log("[Perf] first \(label) (t=\(String(format: "%.2f", CACurrentMediaTime())))")
    }
}
