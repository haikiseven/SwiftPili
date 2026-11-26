import CoreGraphics
import Foundation
import Observation
import SwiftUI

enum MiniPlayerEdge: String, CaseIterable, Equatable, Sendable {
    case top
    case bottom
    case leading
    case trailing
}

struct MiniPlayerDockPosition: Equatable, Sendable {
    var edge: MiniPlayerEdge
    var progress: CGFloat

    init(edge: MiniPlayerEdge, progress: CGFloat) {
        self.edge = edge
        if progress.isFinite {
            self.progress = min(max(progress, 0), 1)
        } else {
            self.progress = 1
        }
    }

    static let bottomTrailing = MiniPlayerDockPosition(edge: .trailing, progress: 1)
    static let bottomLeading = MiniPlayerDockPosition(edge: .leading, progress: 1)
    static let topTrailing = MiniPlayerDockPosition(edge: .trailing, progress: 0)
    static let topLeading = MiniPlayerDockPosition(edge: .leading, progress: 0)
}

struct InAppMiniPlayerSession: Equatable {
    let originRoute: Route
    let originScreenRoute: PlayerScreenRoute
    let originPosition: PlayerRoutePosition?
    let ownerLease: PlayerOwnerLease
    let title: String
    let coverURL: String?
    let mode: PlayerMode
    let isPortrait: Bool
}

struct MiniPlayerReturnHandoff: Equatable {
    let originScreenRoute: PlayerScreenRoute
    let previousOwnerLease: PlayerOwnerLease
    var adoptedOwnerLease: PlayerOwnerLease?
    let mode: PlayerMode
    let aid: Int?
    let cid: Int?
    let source: PlayerViewModel.StreamSource
    let roomID: Int?
    let offlineAsset: OfflinePlaybackAsset?
}

struct PendingMiniPlayerReturnVOD: Equatable, Sendable {
    let aid: Int
    let cid: Int
    let source: PlayerViewModel.StreamSource
}

@MainActor
@Observable
final class InAppMiniPlayerState {
    static let shared = InAppMiniPlayerState()

    static let dockEdgeDefaultsKey = "in_app_mini_player_dock_edge"
    static let dockProgressDefaultsKey = "in_app_mini_player_dock_progress"

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var isInitialized = false

    private(set) var activeSession: InAppMiniPlayerSession?
    @ObservationIgnored
    var returnHandoff: MiniPlayerReturnHandoff?
    var dockPosition: MiniPlayerDockPosition = .bottomTrailing {
        didSet {
            guard isInitialized else { return }
            persistDockPosition(dockPosition)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.dockPosition = Self.loadDockPosition(from: defaults)
        self.isInitialized = true
    }

    private static func loadDockPosition(from defaults: UserDefaults) -> MiniPlayerDockPosition {
        guard let rawEdge = defaults.string(forKey: dockEdgeDefaultsKey),
              let edge = MiniPlayerEdge(rawValue: rawEdge),
              let rawProgress = defaults.object(forKey: dockProgressDefaultsKey),
              let progress = rawProgress as? Double,
              progress.isFinite else {
            return .bottomTrailing
        }
        return MiniPlayerDockPosition(edge: edge, progress: CGFloat(progress))
    }

    private func persistDockPosition(_ position: MiniPlayerDockPosition) {
        defaults.set(position.edge.rawValue, forKey: Self.dockEdgeDefaultsKey)
        defaults.set(Double(position.progress), forKey: Self.dockProgressDefaultsKey)
    }

    var isActive: Bool {
        activeSession != nil
    }

    func retainsOwnerLease(_ lease: PlayerOwnerLease?) -> Bool {
        guard let lease else { return false }
        if activeSession?.ownerLease == lease { return true }
        if let handoff = returnHandoff,
           handoff.adoptedOwnerLease == nil,
           handoff.previousOwnerLease == lease {
            return true
        }
        return false
    }

    func activate(_ session: InAppMiniPlayerSession) {
        returnHandoff = nil
        activeSession = session
    }

    func updateActiveSession(
        matching ownerLease: PlayerOwnerLease,
        title: String,
        coverURL: String?,
        originRoute: Route,
        originScreenRoute: PlayerScreenRoute,
        isPortrait: Bool? = nil
    ) {
        guard let existing = activeSession, existing.ownerLease == ownerLease else { return }
        activeSession = InAppMiniPlayerSession(
            originRoute: originRoute.withoutZoom,
            originScreenRoute: originScreenRoute,
            originPosition: existing.originPosition,
            ownerLease: existing.ownerLease,
            title: title,
            coverURL: coverURL,
            mode: existing.mode,
            isPortrait: isPortrait ?? existing.isPortrait
        )
    }

    func transitionToReturnHandoff(_ handoff: MiniPlayerReturnHandoff) {
        activeSession = nil
        returnHandoff = handoff
    }

    func markReturnHandoffAdopted(by lease: PlayerOwnerLease) {
        guard returnHandoff != nil else { return }
        returnHandoff?.adoptedOwnerLease = lease
    }

    func pendingReturnVOD(
        forSeasonId seasonId: Int,
        ownerLease: PlayerOwnerLease? = nil
    ) -> PendingMiniPlayerReturnVOD? {
        guard let handoff = returnHandoff,
              handoff.mode == .vod,
              handoff.originScreenRoute == .bangumi(seasonId),
              let aid = handoff.aid,
              let cid = handoff.cid else {
            return nil
        }
        if let ownerLease,
           handoff.adoptedOwnerLease != ownerLease && handoff.previousOwnerLease != ownerLease {
            return nil
        }
        return PendingMiniPlayerReturnVOD(aid: aid, cid: cid, source: handoff.source)
    }

    func pendingReturnVOD(
        forAid aid: Int,
        ownerLease: PlayerOwnerLease? = nil
    ) -> PendingMiniPlayerReturnVOD? {
        guard let handoff = returnHandoff,
              handoff.mode == .vod,
              handoff.aid == aid,
              let cid = handoff.cid else {
            return nil
        }
        if let ownerLease,
           handoff.adoptedOwnerLease != ownerLease && handoff.previousOwnerLease != ownerLease {
            return nil
        }
        return PendingMiniPlayerReturnVOD(aid: aid, cid: cid, source: handoff.source)
    }

    func clearActiveSession() {
        activeSession = nil
    }

    func clearReturnHandoff() {
        returnHandoff = nil
    }

    func clearAll() {
        activeSession = nil
        returnHandoff = nil
    }
}

enum InAppMiniPlayerLayoutPolicy {
    static let cornerRadius: CGFloat = 14
    static let phoneHorizontalSize = CGSize(width: 196, height: 110)
    static let padHorizontalSize = CGSize(width: 256, height: 144)
    static let phonePortraitSize = CGSize(width: 116, height: 196)
    static let padPortraitSize = CGSize(width: 144, height: 244)
    static let minCardAspect: CGFloat = 9.0 / 16.0
    static let maxCardAspect: CGFloat = 2.2

    struct SafeCenterBounds: Equatable, Sendable {
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat

        var horizontalSpan: CGFloat { maxX - minX }
        var verticalSpan: CGFloat { maxY - minY }
    }

    enum DismissDirection: CGFloat, Equatable, Sendable {
        case leading = -1
        case trailing = 1
    }

    enum ReleaseAction: Equatable, Sendable {
        case snap(MiniPlayerDockPosition)
        case dismiss(DismissDirection)
    }

    static func cardSize(
        isPortrait: Bool,
        isPad: Bool,
        containerSize: CGSize,
        videoAspectRatio: CGFloat? = nil
    ) -> CGSize {
        let base: CGSize
        if let normalizedAspect = DetailPlayerGeometry.normalizedAspect(videoAspectRatio) {
            let clampedAspect = min(max(normalizedAspect, minCardAspect), maxCardAspect)
            let reference = isPad ? padHorizontalSize : phoneHorizontalSize
            let targetArea = reference.width * reference.height
            let maxBaseWidth = isPad ? padHorizontalSize.width : phoneHorizontalSize.width
            let maxBaseHeight = isPad ? padPortraitSize.height : phonePortraitSize.height
            var width = (targetArea * clampedAspect).squareRoot()
            var height = width / clampedAspect
            let fitScale = min(1, min(maxBaseWidth / width, maxBaseHeight / height))
            width = (width * fitScale).rounded()
            height = (height * fitScale).rounded()
            base = CGSize(width: max(80, width), height: max(60, height))
        } else {
            base = if isPortrait {
                isPad ? padPortraitSize : phonePortraitSize
            } else {
                isPad ? padHorizontalSize : phoneHorizontalSize
            }
        }
        guard containerSize.width.isFinite, containerSize.height.isFinite,
              containerSize.width > 80, containerSize.height > 80 else {
            return base
        }
        let maxWidth = max(96, containerSize.width * 0.56)
        let maxHeight = max(72, containerSize.height * 0.42)
        let widthScale = min(1, maxWidth / base.width)
        let heightScale = min(1, maxHeight / base.height)
        let scale = min(widthScale, heightScale)
        return CGSize(
            width: (base.width * scale).rounded(),
            height: (base.height * scale).rounded()
        )
    }

    static func safeCenterBounds(
        cardSize: CGSize,
        containerSize: CGSize,
        safeArea: EdgeInsets,
        topBarClearance: CGFloat,
        bottomBarClearance: CGFloat,
        horizontalMargin: CGFloat
    ) -> SafeCenterBounds {
        let leadingInset = max(horizontalMargin, safeArea.leading + horizontalMargin)
        let trailingInset = max(horizontalMargin, safeArea.trailing + horizontalMargin)
        let topInset = safeArea.top + topBarClearance
        let bottomInset = safeArea.bottom + bottomBarClearance

        let minX = leadingInset + cardSize.width / 2
        let maxX = max(minX, containerSize.width - trailingInset - cardSize.width / 2)
        let minY = topInset + cardSize.height / 2
        let maxY = max(minY, containerSize.height - bottomInset - cardSize.height / 2)

        return SafeCenterBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    static func anchorCenter(
        for dock: MiniPlayerDockPosition,
        cardSize: CGSize,
        containerSize: CGSize,
        safeArea: EdgeInsets,
        topBarClearance: CGFloat,
        bottomBarClearance: CGFloat,
        horizontalMargin: CGFloat
    ) -> CGPoint {
        let bounds = safeCenterBounds(
            cardSize: cardSize,
            containerSize: containerSize,
            safeArea: safeArea,
            topBarClearance: topBarClearance,
            bottomBarClearance: bottomBarClearance,
            horizontalMargin: horizontalMargin
        )
        let t = dock.progress.isFinite ? min(max(dock.progress, 0), 1) : 1

        switch dock.edge {
        case .leading:
            return CGPoint(x: bounds.minX, y: bounds.minY + bounds.verticalSpan * t)
        case .trailing:
            return CGPoint(x: bounds.maxX, y: bounds.minY + bounds.verticalSpan * t)
        case .top:
            return CGPoint(x: bounds.minX + bounds.horizontalSpan * t, y: bounds.minY)
        case .bottom:
            return CGPoint(x: bounds.minX + bounds.horizontalSpan * t, y: bounds.maxY)
        }
    }

    static func dismissProgress(
        currentCenterX: CGFloat,
        cardWidth: CGFloat,
        containerWidth: CGFloat
    ) -> CGFloat {
        guard containerWidth > 0, cardWidth > 0 else { return 0 }
        let leadingThreshold = cardWidth * 0.30
        let trailingThreshold = containerWidth - cardWidth * 0.30
        let overshoot: CGFloat
        if currentCenterX < leadingThreshold {
            overshoot = leadingThreshold - currentCenterX
        } else if currentCenterX > trailingThreshold {
            overshoot = currentCenterX - trailingThreshold
        } else {
            return 0
        }
        return min(max(overshoot / (cardWidth * 0.45), 0), 1)
    }

    static func resolveRelease(
        anchorCenter: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        cardSize: CGSize,
        containerSize: CGSize,
        safeArea: EdgeInsets,
        topBarClearance: CGFloat,
        bottomBarClearance: CGFloat,
        horizontalMargin: CGFloat
    ) -> ReleaseAction {
        let bounds = safeCenterBounds(
            cardSize: cardSize,
            containerSize: containerSize,
            safeArea: safeArea,
            topBarClearance: topBarClearance,
            bottomBarClearance: bottomBarClearance,
            horizontalMargin: horizontalMargin
        )
        let currentCenter = CGPoint(
            x: anchorCenter.x + translation.width,
            y: anchorCenter.y + translation.height
        )
        let velocityDelta = CGSize(
            width: predictedEndTranslation.width - translation.width,
            height: predictedEndTranslation.height - translation.height
        )
        let horizontalVelocityDominant = abs(velocityDelta.width) > abs(velocityDelta.height) * 1.35

        // Slow drag-off (>58% of card outside container) or strong outward flick past outer dock margin.
        let draggedOffLeading = currentCenter.x < -cardSize.width * 0.08 && velocityDelta.width <= 20
        let flickedOffLeading = horizontalVelocityDominant
            && currentCenter.x < bounds.minX - cardSize.width * 0.12
            && velocityDelta.width < -150
        if draggedOffLeading || flickedOffLeading {
            return .dismiss(.leading)
        }

        let draggedOffTrailing = currentCenter.x > containerSize.width + cardSize.width * 0.08
            && velocityDelta.width >= -20
        let flickedOffTrailing = horizontalVelocityDominant
            && currentCenter.x > bounds.maxX + cardSize.width * 0.12
            && velocityDelta.width > 150
        if draggedOffTrailing || flickedOffTrailing {
            return .dismiss(.trailing)
        }

        // Dampen raw drag momentum so edge docking feels composed and never launches across screen.
        let dampedDX = min(max(velocityDelta.width * 0.30, -130), 130)
        let dampedDY = min(max(velocityDelta.height * 0.30, -150), 150)
        let projected = CGPoint(
            x: currentCenter.x + dampedDX,
            y: currentCenter.y + dampedDY
        )

        let distLeading = projected.x - bounds.minX
        let distTrailing = bounds.maxX - projected.x
        let distTop = projected.y - bounds.minY
        let distBottom = bounds.maxY - projected.y

        let candidates: [(MiniPlayerEdge, CGFloat)] = [
            (.leading, distLeading),
            (.trailing, distTrailing),
            (.top, distTop),
            (.bottom, distBottom),
        ]
        var bestEdge: MiniPlayerEdge = .trailing
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (edge, distance) in candidates where distance < bestDistance {
            bestDistance = distance
            bestEdge = edge
        }

        let progress: CGFloat
        switch bestEdge {
        case .leading, .trailing:
            if bounds.verticalSpan > 0.5 {
                progress = min(max((projected.y - bounds.minY) / bounds.verticalSpan, 0), 1)
            } else {
                progress = 1
            }
        case .top, .bottom:
            if bounds.horizontalSpan > 0.5 {
                progress = min(max((projected.x - bounds.minX) / bounds.horizontalSpan, 0), 1)
            } else {
                progress = 1
            }
        }

        return .snap(MiniPlayerDockPosition(edge: bestEdge, progress: progress))
    }
}

extension Route {
    var withoutZoom: Route {
        switch self {
        case .videoDetail(let target):
            .videoDetail(VideoRouteTarget(
                videoID: target.videoID,
                preview: target.preview,
                zoomSourceID: nil
            ))
        case .liveRoom(let roomID, _):
            .liveRoom(roomID, zoom: .none)
        case .bangumiDetail(let seasonID, _):
            .bangumiDetail(seasonID, zoom: .none)
        case .offlinePlayer(let id, _):
            .offlinePlayer(id, zoom: .none)
        case .offlinePager(let context, _):
            .offlinePager(context, zoom: .none)
        default:
            self
        }
    }

    static func fallback(for screenRoute: PlayerScreenRoute) -> Route {
        switch screenRoute {
        case .video(let id):
            .videoDetail(VideoRouteTarget(videoID: id))
        case .bangumi(let seasonID):
            .bangumiDetail(seasonID, zoom: .none)
        case .live(let roomID):
            .liveRoom(roomID, zoom: .none)
        case .offline(let context):
            if context.items.count == 1, let first = context.items.first {
                .offlinePlayer(first.downloadID, zoom: .none)
            } else {
                .offlinePager(context, zoom: .none)
            }
        }
    }

    var miniPlayerPreviewTitle: String? {
        switch self {
        case .videoDetail(let target):
            return target.preview.title.isEmpty ? nil : target.preview.title
        case .offlinePager(let context, _):
            if context.items.indices.contains(context.initialIndex) {
                let title = context.items[context.initialIndex].preview.title
                return title.isEmpty ? nil : title
            }
            return nil
        default:
            return nil
        }
    }

    var miniPlayerPreviewCoverURL: String? {
        switch self {
        case .videoDetail(let target):
            let url = target.preview.coverSource.url(preferring: .desktop)
            return url.isEmpty ? nil : url
        case .offlinePager(let context, _):
            if context.items.indices.contains(context.initialIndex) {
                let url = context.items[context.initialIndex].preview.coverSource.url(preferring: .desktop)
                return url.isEmpty ? nil : url
            }
            return nil
        default:
            return nil
        }
    }
}

extension PlayerViewModel {
    func ownerMatchesScreenRoute(_ owner: String, route: PlayerScreenRoute) -> Bool {
        switch route {
        case .video(let id):
            owner.hasPrefix("vod-detail-") || owner == Self.vodOwner(id)
        case .bangumi(let seasonID):
            owner == Self.pgcOwner(seasonID)
        case .live(let roomID):
            owner == Self.liveOwner(roomID)
        case .offline:
            owner.hasPrefix("offline-pager-") || owner.hasPrefix("offline-")
        }
    }

    func canEnterMiniPlayer(for lease: PlayerOwnerLease) -> Bool {
        synchronizeTerminalAdmissionFromBackend()
        guard PlayerPlaybackPreferences.inAppMiniPlayerEnabled else { return false }
        guard isCurrentOwner(lease) else { return false }
        guard playbackIntent == .playing else { return false }
        guard currentURL != nil else { return false }
        guard error == nil, unavailability == nil, !terminalOpenFailure else { return false }
        guard !currentPlaybackTerminalState.isTerminal else { return false }
        guard !isFullscreen, !isFullscreenPresentationActive else { return false }
        guard !backend.isPiPActive, !backend.hasObservedPiPLease else { return false }
        return true
    }

    @discardableResult
    func activateMiniPlayerIfEligible(
        departing destination: PlayerRouteDestination,
        departingRoute: Route?,
        ownerLease: PlayerOwnerLease
    ) -> Bool {
        guard canEnterMiniPlayer(for: ownerLease) else { return false }
        retireFullscreenPresentation()
        let originRoute = (departingRoute ?? Route.fallback(for: destination.route)).withoutZoom
        let title = nowPlayingMeta?.title ?? departingRoute?.miniPlayerPreviewTitle ?? ""
        let cover = nowPlayingMeta?.cover ?? ambientCoverURL ?? departingRoute?.miniPlayerPreviewCoverURL
        let session = InAppMiniPlayerSession(
            originRoute: originRoute,
            originScreenRoute: destination.route,
            originPosition: destination.position,
            ownerLease: ownerLease,
            title: title,
            coverURL: cover,
            mode: mode,
            isPortrait: isPortraitContent
        )
        miniPlayer.activate(session)
        suspendDanmakuVisibleWork()
        _ = prepareSurfaceHandoff(ownerLease: ownerLease, to: .miniPlayer)
        PlayerLog.log(
            "[MiniPlayer] activated owner=\(ownerLease.owner) " +
            "mode=\(mode) portrait=\(isPortraitContent ? 1 : 0)"
        )
        return true
    }

    func handleMiniPlayerIncomingRoute(_ incoming: PlayerRouteDestination) {
        guard let session = miniPlayer.activeSession else { return }
        synchronizeTerminalAdmissionFromBackend()
        if incoming.route == session.originScreenRoute,
           isCurrentOwner(session.ownerLease),
           currentURL != nil,
           !currentPlaybackTerminalState.isTerminal,
           error == nil,
           unavailability == nil,
           !terminalOpenFailure {
            let handoff = MiniPlayerReturnHandoff(
                originScreenRoute: session.originScreenRoute,
                previousOwnerLease: session.ownerLease,
                adoptedOwnerLease: nil,
                mode: mode,
                aid: currentAid,
                cid: currentCid,
                source: currentSource,
                roomID: currentRoomID,
                offlineAsset: offlineAsset
            )
            miniPlayer.transitionToReturnHandoff(handoff)
            _ = handoffSurfaceSlot(ownerLease: session.ownerLease, to: .inline)
            PlayerLog.log(
                "[MiniPlayer] returning to origin route owner=\(session.ownerLease.owner) " +
                "mode=\(mode) t=\(String(format: "%.1f", mediaTime))s"
            )
            return
        }
        PlayerLog.log(
            "[MiniPlayer] dismissed by incoming different route owner=\(session.ownerLease.owner)"
        )
        dismissMiniPlayer()
    }

    func dismissMiniPlayer(matching expectedLease: PlayerOwnerLease? = nil) {
        if let expectedLease, miniPlayer.activeSession?.ownerLease != expectedLease {
            return
        }
        let leaseToEnd = miniPlayer.activeSession?.ownerLease
        miniPlayer.clearAll()
        if let leaseToEnd {
            _ = endOwnerPlayback(lease: leaseToEnd)
        }
        PlayerLog.log("[MiniPlayer] dismissed")
    }

    func shouldPreserveSessionForMiniPlayerReturn(incomingOwner: String) -> Bool {
        guard let handoff = miniPlayer.returnHandoff,
              handoff.adoptedOwnerLease == nil,
              currentOwnerLease == handoff.previousOwnerLease,
              currentURL != nil,
              !currentPlaybackTerminalState.isTerminal,
              error == nil,
              unavailability == nil,
              !terminalOpenFailure else {
            return false
        }
        return ownerMatchesScreenRoute(incomingOwner, route: handoff.originScreenRoute)
    }

    func pendingMiniPlayerReturnVOD(
        forSeasonId seasonId: Int,
        ownerLease: PlayerOwnerLease? = nil
    ) -> PendingMiniPlayerReturnVOD? {
        if let pending = miniPlayer.pendingReturnVOD(forSeasonId: seasonId, ownerLease: ownerLease),
           matchesLiveMiniPlayerReturnVOD(
               aid: pending.aid,
               cid: pending.cid,
               source: pending.source,
               ownerLease: ownerLease
           ) {
            return pending
        }
        if let ownerLease,
           isCurrentOwner(ownerLease),
           mode == .vod,
           currentURL != nil,
           !currentPlaybackTerminalState.isTerminal,
           error == nil,
           unavailability == nil,
           !terminalOpenFailure,
           let queue = playbackQueue,
           case .bangumiSeason(let queueSeasonId) = queue.kind,
           queueSeasonId == seasonId,
           let item = queue.currentItem,
           currentAid == item.aid,
           currentCid == item.cid,
           currentSource == item.source {
            return PendingMiniPlayerReturnVOD(aid: item.aid, cid: item.cid, source: item.source)
        }
        return nil
    }

    func pendingMiniPlayerReturnVOD(
        forAid aid: Int,
        ownerLease: PlayerOwnerLease? = nil
    ) -> PendingMiniPlayerReturnVOD? {
        if let pending = miniPlayer.pendingReturnVOD(forAid: aid, ownerLease: ownerLease),
           matchesLiveMiniPlayerReturnVOD(
               aid: pending.aid,
               cid: pending.cid,
               source: pending.source,
               ownerLease: ownerLease
           ) {
            return pending
        }
        if let ownerLease,
           isCurrentOwner(ownerLease),
           mode == .vod,
           currentAid == aid,
           let cid = currentCid,
           currentSource == .ugc,
           currentURL != nil,
           !currentPlaybackTerminalState.isTerminal,
           error == nil,
           unavailability == nil,
           !terminalOpenFailure {
            return PendingMiniPlayerReturnVOD(aid: aid, cid: cid, source: currentSource)
        }
        return nil
    }

    func matchesLiveMiniPlayerReturnVOD(
        aid: Int,
        cid: Int,
        source: StreamSource? = nil,
        ownerLease: PlayerOwnerLease?
    ) -> Bool {
        guard let handoff = miniPlayer.returnHandoff,
              handoff.mode == .vod,
              handoff.aid == aid,
              handoff.cid == cid,
              source == nil || (handoff.source == source && currentSource == source),
              mode == .vod,
              currentAid == aid,
              currentCid == cid,
              currentURL != nil,
              !currentPlaybackTerminalState.isTerminal,
              error == nil,
              unavailability == nil,
              !terminalOpenFailure else {
            return false
        }
        if let ownerLease {
            guard isCurrentOwner(ownerLease),
                  handoff.adoptedOwnerLease == ownerLease || handoff.previousOwnerLease == ownerLease else {
                return false
            }
        }
        return true
    }

    @discardableResult
    func consumeMiniPlayerReturnIfLiveVOD(
        aid: Int,
        cid: Int,
        bvid: String?,
        source: StreamSource,
        quality: Int?,
        ownerLease: PlayerOwnerLease?,
        startupTraceToken: StartupTrace.Token?,
        mediaResetID: UUID?,
        recoveryCoverIdentity: UInt64?,
        cdnSwitchID: UUID?,
        streamRetryID: UUID?
    ) -> Bool {
        guard let handoff = miniPlayer.returnHandoff else { return false }
        let isInitialLoad = mediaResetID == nil
            && recoveryCoverIdentity == nil
            && cdnSwitchID == nil
            && streamRetryID == nil
            && quality == nil
        let leaseMatches = ownerLease == nil
            || handoff.adoptedOwnerLease == ownerLease
            || handoff.previousOwnerLease == ownerLease
        guard isInitialLoad,
              leaseMatches,
              handoff.mode == .vod,
              handoff.aid == aid,
              handoff.cid == cid,
              handoff.source == source,
              mode == .vod,
              currentAid == aid,
              currentCid == cid,
              currentSource == source,
              currentURL != nil,
              !currentPlaybackTerminalState.isTerminal,
              error == nil,
              unavailability == nil,
              !terminalOpenFailure else {
            miniPlayer.clearReturnHandoff()
            return false
        }
        miniPlayer.clearReturnHandoff()
        presentationResetPendingForOwnerChange = false
        if let bvid = bvid?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bvid.isEmpty,
           currentBvid == nil {
            currentBvid = bvid
        }
        if let owner = currentOwnerLease {
            ambientStoryboardRequest = PlayerAmbientStoryboardLoader.Request(
                content: .init(aid: aid, cid: cid, owner: owner),
                loadGeneration: loadGeneration
            )
            reconcileAmbientStoryboard()
            if let meta = nowPlayingMeta {
                setNowPlaying(title: meta.title, artist: meta.artist, cover: meta.cover)
            }
        }
        admitDanmakuSession(openingAt: mediaTime)
        if isPlaying {
            resumePollingTasks()
        }
        if let startupTraceToken {
            StartupTrace.abort("mini-player-return", token: startupTraceToken)
        }
        PlayerLog.log(
            "[MiniPlayer] seamless VOD return handoff aid=\(aid) cid=\(cid) " +
            "t=\(String(format: "%.1f", mediaTime))s"
        )
        return true
    }

    func consumeMiniPlayerReturnIfLiveStream(
        roomID: Int,
        ownerLease: PlayerOwnerLease?,
        mediaResetID: UUID?,
        preservingLiveReconnect: Bool,
        preservePlayState: Bool
    ) -> Int? {
        guard let handoff = miniPlayer.returnHandoff else { return nil }
        let isInitialLoad = mediaResetID == nil && !preservingLiveReconnect && !preservePlayState
        let leaseMatches = ownerLease == nil
            || handoff.adoptedOwnerLease == ownerLease
            || handoff.previousOwnerLease == ownerLease
        guard isInitialLoad,
              leaseMatches,
              handoff.mode == .live,
              handoff.roomID == roomID,
              mode == .live,
              currentRoomID == roomID,
              currentURL != nil,
              error == nil,
              unavailability == nil,
              !terminalOpenFailure else {
            miniPlayer.clearReturnHandoff()
            return nil
        }
        miniPlayer.clearReturnHandoff()
        presentationResetPendingForOwnerChange = false
        if let meta = nowPlayingMeta {
            setNowPlaying(title: meta.title, artist: meta.artist, cover: meta.cover)
        }
        if isPlaying {
            resumePollingTasks()
        }
        PlayerLog.log(
            "[MiniPlayer] seamless Live return handoff room=\(roomID) qn=\(currentLiveQuality)"
        )
        return currentLiveQuality
    }

    @discardableResult
    func consumeMiniPlayerReturnIfLiveOffline(
        asset: OfflinePlaybackAsset,
        ownerLease: PlayerOwnerLease
    ) -> Bool {
        guard let handoff = miniPlayer.returnHandoff else { return false }
        let leaseMatches = handoff.adoptedOwnerLease == ownerLease
            || handoff.previousOwnerLease == ownerLease
        guard leaseMatches,
              handoff.mode == .offline,
              handoff.offlineAsset == asset,
              mode == .offline,
              offlineAsset == asset,
              currentURL == asset.videoURL,
              !currentPlaybackTerminalState.isTerminal,
              error == nil,
              unavailability == nil,
              !terminalOpenFailure else {
            miniPlayer.clearReturnHandoff()
            return false
        }
        miniPlayer.clearReturnHandoff()
        presentationResetPendingForOwnerChange = false
        setNowPlaying(title: asset.title, artist: asset.artist, cover: asset.cover)
        if isPlaying {
            resumePollingTasks()
        }
        PlayerLog.log(
            "[MiniPlayer] seamless Offline return handoff aid=\(asset.aid) cid=\(asset.cid) " +
            "t=\(String(format: "%.1f", mediaTime))s"
        )
        return true
    }
}
