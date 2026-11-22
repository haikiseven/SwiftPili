import SwiftUI
import SwiftData

@main
struct SwiftPiliApp: App {
    // Answers the scene's supported-orientation query from AppOrientation
    // (portrait browsing / landscape fullscreen on iPhone).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = AppCoordinator()
    // Explicit container so DownloadManager can share its main context with
    // the DownloadsView @Query (both must be the same store).
    private let modelContainer: ModelContainer

    init() {
        ExperimentalSettingsStore.shared.bootstrap()
        ExperimentalDiagnosticsRuntime.applyPolicy()
        BuvidManager.ensureBuvid()
        CacheManager.performLaunchCleanup()
        DownloadExportCoordinator.shared.configure(native: NativeMediaExportBackend())
        // Before any backend exists — `--avsb-pitch-engine` is a libVLC
        // INSTANCE argument, so a later reset would not apply until the next
        // launch.
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
                    // Main-thread identity, and it must be taken FROM the main
                    // thread — there is no way to ask for it later. It names the
                    // main thread (so `[Power]`/`[Freeze]` print `main:99%`
                    // instead of the `unnamed:99%` every archived report shows),
                    // records the pthread handle the freeze sampler signals, and
                    // records the Mach port the thread census compares against.
                    // Outside the DEBUG gate below on purpose: the name and the
                    // census identity are worth having on a Release build too.
                    MainThreadIdentity.adopt()
                    ExperimentalDiagnosticsRuntime.activateScene()
                    // Freeze detection from OUTSIDE the main thread: sees a
                    // freeze while it is still happening, records the full
                    // snapshot from the watchdog queue, and leaves a durable
                    // marker so a force-quit during the freeze still yields an
                    // event. `start()` is inert outside DEBUG — its 10Hz
                    // queue/main round-trip is pure wasted wakeups in Release
                    // and skews any Energy Log baseline taken on a production
                    // build. MetricKit below stays supplementary: it is the
                    // only thing that can name the blocked frames, and it is
                    // also the one that is missing under a debugger.
                    ExperimentalDiagnosticsRuntime.applyPolicy()
                    // Re-arm the image-scroll counters if the toggle survived
                    // a relaunch. Not in `init()`: it starts a CADisplayLink,
                    // which wants a live scene.
                    ImageDiagnostics.applyLaunchState()
                    // Learn the keyboard's real duration and curve, so anything
                    // raised alongside it animates on the same one. Cheap and
                    // passive: two notification observers that record two
                    // numbers.
                    KeyboardAnimation.beginObserving()
                    // Hang forensics (Release included): MetricKit delivers
                    // the main-thread call stack of any UI freeze — the one
                    // signal the in-process monitors above cannot capture.
                    HangDiagnosticsReporter.start()
                    // Share the store with the downloads manager (its writes
                    // must land in the same context the DownloadsView queries).
                    DownloadManager.shared.container = modelContainer
                    // Same store, same reason: the offline resume point the
                    // player writes has to land in the context DownloadsView
                    // queries, or its rows show a position playback has left.
                    OfflineProgressStore.shared.container = modelContainer
                    ExperimentalDiagnosticsRuntime.applyPolicy()
                    // Loads VideoToolbox's decoder registry off-main so
                    // the first video's capability checks don't pay it
                    // (observed 3.9s main-thread hang on first loadVOD).
                    if ExperimentalSettingsPolicy.isAllowed(.decoderPrewarm) {
                        VideoHardwareCapabilities.prewarm()
                    }
                    // Same idea, different cost: builds the libVLC instance
                    // (one-time plugin/decoder bank + the avsamplebuffer aout)
                    // off-main NOW, instead of on the main actor inside the
                    // first video's measured startup window.
                    PlayerViewModel.prewarmPlaybackEngine()
                    // Smart CDN: start network-change monitoring, apply
                    // last session's seed host synchronously, and (if the
                    // toggle is on) kick the silent background node sweep.
                    // AHEAD of the awaits below — the seed exists so the
                    // FIRST video doesn't miss, and it must not queue
                    // behind the buvid round-trips and up to 20 paginated
                    // blocklist GETs. Needs nothing from them: the sweep's
                    // zone/geo lookups are plain GETs, and the placeholder
                    // buvid cookie is already set in init().
                    SmartCDNSelector.shared.launch()
                    // Trade the generated placeholder buvid for a real
                    // server-issued one before fingerprint activation.
                    await BuvidManager.syncServerBuvid()
                    await BuvidManager.activateBuvid()
                }
                .task(id: AccountManager.shared.identityRevision) {
                    await BlocklistManager.shared.loadIfNeeded()
                }
        }
    }
}
