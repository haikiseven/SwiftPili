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
        CacheManager.performLaunchCleanup()
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

    static func runIfNeeded(modelContainer: ModelContainer) async {
        guard !hasStarted else { return }
        hasStarted = true
        MainThreadIdentity.adopt()
        ExperimentalDiagnosticsRuntime.activateScene()
        ExperimentalDiagnosticsRuntime.applyPolicy()
        ImageDiagnostics.applyLaunchState()
        KeyboardAnimation.beginObserving()
        HangDiagnosticsReporter.start()
        DownloadManager.shared.container = modelContainer
        OfflineProgressStore.shared.container = modelContainer
        ExperimentalDiagnosticsRuntime.applyPolicy()
        if ExperimentalSettingsPolicy.isAllowed(.decoderPrewarm) {
            VideoHardwareCapabilities.prewarm()
        }
        PlayerViewModel.prewarmPlaybackEngine()
        SmartCDNSelector.shared.launch()
        await BuvidManager.syncServerBuvid()
        await BuvidManager.activateBuvid()
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
                coordinator.resetForAccountChange()
            }
            .task {
                await AppProcessBootstrap.runIfNeeded(modelContainer: modelContainer)
            }
            .task(id: AccountManager.shared.identityRevision) {
                await BlocklistManager.shared.loadIfNeeded()
            }
    }
}
