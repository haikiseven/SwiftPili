import Foundation

/// Opt-in VOD policy. Process switches only recognize the exact rollback value.
enum MultiConnectionFeatureGate {
    static let defaultsKey = "multi_connection_enabled"
    /// Separate opt-in for expensive paths (cellular, personal hotspot); default OFF.
    /// The main switch still gates everything.
    static let cellularDefaultsKey = "multi_connection_cellular_enabled"
    static let environmentKey = "PATHA_MULTI_CONNECTION"
    static let processEnvironment = ProcessInfo.processInfo.environment

    static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = processEnvironment
    ) -> Bool {
        ExperimentalSettingsPolicy.isAllowed(.multiConnection)
            && defaults.bool(forKey: defaultsKey)
            && processEnabled(environment: environment)
    }

    static func processEnabled(environment: [String: String] = processEnvironment) -> Bool {
        let helperPermitted = !ExperimentalSettingsPolicy.isAllowed(.multiConnection)
            || environment[environmentKey] != "0"
        let storePermitted = !ExperimentalSettingsPolicy.diagnosticsEnabled || environment["PATHA_BYTE_CACHE"] != "0"
        return helperPermitted && storePermitted
    }

    static func cellularEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: cellularDefaultsKey)
    }
}
