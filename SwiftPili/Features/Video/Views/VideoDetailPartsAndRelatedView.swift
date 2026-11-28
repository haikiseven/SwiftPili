import SwiftUI
import UIKit

enum VideoDetailLayoutMetrics {
    static let compactCapsuleMinimumWidth: CGFloat = 600
    static let phoneShelfCardWidth: CGFloat = 220
    static let wideHeaderSingleRowWidth: CGFloat = 900
    static let cinematicTextInset: CGFloat = 4
    static let shelfCardWidth: CGFloat = 280
    static let panelComposerClearance: CGFloat = 84
    static let contentBottomPadding: CGFloat = 24
}

enum VideoDetailRouteTargetFactory {
    static func relatedTarget(for video: VideoCard) -> VideoRouteTarget {
        VideoRouteTarget.make(
            bvid: video.bvid,
            aid: nil,
            title: video.title,
            coverURL: video.pic,
            mobileCoverURL: video.mobileCoverURL,
            ownerName: video.owner.name,
            durationSeconds: video.duration,
            isPortraitHint: video.dimension?.isPortrait,
            aspectRatioHint: video.dimension?.effectiveAspectRatio
        ) ?? VideoRouteTarget(videoID: .bvid(video.bvid))
    }

    static func ugcSeasonTarget(
        for episode: VideoInfo.UGCSeason.Episode,
        fallbackOwnerName: String
    ) -> VideoRouteTarget {
        VideoRouteTarget.make(
            bvid: episode.bvid,
            aid: episode.aid > 0 ? episode.aid : nil,
            title: episode.displayTitle,
            coverURL: episode.coverURL ?? "",
            mobileCoverURL: nil,
            ownerName: fallbackOwnerName,
            durationSeconds: episode.durationSeconds ?? 0,
            isPortraitHint: episode.page?.dimension?.isPortrait,
            aspectRatioHint: episode.page?.dimension?.effectiveAspectRatio
        ) ?? VideoRouteTarget(videoID: episode.videoID)
    }
}

extension PlaybackQueueContext {
    static func ugcSeason(
        _ season: VideoInfo.UGCSeason,
        info: VideoInfo,
        videoID: VideoID,
        currentCid: Int
    ) -> PlaybackQueueContext? {
        let playableEpisodes = season.allEpisodes.filter { $0.aid > 0 && $0.cid > 0 }
        guard !playableEpisodes.isEmpty else { return nil }

        let pages = info.pages ?? []
        let expandCurrentPages = pages.count > 1
        var items: [PlaybackQueueItem] = []

        for episode in playableEpisodes {
            if episode.aid == info.aid, expandCurrentPages {
                items.append(contentsOf: makeSeasonPartItems(
                    season: season, info: info, pages: pages, videoID: videoID
                ))
            } else {
                items.append(makeSeasonEpisodeItem(
                    season: season, episode: episode, info: info
                ))
            }
        }

        guard items.count > 1 else { return nil }
        let selectedIndex = items.firstIndex(where: { $0.aid == info.aid && $0.cid == currentCid })
            ?? items.firstIndex(where: { $0.aid == info.aid })
            ?? 0
        return PlaybackQueueContext(
            kind: .ugcSeason(seasonId: season.id),
            items: items,
            currentIndex: selectedIndex
        )
    }

    private static func makeSeasonPartItems(
        season: VideoInfo.UGCSeason,
        info: VideoInfo,
        pages: [VideoInfo.VideoPage],
        videoID: VideoID
    ) -> [PlaybackQueueItem] {
        let bvid = info.bvid.isEmpty ? nil : info.bvid
        let cover = info.pic.isEmpty ? season.cover : info.pic
        return pages.map { page in
            let artist = page.part.isEmpty ? info.owner.name : "P\(page.page) \(page.part)"
            let aspectRatioHint = page.dimension?.effectiveAspectRatio
                ?? info.dimension?.effectiveAspectRatio
            let routeTarget = VideoRouteTarget(
                videoID: videoID,
                preview: PortraitPagingPreview(
                    title: info.title,
                    coverURL: info.pic,
                    ownerName: info.owner.name,
                    durationSeconds: page.duration,
                    isPortraitHint: page.dimension?.isPortrait ?? info.dimension?.isPortrait,
                    aspectRatioHint: aspectRatioHint
                ),
                zoomSourceID: nil
            )
            return PlaybackQueueItem(
                id: "ugc-season-\(season.id)-\(info.aid)-\(page.cid)",
                aid: info.aid,
                cid: page.cid,
                bvid: bvid,
                title: info.title,
                artist: artist,
                coverURL: cover,
                duration: TimeInterval(page.duration),
                isPortraitHint: page.dimension?.isPortrait ?? info.dimension?.isPortrait,
                aspectRatioHint: aspectRatioHint,
                source: .ugc,
                originRoute: .videoDetail(routeTarget),
                originScreenRoute: .video(videoID)
            )
        }
    }

    private static func makeSeasonEpisodeItem(
        season: VideoInfo.UGCSeason,
        episode: VideoInfo.UGCSeason.Episode,
        info: VideoInfo
    ) -> PlaybackQueueItem {
        let target = VideoDetailRouteTargetFactory.ugcSeasonTarget(
            for: episode,
            fallbackOwnerName: info.owner.name
        )
        let cover = episode.coverURL ?? season.cover ?? (info.pic.isEmpty ? nil : info.pic)
        return PlaybackQueueItem(
            id: "ugc-season-\(season.id)-\(episode.aid)-\(episode.cid)",
            aid: episode.aid,
            cid: episode.cid,
            bvid: episode.bvid,
            title: episode.displayTitle,
            artist: info.owner.name,
            coverURL: cover,
            duration: episode.durationSeconds.map(TimeInterval.init),
            isPortraitHint: episode.page?.dimension?.isPortrait,
            aspectRatioHint: episode.page?.dimension?.effectiveAspectRatio,
            source: .ugc,
            originRoute: .videoDetail(target),
            originScreenRoute: .video(episode.videoID)
        )
    }
}

extension VideoDetailViewModel {
    @discardableResult
    func performTripleCombo() async -> Bool {
        guard let aid = videoInfo?.aid else { return false }
        do {
            let result = try await VideoAPI.likeTriple(aid: aid)
            let didLike = result.like == true
            let didCoin = result.coin == true
            let didFav = result.fav == true

            if didLike {
                if !isLiked {
                    isLiked = true
                    videoInfo?.stat.like += 1
                }
            }
            if didCoin {
                let addedCoins = max(1, result.multiply ?? maxCoins)
                let targetCoins = min(maxCoins, max(coinCount, addedCoins))
                let delta = max(0, targetCoins - coinCount)
                coinCount = targetCoins
                videoInfo?.stat.coin += delta
            }
            if didFav {
                if !isFavorited {
                    isFavorited = true
                    videoInfo?.stat.favorite += 1
                }
            }
            tripleComboCelebrationTick &+= 1
            showToast(String(localized: "Triple Combo!"), style: .success)
            return true
        } catch {
            PlayerLog.log("[VideoDetailVM] triple combo failed: \(error)")
            guard !Task.isCancelled, !error.isCancellation else { return false }
            if case let .apiError(code, message) = error {
                showToast(
                    String(localized: "Triple combo failed (\(code)): \(message)"),
                    style: .error
                )
            } else {
                showToast(String(localized: "Triple combo failed"), style: .error)
            }
            return false
        }
    }

    func stopPlaybackForLocalFilterExit() {
        invalidateRetainedScreenData()
        let player = PlayerViewModel.shared
        if let lease = playerLease {
            if player.miniPlayer.retainsOwnerLease(lease) {
                player.dismissMiniPlayer(matching: lease)
            }
            if player.isCurrentOwner(lease) {
                player.clearPlaybackQueue()
                _ = player.endOwnerPlayback(lease: lease)
            }
        } else if player.currentAid == videoInfo?.aid {
            player.clearPlaybackQueue()
            player.endCurrentOwnerPlayback()
        }
        clearPlayerLeaseAfterLocalFilterExit()
    }
}

struct VideoDetailJointCreatorsStripView: View {
    let staff: [VideoInfo.StaffMember]
    let horizontalInset: CGFloat

    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionHeader("Joint Creators", count: staff.count)
                .padding(.horizontal, horizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(staff) { member in
                        Button {
                            coordinator.navigate(to: .userSpace(member.mid))
                        } label: {
                            HStack(spacing: 8) {
                                AvatarImage(urlString: member.face, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.name)
                                        .appFont(.controlLabel)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !member.title.isEmpty {
                                        let isPrimaryUP = member.title == "UP主"
                                        Text(member.title)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(isPrimaryUP ? Color.biliAccent : .secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                AppFill.inset,
                                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                        }
                        .buttonStyle(.appControl)
                    }
                }
                .padding(.horizontal, horizontalInset)
            }
        }
    }
}

struct VideoDetailPartsSelectorView: View {
    @AppMotion private var motion
    let pages: [VideoInfo.VideoPage]
    let model: VideoDetailViewModel
    let horizontalInset: CGFloat

    @State private var partPicks = 0
    @State private var pickedPartCid: Int?
    @Namespace private var partIndicator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionHeader("Parts", count: pages.count)
                .padding(.horizontal, horizontalInset)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pages, id: \.cid) { page in
                            let selected = page.cid == (pickedPartCid ?? model.currentCid)
                            PlaybackEntryChip(
                                label: "P\(page.page)",
                                detail: FormatUtils.duration(page.duration),
                                title: page.part,
                                isSelected: selected,
                                indicator: partIndicator
                            ) {
                                guard !selected else { return }
                                partPicks &+= 1
                                pickPart(page)
                            }
                            .id(page.cid)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                }
                .onAppear {
                    if let cid = pickedPartCid ?? model.currentCid {
                        proxy.scrollTo(cid, anchor: .center)
                    }
                }
                .onChange(of: model.currentCid) { _, cid in
                    guard let cid else { return }
                    withAnimation(motion.feedbackAnimation(normal: .snappy(duration: 0.24))) {
                        proxy.scrollTo(cid, anchor: .center)
                    }
                }
            }
        }
        .padding(.bottom, 6)
        .appSelectionHaptic(userPicks: partPicks)
    }

    private func pickPart(_ page: VideoInfo.VideoPage) {
        if let animation = motion.animation(normal: .snappy(duration: 0.24)) {
            withAnimation(animation) {
                pickedPartCid = page.cid
            }
        } else {
            pickedPartCid = page.cid
        }
        Task {
            await model.switchPage(page)
            if pickedPartCid == page.cid { pickedPartCid = nil }
        }
    }
}

struct VideoDetailUGCSeasonSectionView: View {
    let season: VideoInfo.UGCSeason
    let info: VideoInfo
    let model: VideoDetailViewModel
    let horizontalInset: CGFloat
    var onSelectSeasonEpisode: ((VideoInfo.UGCSeason.Episode) -> Void)? = nil

    @Environment(AppCoordinator.self) private var coordinator
    @State private var showFullSheet = false

    private var allEpisodes: [VideoInfo.UGCSeason.Episode] {
        season.allEpisodes
    }

    private var activeEpisodeScrollID: String? {
        let activeCid = model.currentCid
        let matched = allEpisodes.first(where: {
            $0.aid == info.aid && (activeCid == nil || $0.cid == activeCid)
        }) ?? allEpisodes.first(where: { $0.aid == info.aid })
        return matched.map(Self.episodeScrollID(for:))
    }

    private static func episodeScrollID(for episode: VideoInfo.UGCSeason.Episode) -> String {
        "\(episode.id)-\(episode.cid)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
                .padding(.horizontal, horizontalInset)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(allEpisodes.enumerated()), id: \.offset) { index, episode in
                            let episodeScrollID = Self.episodeScrollID(for: episode)
                            let selected = episodeScrollID == activeEpisodeScrollID
                            PlaybackEntryChip(
                                label: "EP\(index + 1)",
                                detail: episode.durationSeconds.map(FormatUtils.duration),
                                title: episode.displayTitle,
                                isSelected: selected
                            ) {
                                openEpisode(episode)
                            }
                            .id(episodeScrollID)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                }
                .onAppear {
                    if let activeEpisodeScrollID {
                        proxy.scrollTo(activeEpisodeScrollID, anchor: .center)
                    }
                }
                .onChange(of: activeEpisodeScrollID) { _, scrollID in
                    if let scrollID {
                        proxy.scrollTo(scrollID, anchor: .center)
                    }
                }
            }
        }
        .padding(.bottom, 6)
        .sheet(isPresented: $showFullSheet) {
            VideoDetailUGCSeasonSheet(
                season: season,
                currentAid: info.aid,
                currentCid: model.currentCid,
                fallbackOwnerName: info.owner.name
            ) { episode in
                openEpisode(episode)
            }
        }
    }

    private var headerRow: some View {
        Button {
            showFullSheet = true
        } label: {
            Group {
                if season.title.isEmpty {
                    DetailSectionHeader(title: "Collection", count: allEpisodes.count) {
                        headerChevron
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(verbatim: season.title)
                            .appFont(.sectionTitle)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("\(allEpisodes.count)")
                            .appFont(.messageMeta)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        headerChevron
                    }
                }
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var headerChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func openEpisode(_ episode: VideoInfo.UGCSeason.Episode) {
        if let onSelectSeasonEpisode {
            onSelectSeasonEpisode(episode)
            return
        }
        if episode.aid == info.aid {
            if episode.cid != model.currentCid,
               let page = info.pages?.first(where: { $0.cid == episode.cid }) {
                Task { await model.switchPage(page) }
            }
            return
        }
        let target = VideoDetailRouteTargetFactory.ugcSeasonTarget(
            for: episode,
            fallbackOwnerName: info.owner.name
        )
        _ = coordinator.navigateToVideo(target)
    }
}

private struct VideoDetailUGCSeasonSheet: View {
    let season: VideoInfo.UGCSeason
    let currentAid: Int
    var currentCid: Int? = nil
    let fallbackOwnerName: String
    let onSelectEpisode: (VideoInfo.UGCSeason.Episode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSectionID: Int

    private var sections: [VideoInfo.UGCSeason.Section] {
        (season.sections ?? []).filter { !($0.episodes ?? []).isEmpty }
    }

    private var activeEpisodes: [VideoInfo.UGCSeason.Episode] {
        sections.first(where: { $0.id == selectedSectionID })?.episodes ?? season.allEpisodes
    }

    private var activeEpisodeScrollID: String? {
        let matched = activeEpisodes.first(where: {
            $0.aid == currentAid && (currentCid == nil || $0.cid == currentCid)
        }) ?? activeEpisodes.first(where: { $0.aid == currentAid })
        return matched.map(Self.episodeScrollID(for:))
    }

    private static func episodeScrollID(for episode: VideoInfo.UGCSeason.Episode) -> String {
        "\(episode.id)-\(episode.cid)"
    }

    init(
        season: VideoInfo.UGCSeason,
        currentAid: Int,
        currentCid: Int? = nil,
        fallbackOwnerName: String,
        onSelectEpisode: @escaping (VideoInfo.UGCSeason.Episode) -> Void
    ) {
        self.season = season
        self.currentAid = currentAid
        self.currentCid = currentCid
        self.fallbackOwnerName = fallbackOwnerName
        self.onSelectEpisode = onSelectEpisode
        let nonEmpty = (season.sections ?? []).filter { !($0.episodes ?? []).isEmpty }
        let containing = nonEmpty.first { section in
            let episodes = section.episodes ?? []
            return episodes.contains {
                $0.aid == currentAid && (currentCid == nil || $0.cid == currentCid)
            }
        } ?? nonEmpty.first { section in
            (section.episodes ?? []).contains { $0.aid == currentAid }
        }
        _selectedSectionID = State(initialValue: containing?.id ?? nonEmpty.first?.id ?? 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if sections.count > 1 {
                    sectionPickerBar
                    Divider()
                }

                ScrollViewReader { proxy in
                    List(Array(activeEpisodes.enumerated()), id: \.offset) { index, episode in
                        let episodeScrollID = Self.episodeScrollID(for: episode)
                        let isCurrent = episodeScrollID == activeEpisodeScrollID
                        episodeRow(episode, index: index + 1, isCurrent: isCurrent)
                            .id(episodeScrollID)
                            .listRowBackground(
                                isCurrent ? Color.biliAccent.opacity(0.10) : nil
                            )
                    }
                    .listStyle(.plain)
                    .onAppear {
                        if let activeEpisodeScrollID {
                            proxy.scrollTo(activeEpisodeScrollID, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle(season.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .appAdaptiveSheet(compactDetents: [.medium], padSizing: .form)
        .accentContentBoundary()
    }

    private var sectionPickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sections) { section in
                    let isSelected = section.id == selectedSectionID
                    Button {
                        selectedSectionID = section.id
                    } label: {
                        Text(section.title.isEmpty ? String(localized: "Episodes") : section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.biliAccent : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? Color.biliAccent.opacity(0.14) : AppFill.inset,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func episodeRow(
        _ episode: VideoInfo.UGCSeason.Episode,
        index: Int,
        isCurrent: Bool
    ) -> some View {
        Button {
            dismiss()
            onSelectEpisode(episode)
        } label: {
            HStack(spacing: 12) {
                episodeThumbnail(episode, index: index)

                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.displayTitle)
                        .font(.subheadline.weight(isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? Color.biliAccent : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let views = episode.arc?.stat?.view {
                        Text("\(FormatUtils.viewCount(views)) plays")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(fallbackOwnerName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.biliAccent)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func episodeThumbnail(_ episode: VideoInfo.UGCSeason.Episode, index: Int) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let cover = episode.coverURL, !cover.isEmpty {
                CoverImage(
                    urlString: cover,
                    displaySize: CGSize(width: 104, height: 58),
                    contentMode: .fill
                )
                .frame(width: 104, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous)
                    .fill(AppFill.inset)
                    .frame(width: 104, height: 58)
                    .overlay {
                        Text("EP\(index)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            }

            if let seconds = episode.durationSeconds, seconds > 0 {
                Text(FormatUtils.duration(seconds))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
    }
}

struct VideoDetailHotCommentsPreviewView: View {
    let info: VideoInfo
    let model: VideoDetailViewModel
    let commentPresentation: CommentZoomPresentation
    let onOpenComments: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    @ViewBuilder
    var body: some View {
        if !model.commentsClosed {
            let displayedComments: [CommentResult.CommentItem] = if !model.comments.isEmpty {
                Array(model.comments.prefix(2))
            } else {
                model.cachedPreviewComments?.items ?? []
            }
            let showsLoadingSkeleton = (model.isLoadingComments || model.commentsAwaitingInitialResponse)
                && displayedComments.isEmpty
            CommentZoomSource(anchors: commentPresentation.anchors) {
                HotCommentsPreviewCard(
                    comments: displayedComments,
                    total: max(info.stat.reply, model.commentTotal),
                    isLoading: showsLoadingSkeleton,
                    isRegularWidth: sizeClass == .regular,
                    action: onOpenComments
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VideoDetailRelatedSkeletonCard: View {
    private var aspectRatio: CGFloat {
        CoverPresentationStore.shared.presentation.aspect.ratio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: VideoCardMetrics.cornerRadius, style: .continuous)
                .fill(AppFill.inset.opacity(0.65))
                .aspectRatio(aspectRatio, contentMode: .fit)
            footerSkeleton
        }
    }

    private var footerSkeleton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Placeholder\nTitle")
                .appFont(.cardTitle)
                .fontWeight(.medium)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .hidden()
                .overlay(alignment: .topLeading) { titleCapsules }
            Text(verbatim: "Placeholder")
                .appFont(.cardMeta)
                .lineLimit(1)
                .hidden()
                .overlay(alignment: .leading) { metaCapsule }
        }
        .padding(.horizontal, 2)
        .padding(.top, 6)
    }

    private var titleCapsules: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule()
                .fill(AppFill.inset.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 13)
            Capsule()
                .fill(AppFill.inset.opacity(0.8))
                .frame(width: 112, height: 13)
        }
        .padding(.top, 2)
    }

    private var metaCapsule: some View {
        Capsule()
            .fill(AppFill.nested)
            .frame(width: 84, height: 11)
    }
}

struct VideoDetailRelatedSectionView: View {
    private enum DisplayState: Equatable {
        case empty
        case placeholder
        case content
    }

    @AppMotion private var motion
    let model: VideoDetailViewModel
    let columnWidth: CGFloat
    let horizontalInset: CGFloat
    let isCompact: Bool
    var isTransitionSettled: Bool = true
    var isLoadingRelated: Bool = false

    var body: some View {
        let videos = model.relatedVideos
        let displayState: DisplayState = if videos.isEmpty {
            isLoadingRelated ? .placeholder : .empty
        } else if DetailDepartureHeightFreezePolicy.shouldDeferRelatedGrid(
            isCompact: isCompact,
            hasVideos: !videos.isEmpty,
            isTransitionSettled: isTransitionSettled
        ) {
            .placeholder
        } else {
            .content
        }
        Group {
            switch displayState {
            case .empty:
                EmptyView()
            case .placeholder:
                if isCompact {
                    relatedVideosPlaceholderGrid
                        .transition(.opacity)
                } else {
                    relatedVideosPlaceholderShelf
                        .transition(.opacity)
                }
            case .content:
                if isCompact {
                    relatedVideosGrid(videos)
                        .transition(.opacity)
                } else {
                    relatedVideosShelf(videos)
                        .transition(.opacity)
                }
            }
        }
        .animation(
            motion.feedbackAnimation(normal: .easeOut(duration: 0.22)),
            value: displayState
        )
    }

    private var relatedVideosPlaceholderGrid: some View {
        let columnCount = columnWidth >= VideoDetailLayoutMetrics.compactCapsuleMinimumWidth ? 3 : 2
        return VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Related")
                .padding(.horizontal, horizontalInset)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount),
                spacing: 12
            ) {
                ForEach(0..<(columnCount * 2), id: \.self) { _ in
                    VideoDetailRelatedSkeletonCard()
                }
            }
            .padding(.horizontal, horizontalInset)
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    private var relatedVideosPlaceholderShelf: some View {
        let cardWidth = columnWidth >= VideoDetailLayoutMetrics.compactCapsuleMinimumWidth
            ? VideoDetailLayoutMetrics.shelfCardWidth
            : VideoDetailLayoutMetrics.phoneShelfCardWidth
        return VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Related")
                .padding(.horizontal, horizontalInset)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<4, id: \.self) { _ in
                        VideoDetailRelatedSkeletonCard()
                            .frame(width: cardWidth)
                    }
                }
                .padding(.horizontal, horizontalInset)
            }
            .scrollDisabled(true)
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    private func relatedVideosShelf(_ videos: [VideoCard]) -> some View {
        let cardWidth = columnWidth >= VideoDetailLayoutMetrics.compactCapsuleMinimumWidth
            ? VideoDetailLayoutMetrics.shelfCardWidth
            : VideoDetailLayoutMetrics.phoneShelfCardWidth
        return VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Related")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(videos) { video in
                        relatedCard(video, width: cardWidth)
                            .frame(width: cardWidth)
                    }
                }
                .rowCardColumnWidth(cardWidth)
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, 4)
    }

    private func relatedVideosGrid(_ videos: [VideoCard]) -> some View {
        let columnCount = columnWidth >= VideoDetailLayoutMetrics.compactCapsuleMinimumWidth ? 3 : 2
        let cardColumnWidth = FeedColumnPolicy.columnWidth(
            availableWidth: max(0, columnWidth - horizontalInset * 2),
            count: columnCount,
            spacing: 12
        )
        return VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Related")
                .padding(.horizontal, horizontalInset)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount),
                spacing: 12
            ) {
                ForEach(videos) { video in
                    relatedCard(video, width: cardColumnWidth)
                }
            }
            .rowCardColumnWidth(cardColumnWidth)
            .padding(.horizontal, horizontalInset)
        }
        .padding(.top, 4)
    }

    private func relatedCard(_ video: VideoCard, width: CGFloat) -> some View {
        VideoNavigationButton(
            target: VideoDetailRouteTargetFactory.relatedTarget(for: video),
            usesZoomTransition: false
        ) {
            GridVideoCardView(
                title: video.title,
                sources: VideoCoverSources(widescreen: video.pic, fourByThree: video.mobileCoverURL),
                duration: video.duration,
                ownerName: video.owner.name,
                viewCount: video.stat.view,
                explicitColumnWidth: width
            )
            .equatable()
        }
        .contextMenu {
            relatedVideoContextMenu(for: video)
        }
    }

    @ViewBuilder
    private func relatedVideoContextMenu(for video: VideoCard) -> some View {
        let target = VideoCardContextMenuTarget(
            aid: video.aid,
            bvid: video.bvid,
            title: video.title,
            ownerMid: video.owner.mid,
            ownerName: video.owner.name,
            ownerFace: video.owner.face
        )
        if AuthManager.shared.isLoggedIn {
            Button {
                VideoCardContextMenuBuilder.performCloudDislike(target)
            } label: {
                Label("Not Interested", systemImage: "hand.thumbsdown")
            }
        }

        Button {
            VideoCardContextMenuBuilder.performLocalHideVideo(target)
        } label: {
            Label("Locally Hide This Video", systemImage: "eye.slash")
        }

        if video.owner.mid > 0 {
            let trimmed = video.owner.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmed.isEmpty ? "UID \(video.owner.mid)" : trimmed
            Button(role: .destructive) {
                VideoCardContextMenuBuilder.performLocalBlockUP(
                    mid: video.owner.mid,
                    name: displayName,
                    face: video.owner.face
                )
            } label: {
                Label(
                    String(format: String(localized: "Locally Block UP: %@"), displayName),
                    systemImage: "person.slash"
                )
            }
        }
    }
}

struct VideoDetailUnavailableStateView: View {
    let message: String
    let unavailability: PlaybackUnavailability?
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                unavailability != nil
                    ? String(localized: "Unavailable")
                    : String(localized: "Couldn't Load"),
                systemImage: unavailability?.symbolName ?? "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            if unavailability?.isRetryable ?? true {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.biliAccent)
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
