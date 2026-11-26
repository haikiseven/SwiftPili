import Foundation

enum MultiConnectionFeatureGate {
    static let defaultsKey = "multi_connection_enabled"
    static let cellularDefaultsKey = "multi_connection_cellular_enabled"
    static let environmentKey = "PATHA_MULTI_CONNECTION"
    static let processEnvironment = ProcessInfo.processInfo.environment

    static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = processEnvironment
    ) -> Bool {
        defaults.bool(forKey: defaultsKey)
            && processEnabled(environment: environment)
    }

    static func processEnabled(environment: [String: String] = processEnvironment) -> Bool {
        let helperPermitted = environment[environmentKey] != "0"
        let storePermitted = !ExperimentalSettingsPolicy.diagnosticsEnabled || environment["PATHA_BYTE_CACHE"] != "0"
        return helperPermitted && storePermitted
    }

    static func cellularEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: cellularDefaultsKey)
    }
}
