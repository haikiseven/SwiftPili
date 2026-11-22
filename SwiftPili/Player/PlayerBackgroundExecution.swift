import Foundation
import UIKit

/// A finite UIKit assertion for one current playback restoration. This owns
/// execution time only; playback intent and recovery budgets remain in the App.
@MainActor
final class PlayerBackgroundExecution {
    struct Key: Equatable {
        let owner: PlayerOwnerLease
        let recoveryBudget: UUID
    }

    private struct Request {
        let id: UUID
        let key: Key
        var task: UIBackgroundTaskIdentifier = .invalid
        let expiration: @MainActor (UUID) -> Void
    }

    private var request: Request?
    private var refusedKey: Key?
    private var expiredRequestID: UUID?
    private struct Progress {
        let backend: ObjectIdentifier
        let generation: UInt64
        let position: TimeInterval
    }
    private var progress: Progress?

    var isActive: Bool { request != nil }
    var currentRequestID: UUID? { request?.id }

    func end(requestID: UUID?, reason: String) {
        guard let requestID, request?.id == requestID || expiredRequestID == requestID else { return }
        end(reason: reason)
    }

    func allowExplicitRequest() {
        refusedKey = nil
        expiredRequestID = nil
    }

    func isExpired(key: Key, requestID: UUID) -> Bool {
        refusedKey == key && expiredRequestID == requestID && request == nil
    }

    func begin(key: Key, reason: String, explicit: Bool, expiration: @escaping @MainActor (UUID) -> Void) {
        if request?.key == key { return }
        if explicit { allowExplicitRequest() }
        guard refusedKey != key else { return }
        end(reason: "superseded")
        let id = UUID()
        expiredRequestID = nil
        progress = nil
        request = Request(id: id, key: key, expiration: expiration)
        let task = UIApplication.shared.beginBackgroundTask(withName: "Playback restoration") { [weak self] in
            // UIKit invokes expiration handlers on the main thread. End the
            // assertion here; expensive media cleanup is queued by the owner.
            MainActor.assumeIsolated { self?.expire(id) }
        }
        guard request?.id == id else {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            return
        }
        guard task != .invalid else {
            refusedKey = key
            request = nil
            PlayerLog.log("[BackgroundPlayback] execution denied reason=\(reason)")
            return
        }
        request?.task = task
        PlayerLog.log("[BackgroundPlayback] execution began id=\(id) reason=\(reason)")
    }

    func noteProgress(key: Key, backend: ObjectIdentifier, generation: UInt64, position: TimeInterval) {
        guard request?.key == key, position.isFinite else { return }
        if let previous = progress, previous.backend == backend,
           previous.generation == generation, position > previous.position {
            end(reason: "audio-progress")
        } else {
            progress = Progress(backend: backend, generation: generation, position: position)
        }
    }

    func end(reason: String) {
        expiredRequestID = nil
        finish(reason: reason)
    }

    private func finish(reason: String) {
        guard let current = request else { return }
        request = nil
        progress = nil
        if current.task != .invalid { UIApplication.shared.endBackgroundTask(current.task) }
        PlayerLog.log("[BackgroundPlayback] execution ended id=\(current.id) reason=\(reason)")
    }

    private func expire(_ id: UUID) {
        guard let current = request, current.id == id else { return }
        refusedKey = current.key
        expiredRequestID = id
        finish(reason: "expired")
        current.expiration(id)
    }
}
