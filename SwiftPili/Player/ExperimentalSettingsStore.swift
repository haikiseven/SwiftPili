import Foundation
import Observation

@MainActor
@Observable
final class ExperimentalSettingsStore {
    static let shared = ExperimentalSettingsStore()
    private(set) var snapshot = ExperimentalSettingsSnapshot()
    private(set) var storageError: String?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var access: [ExperimentalFeature: ExperimentalAccessReceipt] = [:]
    @ObservationIgnored private var observers: [Observer] = []
    @ObservationIgnored private var autoVerifyID = UUID()
    @ObservationIgnored private var autoVerifyPermit = ExperimentalAccessPermit()

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor (AnyObject, Set<ExperimentalFeature>) -> Void
    }

    private init() {}

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        let record = ExperimentalSettingsPreferences.bootstrap()
        autoVerifyEnabled = UserDefaults.standard.bool(forKey: "comment_check_after_post")
        commentAIFilter = CommentAIFilterPreferences.load()
        videoEnhancementDefaultSRMode = VideoEnhancementPreferences.defaultSRMode
        videoEnhancementDefaultFrameInterpolation = VideoEnhancementPreferences.defaultFrameInterpolationEnabled
        videoEnhancementDefaultRate = VideoEnhancementPreferences.interpolationRate
        videoEnhancementDefaultScale = VideoEnhancementPreferences.superResolutionScale
        videoEnhancementAdaptiveQuality = VideoEnhancementPreferences.adaptiveQualityEnabled
        storageError = record.storageError
        publish(record.snapshot)
    }

    func isAllowed(_ feature: ExperimentalFeature) -> Bool { snapshot.isAllowed(feature) }
    func captureAccess(_ feature: ExperimentalFeature) -> ExperimentalAccessReceipt? {
        guard isAllowed(feature) else { return nil }
        return access[feature]
    }
    func isCurrentAccess(_ receipt: ExperimentalAccessReceipt) -> Bool {
        isAllowed(receipt.feature) && access[receipt.feature] == receipt && receipt.isValid
    }

    func addObserver<Owner: AnyObject>(
        owner: Owner, handler: @escaping @MainActor (Owner, Set<ExperimentalFeature>) -> Void
    ) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: { object, changes in
            guard let owner = object as? Owner else { return }
            handler(owner, changes)
        }))
    }

    @discardableResult
    // swiftlint:disable:next inclusive_language
    func setMasterEnabled(_ enabled: Bool) -> Bool {
        var next = snapshot
        next.masterEnabled = enabled
        return commit(next)
    }

    @discardableResult
    func setGranted(_ granted: Bool, for feature: ExperimentalFeature) -> Bool {
        guard snapshot.masterEnabled else { return false }
        var next = snapshot
        next.grants[feature] = granted
        return commit(next)
    }

    @discardableResult
    func updateDiagnosticOverrides(_ overrides: ExperimentalDiagnosticOverrides) -> Bool {
        guard isAllowed(.diagnostics) else { return false }
        var next = snapshot
        next.diagnosticOverrides = overrides
        return commit(next)
    }

    private(set) var autoVerifyEnabled = false
    private(set) var commentAIFilter = CommentAIFilterConfiguration.default
    private(set) var videoEnhancementDefaultSRMode = VideoEnhancementPreferences.defaultSRMode
    // swiftlint:disable:next identifier_name
    private(set) var videoEnhancementDefaultFrameInterpolation =
        VideoEnhancementPreferences.defaultFrameInterpolationEnabled

    private(set) var videoEnhancementDefaultRate = VideoEnhancementPreferences.interpolationRate
    private(set) var videoEnhancementDefaultScale = VideoEnhancementPreferences.superResolutionScale
    private(set) var videoEnhancementAdaptiveQuality = VideoEnhancementPreferences.adaptiveQualityEnabled

    @discardableResult
    func setVideoEnhancementAdaptiveQuality(_ enabled: Bool) -> Bool {
        guard isAllowed(.videoEnhancement), storageError == nil else { return false }
        guard videoEnhancementAdaptiveQuality != enabled else { return true }
        VideoEnhancementPreferences.adaptiveQualityEnabled = enabled
        videoEnhancementAdaptiveQuality = enabled
        notifyObservers([.videoEnhancement])
        return true
    }

    @discardableResult
    func setVideoEnhancementDefaultSRMode(_ mode: VideoSuperResolutionMode) -> Bool {
        guard isAllowed(.videoEnhancement), storageError == nil else { return false }
        guard videoEnhancementDefaultSRMode != mode else { return true }
        VideoEnhancementPreferences.defaultSRMode = mode
        videoEnhancementDefaultSRMode = mode
        notifyObservers(Set([.videoEnhancement]))
        return true
    }

    @discardableResult
    func setVideoEnhancementDefaultFrameInterpolation(_ enabled: Bool) -> Bool {
        guard isAllowed(.videoEnhancement), storageError == nil else { return false }
        guard videoEnhancementDefaultFrameInterpolation != enabled else { return true }
        VideoEnhancementPreferences.defaultFrameInterpolationEnabled = enabled
        videoEnhancementDefaultFrameInterpolation = enabled
        notifyObservers(Set([.videoEnhancement]))
        return true
    }

    @discardableResult
    func setVideoEnhancementDefaultRate(_ rate: VideoInterpolationRate) -> Bool {
        guard isAllowed(.videoEnhancement), storageError == nil else { return false }
        guard videoEnhancementDefaultRate != rate else { return true }
        VideoEnhancementPreferences.interpolationRate = rate
        videoEnhancementDefaultRate = rate
        notifyObservers([.videoEnhancement])
        return true
    }

    @discardableResult
    func setVideoEnhancementDefaultScale(_ scale: VideoSuperResolutionScale) -> Bool {
        guard isAllowed(.videoEnhancement), storageError == nil else { return false }
        guard videoEnhancementDefaultScale != scale else { return true }
        VideoEnhancementPreferences.superResolutionScale = scale
        videoEnhancementDefaultScale = scale
        notifyObservers([.videoEnhancement])
        return true
    }

    @discardableResult
    func setAutoVerifyEnabled(_ enabled: Bool) -> Bool {
        guard isAllowed(.commentTools), storageError == nil else { return false }
        guard autoVerifyEnabled != enabled else { return true }
        UserDefaults.standard.set(enabled, forKey: "comment_check_after_post")
        autoVerifyEnabled = enabled
        retireAutoVerification()
        return true
    }

    @discardableResult
    func updateCommentAIFilter(_ mutate: (inout CommentAIFilterConfiguration) -> Void) -> Bool {
        guard isAllowed(.aiCommentFilter), storageError == nil else { return false }
        var next = commentAIFilter
        mutate(&next)
        guard next != commentAIFilter else { return true }
        guard CommentAIFilterPreferences.save(next) else { return false }
        commentAIFilter = next
        notifyObservers([.aiCommentFilter])
        return true
    }

    @discardableResult
    func allowCommentAIFilterAuthor(mid: Int, name: String?) -> Bool {
        guard mid > 0 else { return false }
        return updateCommentAIFilter { config in
            config.allowedAuthorMIDs.insert(mid)
            if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                config.allowedAuthorNames[mid] = trimmed
            }
        }
    }

    @discardableResult
    func removeCommentAIFilterAllowedAuthor(mid: Int) -> Bool {
        updateCommentAIFilter { config in
            config.allowedAuthorMIDs.remove(mid)
            config.allowedAuthorNames.removeValue(forKey: mid)
        }
    }

    @discardableResult
    func clearCommentAIFilterAllowlist() -> Bool {
        updateCommentAIFilter { config in
            config.allowedAuthorMIDs.removeAll()
            config.allowedAuthorNames.removeAll()
        }
    }

    func captureAutoVerification() -> ExperimentalAutoVerifyReceipt? {
        guard autoVerifyEnabled, let access = captureAccess(.commentTools) else { return nil }
        return ExperimentalAutoVerifyReceipt(access: access, id: autoVerifyID, permit: autoVerifyPermit)
    }

    func isCurrentAutoVerification(_ receipt: ExperimentalAutoVerifyReceipt) -> Bool {
        autoVerifyEnabled && isCurrentAccess(receipt.access) && receipt.id == autoVerifyID && receipt.isValid
    }

    private func retireAutoVerification() {
        autoVerifyPermit.revoke()
        autoVerifyID = UUID()
        autoVerifyPermit = ExperimentalAccessPermit()
    }

    private func commit(_ next: ExperimentalSettingsSnapshot) -> Bool {
        guard bootstrapped, storageError == nil else { return false }
        guard next != snapshot else { return true }
        guard ExperimentalSettingsPreferences.persist(next) else {
            storageError = String(localized: "Experimental settings could not be saved.")
            return false
        }
        publish(next)
        return true
    }

    private func publish(_ next: ExperimentalSettingsSnapshot) {
        let changed = Set(ExperimentalFeature.allCases.filter { snapshot.isAllowed($0) != next.isAllowed($0) })
        for feature in changed {
            access[feature]?.permit.revoke()
            access[feature] = next.isAllowed(feature)
                ? ExperimentalAccessReceipt(feature: feature, id: UUID(), permit: ExperimentalAccessPermit()) : nil
        }
        if changed.contains(.commentTools) { retireAutoVerification() }
        let overridesChanged = snapshot.diagnosticOverrides != next.diagnosticOverrides
        snapshot = next
        ExperimentalSettingsPolicy.install(next, access: access)
        var notifications = changed
        if overridesChanged { notifications.insert(.diagnostics) }
        if notifications.contains(.diagnostics) { ExperimentalDiagnosticsRuntime.applyPolicy() }
        notifyObservers(notifications)
    }

    private func notifyObservers(_ notifications: Set<ExperimentalFeature>) {
        guard !notifications.isEmpty else { return }
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            if let owner = observer.owner { observer.handler(owner, notifications) }
        }
    }
}
