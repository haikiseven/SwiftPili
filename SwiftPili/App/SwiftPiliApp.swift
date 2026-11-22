import SwiftUI
import SwiftData

@main
struct SwiftPiliApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = AppCoordinator()
    private let modelContainer: ModelContainer

    init() {
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
            RootView()
                .environment(coordinator)
                .modelContainer(modelContainer)
                .task {
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
                .task(id: AccountManager.shared.identityRevision) {
                    await BlocklistManager.shared.loadIfNeeded()
                }
        }
    }
}
