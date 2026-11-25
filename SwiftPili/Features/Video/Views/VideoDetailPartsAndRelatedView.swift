import SwiftUI

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
            durationSeconds: video.duration
        ) ?? VideoRouteTarget(videoID: .bvid(video.bvid))
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
                    }
                }
                .padding(.horizontal, horizontalInset)
            }
        }
        .padding(.bottom, 6)
        .appSelectionHaptic(userPicks: partPicks)
    }

    private func pickPart(_ page: VideoInfo.VideoPage) {
        let start = {
            guard pickedPartCid == page.cid else { return }
            Task {
                await model.switchPage(page)
                if pickedPartCid == page.cid { pickedPartCid = nil }
            }
        }
        guard let animation = motion.animation(normal: .snappy(duration: 0.24)) else {
            pickedPartCid = page.cid
            start()
            return
        }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            pickedPartCid = page.cid
        } completion: {
            start()
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
            CommentZoomSource(anchors: commentPresentation.anchors) {
                HotCommentsPreviewCard(
                    comments: Array(model.comments.prefix(2)),
                    total: info.stat.reply,
                    isLoading: model.isLoadingComments || model.commentsAwaitingInitialResponse,
                    isRegularWidth: sizeClass == .regular,
                    action: onOpenComments
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VideoDetailRelatedSectionView: View {
    let model: VideoDetailViewModel
    let columnWidth: CGFloat
    let horizontalInset: CGFloat
    let isCompact: Bool

    @ViewBuilder
    var body: some View {
        let videos = model.relatedVideos
        if !videos.isEmpty {
            if isCompact {
                relatedVideosGrid(videos)
            } else {
                UpNextShelf(
                    title: "Related",
                    videos: videos,
                    cardWidth: columnWidth >= VideoDetailLayoutMetrics.compactCapsuleMinimumWidth
                        ? VideoDetailLayoutMetrics.shelfCardWidth
                        : VideoDetailLayoutMetrics.phoneShelfCardWidth,
                    leadingInset: 0,
                    target: VideoDetailRouteTargetFactory.relatedTarget,
                    clipsContent: true
                )
                .padding(.horizontal, horizontalInset)
                .padding(.top, 4)
            }
        }
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
                    VideoNavigationButton(target: VideoDetailRouteTargetFactory.relatedTarget(for: video)) {
                        GridVideoCardView(
                            title: video.title,
                            sources: VideoCoverSources(widescreen: video.pic, fourByThree: video.mobileCoverURL),
                            duration: video.duration,
                            ownerName: video.owner.name,
                            viewCount: video.stat.view,
                            explicitColumnWidth: cardColumnWidth
                        )
                        .equatable()
                    }
                }
            }
            .rowCardColumnWidth(cardColumnWidth)
            .padding(.horizontal, horizontalInset)
        }
        .padding(.top, 4)
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
