import Foundation
import os
import Synchronization

/// Cross-queue admission has no UserDefaults/actor/lock work on the audio callback.
enum ExperimentalSettingsPolicy {
    private static let effectiveBits = Atomic<UInt32>(0)
    private struct State {
        var overrides = ExperimentalDiagnosticOverrides.stock
        var access: [ExperimentalFeature: ExperimentalAccessReceipt] = [:]
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func isAllowed(_ feature: ExperimentalFeature) -> Bool {
        effectiveBits.load(ordering: .acquiring) & feature.mask != 0
    }

    static var diagnosticsEnabled: Bool { isAllowed(.diagnostics) }
    static var aiCommentFilterEnabled: Bool { isAllowed(.aiCommentFilter) }
    static var videoEnhancementEnabled: Bool { isAllowed(.videoEnhancement) }
    static var diagnosticOverrides: ExperimentalDiagnosticOverrides {
        guard diagnosticsEnabled else { return .stock }
        return state.withLock {
            $0.access[.diagnostics]?.isValid == true ? $0.overrides : .stock
        }
    }

    /// Non-real-time admission only. Capture once and read its atomic validity on callbacks.
    static func captureAccess(_ feature: ExperimentalFeature) -> ExperimentalAccessReceipt? {
        guard isAllowed(feature) else { return nil }
        return state.withLock { value in
            guard let receipt = value.access[feature], receipt.isValid else { return nil }
            return receipt
        }
    }

    static func capturePermit(_ feature: ExperimentalFeature) -> ExperimentalAccessPermit? {
        captureAccess(feature)?.permit
    }

    /// NSArgumentDomain is a launch override, never a second persistent authority.
    static func diagnosticBool(
        key: String, saved: Bool, defaults: UserDefaults = .standard
    ) -> Bool {
        guard diagnosticsEnabled else { return true }
        guard defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil else { return saved }
        return PlayerDefaultBool.resolve(key: key, defaultValue: saved, defaults: defaults)
    }

    @MainActor
    static func install(
        _ snapshot: ExperimentalSettingsSnapshot, access: [ExperimentalFeature: ExperimentalAccessReceipt]
    ) {
        state.withLock {
            $0.overrides = snapshot.diagnosticOverrides
            $0.access = access
        }
        effectiveBits.store(snapshot.effectiveMask, ordering: .releasing)
    }
}

/// Revocation is irreversible: toggling OFF then ON never revives an old request.
final class ExperimentalAccessPermit: Sendable {
    private let revoked = Atomic<Bool>(false)
    var isValid: Bool { !revoked.load(ordering: .acquiring) }
    func revoke() { revoked.store(true, ordering: .releasing) }
}

struct ExperimentalAccessReceipt: Equatable, Sendable {
    let feature: ExperimentalFeature
    let id: UUID
    let permit: ExperimentalAccessPermit

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.feature == rhs.feature && lhs.id == rhs.id }
    var isValid: Bool { permit.isValid }
}

struct ExperimentalAutoVerifyReceipt: Equatable, Sendable {
    let access: ExperimentalAccessReceipt
    let id: UUID
    let permit: ExperimentalAccessPermit
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.access == rhs.access && lhs.id == rhs.id }
    var isValid: Bool { access.isValid && permit.isValid }
}
