import Foundation

/// The identity carried with a backend-originated system-media edge.
///
/// These axes are deliberately kept separate. The owner/item pair belongs to
/// the App's system-media session, while backend/session/PiP generations fence
/// the transport object that produced the edge. A callback from an old object
/// must be rejected before it reaches the projection sink.
struct NowPlayingEdgeFence: Sendable, Equatable {
    let owner: PlayerOwnerLease
    let itemGeneration: UInt64
    let backendGeneration: UInt64
    let sessionGeneration: UInt64
    var pipBindingGeneration: UInt64?
}

/// Significant state edges which may refresh the manually-published
/// Now-Playing timing snapshot. Buffering is intentionally absent: this slice
/// does not turn transient buffering or interruption observations into a new
/// rate policy.
enum NowPlayingStateEdge: Sendable, Equatable {
    case playing
    case paused
    case rateChanged
    case seekSettled(operation: UInt64)
    case terminal
    case background
}

/// Dynamic values supplied by the App after it has reduced a backend edge.
/// `elapsed` remains the existing display-time authority for this slice.
struct NowPlayingEdgeProjection: Sendable, Equatable {
    let elapsed: TimeInterval
    let duration: TimeInterval
    let rate: Float
    let isPlaying: Bool
    let isActionable: Bool
}

/// Maps accepted, backend-neutral state edges into the single App-owned
/// Now-Playing projection. It has no task, timer, backend, or MediaPlayer
/// singleton of its own.
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
    /// Keep a bounded operation ledger so a duplicate seek settlement cannot
    /// republish after another edge has changed the latest projection.
    private var settledSeekOperations: [SettlementKey] = []

    init(
        sink: NowPlayingCenter,
        fenceValidator: @escaping FenceValidator = { _ in true }
    ) {
        self.sink = sink
        self.fenceValidator = fenceValidator
    }

    /// Publishes one current projection for an accepted edge. Equal
    /// projections are coalesced across edge labels as well as duplicate
    /// settlements; this covers synchronous re-entrant pause callbacks and
    /// duplicate AVKit/backend completions without requiring a second owner.
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
        // A repeated edge with a different edge identity but identical values
        // still represents one system snapshot. This is important when a
        // backend's paused callback re-enters while a terminal failure is
        // being accepted by the presentation reducer. A seek settlement is
        // different: operation identity is the semantic edge, so a successful
        // seek must publish even when it lands on values equal to the last
        // transport snapshot (for example, a clamped/zero-distance landing).
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
