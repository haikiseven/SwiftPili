import Foundation

struct AppBuildInfo: Sendable {
    let displayName: String
    let version: String?
    let build: String?
    let gitCommit: String?
    let gitDirty: Bool?
    let buildDate: Date?
    let iconNames: [String]

    static let current = AppBuildInfo(info: Bundle.main.infoDictionary ?? [:])

    private init(info: [String: Any]) {
        displayName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? "SwiftPili"
        version = info["CFBundleShortVersionString"] as? String
        build = info["CFBundleVersion"] as? String

        let commit = info["SPBuildGitCommit"] as? String
        gitCommit = (commit?.isEmpty == false && commit != "unknown") ? commit : nil
        gitDirty = gitCommit == nil ? nil : info["SPBuildGitDirty"] as? Bool
        buildDate = (info["SPBuildDate"] as? String).flatMap {
            try? Date($0, strategy: .iso8601)
        }

        let primaryIcon = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"]
            as? [String: Any]
        iconNames = [primaryIcon?["CFBundleIconName"] as? String].compactMap(\.self)
            + ((primaryIcon?["CFBundleIconFiles"] as? [String]) ?? []).reversed()
    }
}
