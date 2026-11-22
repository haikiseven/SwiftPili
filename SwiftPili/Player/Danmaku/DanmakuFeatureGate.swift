import Foundation

enum DanmakuFeatureGate {
    static let defaultsKey = "danmaku_enabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}
