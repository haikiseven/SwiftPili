import Foundation

/// The rollback boundary for VOD danmaku.
///
/// Default off. A caller that sees `false` must not create a segment store, an
/// overlay, or a timeline sink, so a disabled switch cannot touch playback.
enum DanmakuFeatureGate {
    static let defaultsKey = "danmaku_enabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}
