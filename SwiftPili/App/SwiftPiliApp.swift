import SwiftUI
import SwiftData

@main
struct SwiftPiliApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer?
    private let isRunningUnitTests: Bool

    init() {
        let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.isRunningUnitTests = runningTests
        guard !runningTests else {
            self.modelContainer = nil
            return
        }
        ExperimentalSettingsStore.shared.bootstrap()
        ExperimentalDiagnosticsRuntime.applyPolicy()
        BuvidManager.ensureBuvid()
        CacheManager.apply()
        DownloadExportCoordinator.shared.configure(native: NativeMediaExportBackend())
        PlayerPlaybackPreferences.clearDebugOnlyPlaybackExperiments()
        do {
            modelContainer = try AppStorageContainer.makeModelContainer()
        } catch {
            fatalError("Failed to create the model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if isRunningUnitTests {
                Color.clear
            } else if let modelContainer {
                AppSceneRootView(modelContainer: modelContainer)
            }
        }
    }
}

@MainActor
private enum AppProcessBootstrap {
    private static var hasStarted = false

    static func runIfNeeded(modelContainer: ModelContainer) {
        guard !hasStarted else { return }
        hasStarted = true
        ExperimentalDiagnosticsRuntime.activateScene()
        KeyboardAnimation.beginObserving()
        HangDiagnosticsReporter.start()
        DownloadManager.shared.container = modelContainer
        OfflineProgressStore.shared.container = modelContainer

        let allowDecoderPrewarm = ExperimentalSettingsPolicy.isAllowed(.decoderPrewarm)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(600))
            CacheManager.cleanExpiredDiskCache()
            if allowDecoderPrewarm {
                VideoHardwareCapabilities.prewarm()
            }
            await MainActor.run {
                PlayerViewModel.prewarmPlaybackEngine()
                SmartCDNSelector.shared.launch()
            }
            await BuvidManager.syncServerBuvid()
            await BuvidManager.activateBuvid()
        }
    }
}

private struct AppSceneRootView: View {
    let modelContainer: ModelContainer
    @State private var sceneID = UUID()
    @State private var coordinator = AppCoordinator()
    @State private var noticeCenter = AppNoticeCenter()

    var body: some View {
        RootView()
            .id(AccountManager.shared.identityRevision)
            .environment(\.appSceneID, sceneID)
            .environment(coordinator)
            .environment(noticeCenter)
            .environment(\.appNoticeCenter, noticeCenter)
            .environment(\.authManager, AuthManager.shared)
            .environment(\.accountManager, AccountManager.shared)
            .environment(\.accentStore, AccentStore.shared)
            .environment(\.blocklistManager, BlocklistManager.shared)
            .environment(\.downloadManager, DownloadManager.shared)
            .modelContainer(modelContainer)
            .onChange(of: AccountManager.shared.identityRevision) { _, _ in
                HomeFeedSnapshotStore.shared.clear()
                coordinator.resetForAccountChange()
            }
            .task {
                AppProcessBootstrap.runIfNeeded(modelContainer: modelContainer)
            }
            .task(id: AccountManager.shared.identityRevision) {
                await BlocklistManager.shared.loadIfNeeded()
            }
    }
}
