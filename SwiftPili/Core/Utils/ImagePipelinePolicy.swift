import CoreGraphics
import Foundation

enum ImagePipelinePolicy {
    // MARK: - Stabilised request geometry

    static let stableRequestGeometryKey = "image_ab_stable_geometry"

    nonisolated(unsafe) static var usesStableRequestGeometry: Bool = false

    static let requestBoxQuantum: CGFloat = 16

    static func quantizedRequestBox(_ box: CGSize) -> CGSize {
        guard usesStableRequestGeometry,
              box.width.isFinite, box.height.isFinite,
              box.width > 1, box.height > 1
        else { return box }
        let width = (box.width / requestBoxQuantum).rounded(.up) * requestBoxQuantum
        let height = max(box.height.rounded(.up), (box.height * (width / box.width)).rounded())
        return CGSize(width: width, height: height)
    }

    // MARK: - Async decode / disk path

    static let asyncDecodeKey = "image_ab_async_decode"

    nonisolated(unsafe) static var usesAsyncCacheTypeCheck: Bool = true

    // MARK: - Appearance transition

    static let instantTransitionKey = "image_ab_instant_transition"

    nonisolated(unsafe) static var usesInstantTransition: Bool = true

    static let networkFadeSeconds: TimeInterval = 0.12

    static func fadeSeconds(reduceMotion: Bool, instantArm: Bool) -> TimeInterval? {
        if reduceMotion || instantArm { return nil }
        return networkFadeSeconds
    }

    static func fadeSeconds(reduceMotion: Bool) -> TimeInterval? {
        fadeSeconds(reduceMotion: reduceMotion, instantArm: usesInstantTransition)
    }

    // MARK: - Settings entry points

    @MainActor
    @discardableResult
    static func applyExperimentalPolicy() -> Bool {
        let allowed = ExperimentalSettingsPolicy.isAllowed(.diagnostics)
        let defaults = UserDefaults.standard
        let previousAsync = usesAsyncCacheTypeCheck
        let previousTransition = usesInstantTransition
        usesStableRequestGeometry = allowed && defaults.bool(forKey: stableRequestGeometryKey)
        usesAsyncCacheTypeCheck = !allowed || (defaults.object(forKey: asyncDecodeKey) as? Bool ?? true)
        usesInstantTransition = !allowed || (defaults.object(forKey: instantTransitionKey) as? Bool ?? true)
        return previousAsync != usesAsyncCacheTypeCheck || previousTransition != usesInstantTransition
    }
}
