import CoreGraphics
import Foundation

enum ImagePipelinePolicy {
    // MARK: - Arm C: diagnostics suppression

    static let suppressDiagnosticsKey = "image_ab_suppress_diagnostics"

    nonisolated(unsafe) static var suppressesDiagnostics: Bool = false

    static var emitsImageDiagnostics: Bool { !suppressesDiagnostics }

    // MARK: - Arm D: stabilised request geometry

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

    // MARK: - Arm E: async decode / disk path

    static let asyncDecodeKey = "image_ab_async_decode"

    nonisolated(unsafe) static var usesAsyncCacheTypeCheck: Bool = true

    // MARK: - Arm F: appearance transition

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

    // MARK: - Arm G: split layout probes

    static let splitLayoutProbesKey = "image_ab_split_layout_probes"

    nonisolated(unsafe) static var splitsLayoutProbes: Bool = false

    static func installsCoverGeometryProbes(
        armed: Bool,
        capturing: Bool,
        splitArm: Bool
    ) -> Bool {
        guard armed else { return false }
        return capturing || splitArm
    }

    static var installsCoverGeometryProbes: Bool {
        installsCoverGeometryProbes(
            armed: ImageDiagnostics.isRecordingImageEvents,
            capturing: PlayerLog.isCapturing,
            splitArm: splitsLayoutProbes
        )
    }

    // MARK: - Settings entry points

    @MainActor
    @discardableResult
    static func applyExperimentalPolicy() -> Bool {
        let allowed = ExperimentalSettingsPolicy.isAllowed(.diagnostics)
        let defaults = UserDefaults.standard
        let previousAsync = usesAsyncCacheTypeCheck
        let previousTransition = usesInstantTransition
        suppressesDiagnostics = allowed && defaults.bool(forKey: suppressDiagnosticsKey)
        usesStableRequestGeometry = allowed && defaults.bool(forKey: stableRequestGeometryKey)
        usesAsyncCacheTypeCheck = !allowed || (defaults.object(forKey: asyncDecodeKey) as? Bool ?? true)
        usesInstantTransition = !allowed || (defaults.object(forKey: instantTransitionKey) as? Bool ?? true)
        splitsLayoutProbes = allowed && defaults.bool(forKey: splitLayoutProbesKey)
        return previousAsync != usesAsyncCacheTypeCheck || previousTransition != usesInstantTransition
    }

    @MainActor
    private static func setArm(_ enabled: Bool, key: String) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        UserDefaults.standard.set(enabled, forKey: key)
        if applyExperimentalPolicy() { CacheManager.apply() }
    }

    @MainActor
    static func setSuppressesDiagnostics(_ on: Bool) { setArm(on, key: suppressDiagnosticsKey) }

    @MainActor
    static func setUsesStableRequestGeometry(_ on: Bool) { setArm(on, key: stableRequestGeometryKey) }

    @MainActor
    static func setUsesAsyncCacheTypeCheck(_ on: Bool) { setArm(on, key: asyncDecodeKey) }

    @MainActor
    static func setUsesInstantTransition(_ on: Bool) { setArm(on, key: instantTransitionKey) }

    @MainActor
    static func setSplitsLayoutProbes(_ on: Bool) { setArm(on, key: splitLayoutProbesKey) }

    static func armSummary(
        staticIndicator: Bool,
        suppressDiagnostics: Bool,
        stableGeometry: Bool,
        asyncCacheTypeCheck: Bool,
        instantTransition: Bool,
        splitLayoutProbes: Bool
    ) -> String {
        var arms: [String] = []
        if staticIndicator { arms.append("B:static-indicator") }
        if suppressDiagnostics { arms.append("C:diagnostics-off") }
        if stableGeometry { arms.append("D:stable-geometry") }
        if !asyncCacheTypeCheck { arms.append("E:sync-disk-decode") }
        if instantTransition { arms.append("F:instant-transition") }
        if splitLayoutProbes { arms.append("G:split-layout-probes") }
        return arms.isEmpty ? "-" : arms.joined(separator: ",")
    }

    static var activeArmSummary: String {
        armSummary(
            staticIndicator: ImageLoadingIndicatorPolicy.isStatic,
            suppressDiagnostics: suppressesDiagnostics,
            stableGeometry: usesStableRequestGeometry,
            asyncCacheTypeCheck: usesAsyncCacheTypeCheck,
            instantTransition: usesInstantTransition,
            splitLayoutProbes: splitsLayoutProbes
        )
    }
}
