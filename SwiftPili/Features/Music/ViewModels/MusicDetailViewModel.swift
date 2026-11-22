import Foundation
import Observation

@MainActor
@Observable
final class MusicDetailViewModel {
    let reference: MusicReference
    private(set) var detail: MusicDetail?
    private(set) var isLoading = false
    private(set) var hasAttemptedLoad = false
    private(set) var failure: String?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var requestTask: Task<MusicDetail, any Error>?

    init(reference: MusicReference) {
        self.reference = reference
    }

    func load() async {
        guard !Task.isCancelled, !isLoading, detail == nil else { return }
        let identifier = UUID()
        requestID = identifier
        hasAttemptedLoad = true
        isLoading = true
        failure = nil
        let musicID = reference.musicID
        let task = Task { try await MusicAPI.detail(musicID: musicID) }
        requestTask = task
        defer {
            if requestID == identifier {
                requestID = nil
                requestTask = nil
                isLoading = false
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled, requestID == identifier else { return }
            detail = result
        } catch {
            guard !Task.isCancelled, requestID == identifier,
                  !(error is CancellationError), (error as? BiliError)?.isCancellation != true else { return }
            failure = error.localizedDescription
        }
    }

    func cancel() {
        requestID = nil
        requestTask?.cancel()
        requestTask = nil
        isLoading = false
    }
}
