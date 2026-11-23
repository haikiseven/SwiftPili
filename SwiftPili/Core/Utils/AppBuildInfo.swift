import Foundation

struct AppBuildInfo: Sendable {
    let displayName: String
    let version: String?
    let build: String?
    let gitCommit: String?
    let gitDirty: Bool?
    let buildDate: Date?
    let iconNames: [String]
    private let alternateIconFiles: [String: [String]]

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

        let icons = info["CFBundleIcons"] as? [String: Any]
        let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        iconNames = [primaryIcon?["CFBundleIconName"] as? String].compactMap(\.self)
            + ((primaryIcon?["CFBundleIconFiles"] as? [String]) ?? []).reversed()

        var alternates: [String: [String]] = [:]
        if let rawAlternates = icons?["CFBundleAlternateIcons"] as? [String: Any] {
            for (name, value) in rawAlternates {
                guard let dict = value as? [String: Any] else { continue }
                let names = [dict["CFBundleIconName"] as? String].compactMap(\.self)
                    + ((dict["CFBundleIconFiles"] as? [String]) ?? []).reversed()
                alternates[name] = names
            }
        }
        alternateIconFiles = alternates
    }

    func resolvedIconNames(activeAlternateIconName: String?) -> [String] {
        guard let activeAlternateIconName else { return iconNames }
        let activeCandidates = [activeAlternateIconName] + (alternateIconFiles[activeAlternateIconName] ?? [])
        return activeCandidates + iconNames
    }
}
