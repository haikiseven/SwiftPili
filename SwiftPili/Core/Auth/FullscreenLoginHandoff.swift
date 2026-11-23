import Foundation
import SwiftUI

private struct AppSceneIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var appSceneID: UUID? {
        get { self[AppSceneIDKey.self] }
        set { self[AppSceneIDKey.self] = newValue }
    }
}

@MainActor
@Observable
final class FullscreenLoginHandoff {
    static let shared = FullscreenLoginHandoff()

    @ObservationIgnored private var awaitingExit = false
    @ObservationIgnored private var pendingSceneID: UUID?
    private(set) var targetSceneID: UUID?
    private(set) var isReady = false

    func arm(sceneID: UUID? = nil) {
        awaitingExit = true
        pendingSceneID = sceneID
        isReady = false
        targetSceneID = nil
    }

    func cancel() {
        awaitingExit = false
        pendingSceneID = nil
    }

    func release() {
        guard awaitingExit else { return }
        awaitingExit = false
        targetSceneID = pendingSceneID
        pendingSceneID = nil
        isReady = true
    }

    func consume(for sceneID: UUID? = nil) -> Bool {
        guard isReady else { return false }
        if let targetSceneID, targetSceneID != sceneID {
            return false
        }
        isReady = false
        targetSceneID = nil
        return true
    }
}
