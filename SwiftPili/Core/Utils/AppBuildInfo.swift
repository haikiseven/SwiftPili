import Foundation

/// The identity of the running build, read from the app's Info.plist.
///
/// `version`/`build` are the standard bundle keys. The git commit, dirty flag
/// and build date are written into the BUILT Info.plist by
/// `scripts/embed-build-info.sh` (the "Embed Build Info" run-script phase in
/// project.yml); a build made without that phase — `swift build` through
/// Package.swift, or git missing on the build host — leaves them `nil`, which
/// the UI shows as unknown rather than inventing a value.
struct AppBuildInfo: Sendable {
    let displayName: String
    let version: String?
    let build: String?
    let gitCommit: String?
    /// `true` when tracked files differed from `gitCommit` at build time.
    let gitDirty: Bool?
    let buildDate: Date?
    /// Names under which the primary home-screen icon can be loaded, from
    /// `CFBundleIcons`: the asset-catalog icon name, then the generated files.
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
