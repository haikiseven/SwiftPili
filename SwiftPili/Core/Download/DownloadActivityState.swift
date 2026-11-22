import Observation

/// One row store, with a changed-only eligibility edge for the root accessory.
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
