import SwiftUI

private struct AuthManagerKey: EnvironmentKey {
    static let defaultValue: AuthManager = .shared
}

private struct AccountManagerKey: EnvironmentKey {
    static var defaultValue: AccountManager {
        MainActor.assumeIsolated { .shared }
    }
}

private struct AccentStoreKey: EnvironmentKey {
    static var defaultValue: AccentStore {
        MainActor.assumeIsolated { .shared }
    }
}

private struct BlocklistManagerKey: EnvironmentKey {
    static var defaultValue: BlocklistManager {
        MainActor.assumeIsolated { .shared }
    }
}

private struct DownloadManagerKey: EnvironmentKey {
    static var defaultValue: DownloadManager {
        MainActor.assumeIsolated { .shared }
    }
}

extension EnvironmentValues {
    var authManager: AuthManager {
        get { self[AuthManagerKey.self] }
        set { self[AuthManagerKey.self] = newValue }
    }

    var accountManager: AccountManager {
        get { self[AccountManagerKey.self] }
        set { self[AccountManagerKey.self] = newValue }
    }

    var accentStore: AccentStore {
        get { self[AccentStoreKey.self] }
        set { self[AccentStoreKey.self] = newValue }
    }

    var blocklistManager: BlocklistManager {
        get { self[BlocklistManagerKey.self] }
        set { self[BlocklistManagerKey.self] = newValue }
    }

    var downloadManager: DownloadManager {
        get { self[DownloadManagerKey.self] }
        set { self[DownloadManagerKey.self] = newValue }
    }
}
