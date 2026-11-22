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
        }
    }

    private(set) var hasInFlightDownloads = false
}
