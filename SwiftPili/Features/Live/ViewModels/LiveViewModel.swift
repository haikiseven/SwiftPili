import Foundation
import Observation

enum LiveSection: Equatable, Hashable {
    case recommended
    case follows
    case area(parentID: Int, areaID: Int, name: String)

    var title: String {
        switch self {
        case .recommended: String(localized: "Live")
        case .follows: String(localized: "My Follows")
        case .area(_, _, let name): name
        }
    }

    var icon: String {
        switch self {
        case .recommended: "sparkles"
        case .follows: "heart"
        case .area: "square.grid.2x2"
        }
    }
}

@MainActor
@Observable
final class LiveListViewModel {
    @MainActor
    @Observable
    final class SectionState {
        var cards: [LiveListResult.LiveCard] = []
        var page = 1
        var hasMore = true
        var hasLoadedPage = false
        var isLoading = false
        var loadFailure: LoadFailure?
    }

    var section: LiveSection = .recommended
    var areas: [LiveParentArea] = []

    struct LoadFailure: Equatable {
        let id = UUID()
        let message: String
        let retriesRefresh: Bool
    }

    var liveCards: [LiveListResult.LiveCard] {
        get { state(for: section).cards }
        set { state(for: section).cards = newValue }
    }

    var isLoading: Bool {
        get { state(for: section).isLoading }
        set { state(for: section).isLoading = newValue }
    }

    var hasLoadedPage: Bool { state(for: section).hasLoadedPage }
    var loadFailure: LoadFailure? { state(for: section).loadFailure }

    private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var sectionStates: [LiveSection: SectionState] = [
        .recommended: SectionState(),
    ]
    @ObservationIgnored private var warmTasks: [LiveSection: (id: UUID, task: Task<Void, Never>)] = [:]

    var paginationAdmissionCursor: String { "page:\(state(for: section).page)" }

    func state(for target: LiveSection) -> SectionState {
        if let existing = sectionStates[target] {
            return existing
        }
        let created = SectionState()
        sectionStates[target] = created
        return created
    }

    func selectSection(_ new: LiveSection) {
        guard new != section else { return }
        let previousState = state(for: section)
        if previousState.isLoading {
            previousState.isLoading = false
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        section = new
        let targetState = state(for: new)
        targetState.loadFailure = nil
        if targetState.hasLoadedPage {
            targetState.isLoading = false
            return
        }
        if warmTasks[new] != nil {
            targetState.isLoading = true
            return
        }
        Task { await fetchInitialSection(new, generation: generation) }
    }

    func switchSection(_ new: LiveSection) async {
        selectSection(new)
    }

    func displayedCards(for target: LiveSection) -> [LiveListResult.LiveCard] {
        state(for: target).cards
    }

    func displayedHasLoadedPage(for target: LiveSection) -> Bool {
        state(for: target).hasLoadedPage
    }

    func displayedFailure(for target: LiveSection) -> LoadFailure? {
        state(for: target).loadFailure
    }

    func displayedIsLoading(for target: LiveSection) -> Bool {
        state(for: target).isLoading
    }

    func warmAdjacentSections(isLoggedIn: Bool) {
        if isLoggedIn {
            warmSectionIfNeeded(.follows)
        } else if let firstArea = areas.first {
            warmSectionIfNeeded(.area(parentID: firstArea.id, areaID: 0, name: firstArea.name))
        }
    }

    private func warmSectionIfNeeded(_ target: LiveSection) {
        guard target != section else { return }
        let targetState = state(for: target)
        guard !targetState.hasLoadedPage, warmTasks[target] == nil else { return }
        let warmID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.warmTasks[target]?.id == warmID {
                    self.warmTasks.removeValue(forKey: target)
                }
            }
            do {
                let (cards, more) = try await self.fetchPage(1, section: target)
                guard !Task.isCancelled,
                      self.warmTasks[target]?.id == warmID,
                      !targetState.hasLoadedPage else { return }
                targetState.cards = FeedCollectionPolicy.replaceDeduplicated(cards, id: \.id)
                targetState.hasMore = more
                targetState.page = 2
                targetState.hasLoadedPage = true
                targetState.loadFailure = nil
                targetState.isLoading = false
            } catch {
                guard !Task.isCancelled,
                      self.warmTasks[target]?.id == warmID,
                      !targetState.hasLoadedPage else { return }
                targetState.isLoading = false
                if self.section == target, !Self.isCancellationError(error) {
                    targetState.loadFailure = LoadFailure(
                        message: error.localizedDescription,
                        retriesRefresh: false
                    )
                }
            }
        }
        warmTasks[target] = (id: warmID, task: task)
    }

    private func fetchInitialSection(_ new: LiveSection, generation: UInt64) async {
        let targetState = state(for: new)
        beginRequest(on: targetState)
        defer { endRequest(on: targetState, generation: generation) }
        do {
            let (cards, more) = try await fetchPage(1, section: new)
            guard !Task.isCancelled, generation == loadGeneration, section == new else { return }
            targetState.cards = FeedCollectionPolicy.replaceDeduplicated(cards, id: \.id)
            targetState.hasMore = more
            targetState.page = 2
            targetState.hasLoadedPage = true
        } catch {
            guard !Task.isCancelled, generation == loadGeneration, section == new else { return }
            guard !error.isCancellation else { return }
            targetState.loadFailure = LoadFailure(message: error.localizedDescription, retriesRefresh: false)
            PlayerLog.log("[LiveVM] switchSection failed: \(error)")
        }
    }

    func loadAreas() async {
        guard areas.isEmpty else { return }
        do {
            areas = try await LiveAPI.getAreaList()
        } catch {
            PlayerLog.log("[LiveVM] area list failed: \(error)")
        }
    }

    private func fetchPage(
        _ page: Int, section requestedSection: LiveSection
    ) async throws(BiliError) -> (cards: [LiveListResult.LiveCard], hasMore: Bool) {
        switch requestedSection {
        case .recommended:
            let result = try await LiveAPI.getLiveList(page: page)
            guard let cards = result.list else { throw missingListError() }
            return (cards, (result.hasMore ?? 0) == 1)
        case .follows:
            let result = try await LiveAPI.getFollowingLive(page: page)
            guard let list = result.list else { throw missingListError() }
            let cards = list.sorted { ($0.liveStatus == 1 ? 0 : 1) < ($1.liveStatus == 1 ? 0 : 1) }
            return (cards, page < (result.totalPage ?? 1))
        case .area(let parentID, let areaID, _):
            let cards = try await LiveAPI.getAreaRooms(parentAreaID: parentID, areaID: areaID, page: page)
            return (cards, cards.count >= LiveAPI.areaRoomsPageSize)
        }
    }

    private enum CatalogueCodingKey: String, CodingKey { case list }

    private func missingListError() -> BiliError {
        .decodingFailed(DecodingError.keyNotFound(
            CatalogueCodingKey.list,
            .init(codingPath: [], debugDescription: "Live catalogue response has no usable list")
        ))
    }

    @discardableResult
    func load() async -> Bool {
        let requested = section
        let targetState = state(for: requested)
        guard !Task.isCancelled, targetState.hasMore, !targetState.isLoading else { return false }
        let requestedPage = targetState.page
        let generation = loadGeneration
        beginRequest(on: targetState)
        defer { endRequest(on: targetState, generation: generation) }
        do {
            let (cards, more) = try await fetchPage(requestedPage, section: requested)
            guard !Task.isCancelled, generation == loadGeneration, section == requested else { return false }
            FeedCollectionPolicy.appendDeduplicated(
                to: &targetState.cards,
                incoming: cards,
                id: \.id
            )
            targetState.hasMore = more
            targetState.page = max(targetState.page, requestedPage + 1)
            targetState.hasLoadedPage = true
            return true
        } catch {
            guard !Task.isCancelled, generation == loadGeneration, section == requested else { return false }
            guard !error.isCancellation else { return false }
            targetState.loadFailure = LoadFailure(message: error.localizedDescription, retriesRefresh: false)
            PlayerLog.log("[LiveVM] load failed: \(error)")
            return false
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requested = section
        if let warm = warmTasks.removeValue(forKey: requested) {
            warm.task.cancel()
        }
        let targetState = state(for: requested)
        beginRequest(on: targetState)
        defer { endRequest(on: targetState, generation: generation) }
        let fetch = Task { try await self.fetchPage(1, section: requested) }
        do {
            let (cards, more) = try await fetch.value
            guard generation == loadGeneration, section == requested else { return false }
            targetState.cards = FeedCollectionPolicy.replaceDeduplicated(cards, id: \.id)
            targetState.hasMore = more
            targetState.page = 2
            targetState.hasLoadedPage = true
            return true
        } catch {
            guard generation == loadGeneration, section == requested else { return false }
            guard !Self.isCancellationError(error) else { return false }
            targetState.loadFailure = LoadFailure(message: error.localizedDescription, retriesRefresh: true)
            PlayerLog.log("[LiveVM] refresh failed (keeping current cards): \(error)")
            return false
        }
    }

    private static func isCancellationError(_ error: any Error) -> Bool {
        BiliAPIRetryPolicy.isCancellation(error) || (error as? BiliError)?.isCancellation == true
    }

    func canRetry(_ failure: LoadFailure) -> Bool {
        !isLoading && loadFailure == failure
    }

    private func beginRequest(on targetState: SectionState) {
        targetState.loadFailure = nil
        targetState.isLoading = true
    }

    private func endRequest(on targetState: SectionState, generation: UInt64) {
        guard generation == loadGeneration else { return }
        targetState.isLoading = false
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    let uid: Int
    let uname: String
    let text: String
    let isSystem: Bool
    let medalName: String?
    let medalLevel: Int?
    let medalColor: Int?

    init(
        uid: Int = 0,
        uname: String,
        text: String,
        isSystem: Bool = false,
        medalName: String? = nil,
        medalLevel: Int? = nil,
        medalColor: Int? = nil
    ) {
        self.id = UUID()
        self.uid = uid
        self.uname = uname
        self.text = text
        self.isSystem = isSystem
        self.medalName = medalName
        self.medalLevel = medalLevel
        self.medalColor = medalColor
    }
}

struct LiveQuality: Sendable {
    let qn: Int
    let label: String
}

enum LiveNowPlayingPublicationPolicy {
    static func allows(
        callerLease: PlayerOwnerLease?,
        currentLease: PlayerOwnerLease?
    ) -> Bool {
        guard let callerLease, let currentLease else { return false }
        return callerLease == currentLease
    }
}

@MainActor
@Observable
final class LiveRoomViewModel {
    var roomInfo: LiveRoomInfo?
    var isPortraitHint: Bool?
    var playbackState: LiveRoomPlaybackState?
    var streamUnavailable: LiveRoomStatusPolicy.Refusal?
    var isLoading = false
    var error: String?
    var currentQuality = 400
    var chatMessages: [ChatMessage] = []
    var availableQualities: [LiveQuality] = []
    var popularity: Int = 0

    private var danmakuClient: LiveDanmakuClient?
    private var danmakuConnectionGeneration: UInt64 = 0
    private(set) var playerOwnerLease: PlayerOwnerLease?
    private var committedRoomID: Int?
    @ObservationIgnored private var loadRequestSerial: UInt64 = 0

    private static let fallbackQualities: [LiveQuality] = [
        LiveQuality(qn: 10000, label: String(localized: "Original")),
        LiveQuality(qn: 400, label: String(localized: "Blu-ray")),
        LiveQuality(qn: 150, label: String(localized: "HD")),
        LiveQuality(qn: 80, label: String(localized: "SD")),
    ]

    private static let systemSender = String(localized: "System (live)")

    func load(roomID: Int, requestAdmission: (@MainActor () -> Bool)? = nil) async {
        guard !Task.isCancelled, requestAdmission?() ?? true else { return }
        if committedRoomID == roomID, roomInfo != nil, error == nil, streamUnavailable == nil,
           PlayerViewModel.shared.isAlreadyLivePresentation(
               lease: playerOwnerLease, source: .live(roomID: roomID)
           ) { return }
        if roomInfo?.roomId != roomID, committedRoomID != roomID { isPortraitHint = nil }
        loadRequestSerial &+= 1
        let requestSerial = loadRequestSerial
        PlayerLog.log("[LiveRoomVM] loading roomID=\(roomID)")
        isLoading = true
        defer { if loadRequestSerial == requestSerial { isLoading = false } }

        error = nil
        let publication = RoomLoadPublication()

        disconnect()
        let danmakuGeneration = danmakuConnectionGeneration

        async let roomInfo: Void = loadRoomInfo(
            roomID: roomID, requestSerial: requestSerial,
            requestAdmission: requestAdmission, publication: publication
        )
        async let danmaku: Void = connectDanmaku(
            roomID: roomID,
            generation: danmakuGeneration
        )

        do {
            let playInfo = try await LiveAPI.getPlayInfo(roomID: roomID, quality: currentQuality)
            try requireCurrentLoad(requestSerial, requestAdmission: requestAdmission)
            if let isPortrait = playInfo.isPortrait { isPortraitHint = isPortrait }
            updateQualities(from: playInfo)
            let decision = LiveRoomStatusPolicy.decide(
                liveStatus: playInfo.liveStatus,
                hasStream: playInfo.hasPlayableStream
            )
            playbackState = LiveRoomStatusPolicy.state(liveStatus: playInfo.liveStatus)
            if case .refuse(let refusal) = decision {
                PlayerLog.log(
                    "[LiveRoomVM] no playback attempt — status=" +
                        "\(playInfo.liveStatus.map(String.init) ?? "nil") refusal=\(refusal)"
                )
                streamUnavailable = refusal
                error = nil
                await roomInfo
                return
            }
            streamUnavailable = nil
            PlayerLog.log("[LiveRoomVM] qualities: \(availableQualities.map { "\($0.qn):\($0.label)" }) current=\(currentQuality)")
            let lease = PlayerViewModel.shared.claimOwnerLease(
                owner: PlayerViewModel.liveOwner(roomID)
            )
            playerOwnerLease = lease
            committedRoomID = roomID
            let selectedQuality = await PlayerViewModel.shared.loadLive(
                roomID: roomID,
                quality: currentQuality,
                playInfo: playInfo,
                owner: lease.owner,
                ownerLease: lease
            )
            try requireCurrentLoad(requestSerial, requestAdmission: requestAdmission)
            publication.lease = lease
            if let room = publication.roomInfo {
                publishRoomInfo(room, publicationLease: lease)
            }
            if let selectedQuality {
                let requestedQuality = currentQuality
                currentQuality = selectedQuality
                announceQualityFallback(
                    requested: requestedQuality,
                    actual: selectedQuality
                )
            }
        } catch {
            guard admitsLoad(requestSerial, requestAdmission: requestAdmission) else { return }
            self.error = "\(error)"
            PlayerLog.log("[LiveRoomVM] play info failed: \(error)")
        }

        await roomInfo
        await danmaku
    }

    private func admitsLoad(_ requestSerial: UInt64, requestAdmission: (@MainActor () -> Bool)?) -> Bool {
        !Task.isCancelled && loadRequestSerial == requestSerial && (requestAdmission?() ?? true)
    }

    private func requireCurrentLoad(
        _ requestSerial: UInt64,
        requestAdmission: (@MainActor () -> Bool)?
    ) throws {
        guard admitsLoad(requestSerial, requestAdmission: requestAdmission) else {
            throw CancellationError()
        }
    }

    private func publishRoomInfo(_ room: LiveRoomInfo, publicationLease: PlayerOwnerLease?) {
        isPortraitHint = room.isPortrait
        roomInfo = room
        PlayerLog.log("[LiveRoomVM] room info loaded: \(room.title)")
        guard publicationLease != nil else { return }
        let player = PlayerViewModel.shared
        guard LiveNowPlayingPublicationPolicy.allows(
            callerLease: publicationLease,
            currentLease: player.currentOwnerLease
        ) else {
            PlayerLog.log("[LiveRoomVM] Now Playing publication rejected — stale or missing caller lease")
            return
        }
        player.setNowPlaying(
            title: room.title,
            artist: room.areaName,
            cover: room.coverURL(for: .roomPoster)
        )
    }

    func revokeLoadForRouteDeparture() {
        loadRequestSerial &+= 1
        if isLoading { isLoading = false }
        disconnect()
    }

    func disconnect() {
        danmakuConnectionGeneration &+= 1
        danmakuClient?.disconnect()
        danmakuClient = nil
    }

    @discardableResult
    func endPlayback() -> PlayerOwnerExitOutcome {
        guard let playerOwnerLease else { return .ownershipEnded }
        let outcome = PlayerViewModel.shared.endOwnerPlayback(lease: playerOwnerLease)
        guard outcome == .ownershipEnded else { return outcome }
        self.playerOwnerLease = nil
        committedRoomID = nil
        disconnect()
        return outcome
    }

    func switchQuality(roomID: Int, quality: Int) async {
        guard quality != currentQuality else { return }
        guard let lease = playerOwnerLease,
              lease.owner == PlayerViewModel.liveOwner(roomID),
              committedRoomID == roomID, PlayerViewModel.shared.isCurrentOwner(lease) else { return }
        currentQuality = quality
        let label = availableQualities.first(where: { $0.qn == quality })?.label ?? "\(quality)"
        appendChat(ChatMessage(
            uname: Self.systemSender,
            text: String(format: String(localized: "Switched to %@"), label),
            isSystem: true
        ))
        let selectedQuality = await PlayerViewModel.shared.loadLive(
            roomID: roomID,
            quality: quality,
            preservePlayState: true,
            owner: lease.owner,
            ownerLease: lease
        )
        if let selectedQuality {
            currentQuality = selectedQuality
            announceQualityFallback(requested: quality, actual: selectedQuality)
        }
    }

    private func announceQualityFallback(requested: Int, actual: Int) {
        guard requested != actual else { return }
        appendChat(ChatMessage(
            uname: Self.systemSender,
            text: String(
                format: String(localized: "%1$@ is unavailable — playing %2$@ instead"),
                qualityLabel(requested),
                qualityLabel(actual)
            ),
            isSystem: true
        ))
    }

    private func qualityLabel(_ qn: Int) -> String {
        availableQualities.first { $0.qn == qn }?.label
            ?? LiveQualityDescription.fallbackText(for: qn)
            ?? "\(qn)"
    }

    func sendDanmaku(roomID: Int, message: String) async {
        do {
            let result = try await LiveAPI.sendDanmaku(roomID: roomID, message: message)
            PlayerLog.log(
                "[LiveRoomVM] send result received modeInfo=\(result.modeInfo == nil ? "none" : "present")"
            )
        } catch {
            if Task.isCancelled { return }
            PlayerLog.log("[LiveRoomVM] send danmaku failed: \(error)")
            appendChat(ChatMessage(
                uname: Self.systemSender,
                text: String(format: String(localized: "Send failed: %@"), error.localizedDescription),
                isSystem: true
            ))
        }
    }

    // MARK: - WebSocket

    private func connectDanmaku(roomID: Int, generation: UInt64) async {
        do {
            let danmuInfo = try await LiveAPI.getDanmuInfo(roomID: roomID)
            guard !Task.isCancelled, generation == danmakuConnectionGeneration else {
                return
            }
            let host = danmuInfo.hostList?.first?.host ?? "broadcastlv.chat.bilibili.com"
            let token = danmuInfo.token

            let client = LiveDanmakuClient(
                onMessage: { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.danmakuConnectionGeneration == generation else {
                            return
                        }
                        self.appendChat(ChatMessage(
                            uid: event.uid,
                            uname: event.uname,
                            text: event.text,
                            medalName: event.medalName,
                            medalLevel: event.medalLevel,
                            medalColor: event.medalColor
                        ))
                    }
                },
                onPopularity: { [weak self] pop in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.danmakuConnectionGeneration == generation else {
                            return
                        }
                        self.popularity = pop
                    }
                }
            )
            client.connect(roomID: roomID, token: token, host: host)
            guard generation == danmakuConnectionGeneration else {
                client.disconnect()
                return
            }
            danmakuClient?.disconnect()
            danmakuClient = client

            appendChat(ChatMessage(
                uname: Self.systemSender,
                text: String(localized: "Chat connected"),
                isSystem: true
            ))
        } catch {
            guard !Task.isCancelled, generation == danmakuConnectionGeneration else {
                return
            }
            PlayerLog.log("[LiveRoomVM] getDanmuInfo failed: \(error)")
            appendChat(ChatMessage(
                uname: Self.systemSender,
                text: String(localized: "Chat connection failed"),
                isSystem: true
            ))
        }
    }

    private func appendChat(_ msg: ChatMessage) {
        chatMessages.append(msg)
        if chatMessages.count > 500 {
            chatMessages.removeFirst(chatMessages.count - 500)
        }
    }
}

private extension LiveRoomViewModel {
    // MARK: - Quality

    func updateQualities(from playInfo: LivePlayInfo) {
        var acceptQn: [Int] = []
        var apiCurrentQn: Int?
        if let streams = playInfo.playurlInfo?.playurl?.stream {
            for stream in streams {
                for format in stream.format {
                    for codec in format.codec {
                        if let aq = codec.acceptQn, !aq.isEmpty {
                            acceptQn = aq
                        }
                        if let qn = codec.currentQn {
                            apiCurrentQn = qn
                        }
                    }
                }
            }
        }

        if let apiCurrentQn, !acceptQn.contains(currentQuality) {
            currentQuality = apiCurrentQn
        }

        if let qnDescs = playInfo.playurlInfo?.playurl?.gQnDesc, !acceptQn.isEmpty {
            let acceptSet = Set(acceptQn)
            availableQualities = qnDescs
                .filter { acceptSet.contains($0.qn) }
                .map { LiveQuality(qn: $0.qn, desc: $0.desc) }
        } else if let qnDescs = playInfo.playurlInfo?.playurl?.gQnDesc, !qnDescs.isEmpty {
            availableQualities = qnDescs.map { LiveQuality(qn: $0.qn, desc: $0.desc) }
        } else {
            availableQualities = Self.fallbackQualities
        }
    }
}

private extension LiveQuality {
    init(qn: Int, desc: String) {
        self.qn = qn
        self.label = desc
    }
}

extension LiveRoomViewModel {
    func prefetchMetadata(roomID: Int, requestAdmission: (@MainActor () -> Bool)? = nil) async {
        guard !Task.isCancelled, requestAdmission?() ?? true else { return }
        if roomInfo?.roomId == roomID { return }
        do {
            let room = try await LiveAPI.getRoomInfo(roomID: roomID)
            guard !Task.isCancelled, requestAdmission?() ?? true else { return }
            if roomInfo == nil || roomInfo?.roomId == roomID {
                isPortraitHint = room.isPortrait
                roomInfo = room
            }
        } catch {
        }
    }
}

private extension LiveRoomViewModel {
    @MainActor
    private final class RoomLoadPublication {
        var lease: PlayerOwnerLease?
        var roomInfo: LiveRoomInfo?
    }

    private func loadRoomInfo(
        roomID: Int, requestSerial: UInt64,
        requestAdmission: (@MainActor () -> Bool)?, publication: RoomLoadPublication
    ) async {
        if let existing = roomInfo, existing.roomId == roomID {
            publication.roomInfo = existing
            publishRoomInfo(existing, publicationLease: publication.lease)
            return
        }
        do {
            let room = try await LiveAPI.getRoomInfo(roomID: roomID)
            try requireCurrentLoad(requestSerial, requestAdmission: requestAdmission)
            publication.roomInfo = room
            publishRoomInfo(room, publicationLease: publication.lease)
        } catch {
            guard admitsLoad(requestSerial, requestAdmission: requestAdmission) else { return }
            if roomInfo == nil, streamUnavailable == nil { self.error = "\(error)" }
            PlayerLog.log("[LiveRoomVM] room info failed: \(error)")
        }
    }
}
