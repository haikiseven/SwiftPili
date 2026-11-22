import Foundation

struct NowPlayingEdgeFence: Sendable, Equatable {
    let owner: PlayerOwnerLease
    let itemGeneration: UInt64
    let backendGeneration: UInt64
    let sessionGeneration: UInt64
    var pipBindingGeneration: UInt64?
}

enum NowPlayingStateEdge: Sendable, Equatable {
    case playing
    case paused
    case rateChanged
    case seekSettled(operation: UInt64)
    case terminal
    case background
}

struct NowPlayingEdgeProjection: Sendable, Equatable {
    let elapsed: TimeInterval
    let duration: TimeInterval
    let rate: Float
    let isPlaying: Bool
    let isActionable: Bool
}

@MainActor
final class NowPlayingStateEdgeAdapter {
    typealias FenceValidator = @MainActor @Sendable (NowPlayingEdgeFence) -> Bool

    private struct Publication: Equatable {
        let edge: NowPlayingStateEdge
        let fence: NowPlayingEdgeFence
        let projection: NowPlayingEdgeProjection
    }

    private struct SettlementKey: Equatable {
        let operation: UInt64
        let owner: String
        let ownerLeaseGeneration: UInt64
        let itemGeneration: UInt64
        let backendGeneration: UInt64
        let sessionGeneration: UInt64
        let pipBindingGeneration: UInt64?

        init(operation: UInt64, fence: NowPlayingEdgeFence) {
            self.operation = operation
            owner = fence.owner.owner
            ownerLeaseGeneration = fence.owner.generation
            itemGeneration = fence.itemGeneration
            backendGeneration = fence.backendGeneration
            sessionGeneration = fence.sessionGeneration
            pipBindingGeneration = fence.pipBindingGeneration
        }
    }

    private let sink: NowPlayingCenter
    private let fenceValidator: FenceValidator
    private var lastPublication: Publication?
    private var settledSeekOperations: [SettlementKey] = []

    init(
        sink: NowPlayingCenter,
        fenceValidator: @escaping FenceValidator = { _ in true }
    ) {
        self.sink = sink
        self.fenceValidator = fenceValidator
    }

    @discardableResult
    func publish(
        edge: NowPlayingStateEdge,
        fence: NowPlayingEdgeFence,
        projection: NowPlayingEdgeProjection
    ) -> Bool {
        guard fenceValidator(fence) else { return false }
        guard let current = sink.currentSnapshot,
              current.owner == fence.owner,
              current.itemGeneration == fence.itemGeneration else {
            return false
        }

        let publication = Publication(
            edge: edge,
            fence: fence,
            projection: projection
        )
        if case let .seekSettled(operation) = edge {
            let key = SettlementKey(operation: operation, fence: fence)
            guard !settledSeekOperations.contains(key) else { return false }
        }
        let isSeekSettlement: Bool
        if case .seekSettled = edge {
            isSeekSettlement = true
        } else {
            isSeekSettlement = false
        }
        if !isSeekSettlement,
           lastPublication?.fence == publication.fence,
           lastPublication?.projection == publication.projection {
            return false
        }

        guard sink.updatePlayback(
            owner: fence.owner,
            elapsed: projection.elapsed,
            duration: projection.duration,
            rate: projection.rate,
            isPlaying: projection.isPlaying,
            isActionable: projection.isActionable
        ) else {
            return false
        }
        lastPublication = publication
        if case let .seekSettled(operation) = edge {
            settledSeekOperations.append(SettlementKey(operation: operation, fence: fence))
            if settledSeekOperations.count > 128 {
                settledSeekOperations.removeFirst()
            }
        }
        return true
    }

    @discardableResult
    func consume(
        edge: NowPlayingStateEdge,
        fence: NowPlayingEdgeFence,
        projection: NowPlayingEdgeProjection
    ) -> Bool {
        publish(edge: edge, fence: fence, projection: projection)
    }
}
