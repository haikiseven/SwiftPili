import Observation

@MainActor
@Observable
final class DownloadActivityState {
    var active: [DownloadManager.ActiveDownload] = [] {
        didSet {
            let hasInFlight = active.contains { !$0.phase.isResumable }
            if hasInFlightDownloads != hasInFlight {
                hasInFlightDownloads = hasInFlight
            }
            let hasRunning = active.contains { $0.phase.isActivelyRunning }
            if hasRunningDownloads != hasRunning {
                hasRunningDownloads = hasRunning
            }
        }
    }

    private(set) var hasInFlightDownloads = false
    private(set) var hasRunningDownloads = false
}
