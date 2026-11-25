import SwiftUI
import UIKit

struct VideoDetailColumnView: View {
    @AppMotion private var motion
    let model: VideoDetailViewModel
    let previewTitle: String
    let columnWidth: CGFloat
    let horizontalInset: CGFloat
    let showsHeroBar: Bool
    let showsCommentsCapsule: Bool
    let stagePresentation: DetailStagePresentation
    let isCompact: Bool
    let usesCompactPhoneActions: Bool
    let isActiveVideoRoute: Bool
    let favoriteRequestInFlight: Bool
    let commentPresentation: CommentZoomPresentation
    let onHeroBarHeightChange: (CGFloat) -> Void
    let onOpenComments: () -> Void
    let onPresentFavorite: () -> Void
    let onShareCard: (VideoInfo) -> Void
    let onSelectMusic: (MusicDestination) -> Void
    let onRetry: () -> Void

    @State private var isDescExpanded = false

    var body: some View {
        let info = model.videoInfo
        if info != nil || model.isLoading || model.error == nil {
            VStack(alignment: .leading, spacing: 18) {
                if showsHeroBar, let info {
                    VideoDetailHeroBarView(
                        info: info,
                        model: model,
                        previewTitle: previewTitle,
                        columnWidth: columnWidth,
                        horizontalInset: horizontalInset,
                        stagePresentation: stagePresentation,
                        favoriteRequestInFlight: favoriteRequestInFlight,
                        isDescExpanded: $isDescExpanded,
                        onHeroBarHeightChange: onHeroBarHeightChange,
                        onOpenComments: onOpenComments,
                        onPresentFavorite: onPresentFavorite,
                        onShareCard: onShareCard
                    )
                    VideoDetailStatsLineView(info: info, model: model)
                        .padding(.horizontal, horizontalInset)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        VideoDetailTitleHeaderView(
                            info: info,
                            model: model,
                            previewTitle: previewTitle,
                            horizontalInset: horizontalInset,
                            isDescExpanded: $isDescExpanded
                        )
                        if let info {
                            VideoDetailStatsLineView(info: info, model: model)
                                .padding(.horizontal, horizontalInset)
                        }
                    }
                    if let info {
                        VideoDetailCreatorAndActionsView(
                            info: info,
                            model: model,
                            columnWidth: columnWidth,
                            horizontalInset: horizontalInset,
                            showsCommentsCapsule: showsCommentsCapsule,
                            stagePresentation: stagePresentation,
                            usesCompactPhoneActions: usesCompactPhoneActions,
                            favoriteRequestInFlight: favoriteRequestInFlight,
                            onOpenComments: onOpenComments,
                            onPresentFavorite: onPresentFavorite,
                            onShareCard: onShareCard
                        )
                    }
                }

                if let info {
                    if isDescExpanded {
                        VideoDetailDescriptionBlockView(
                            info: info,
                            model: model,
                            horizontalInset: horizontalInset,
                            isActiveVideoRoute: isActiveVideoRoute,
                            isDescExpanded: $isDescExpanded,
                            onSelectMusic: onSelectMusic
                        )
                        .transition(motion.transition(normal: .opacity))
                    }
                    if let pages = info.pages, pages.count > 1 {
                        VideoDetailPartsSelectorView(
                            pages: pages,
                            model: model,
                            horizontalInset: horizontalInset
                        )
                    }
                    if isCompact {
                        VideoDetailHotCommentsPreviewView(
                            info: info,
                            model: model,
                            commentPresentation: commentPresentation,
                            onOpenComments: onOpenComments
                        )
                        .padding(.horizontal, horizontalInset)
                    }
                    VideoDetailRelatedSectionView(
                        model: model,
                        columnWidth: columnWidth,
                        horizontalInset: horizontalInset,
                        isCompact: isCompact
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
        } else if let message = model.error {
            VideoDetailUnavailableStateView(
                message: message,
                unavailability: model.unavailability,
                onRetry: onRetry
            )
        }
    }
}

struct VideoDetailTitleHeaderView: View {
    @AppMotion private var motion
    let info: VideoInfo?
    let model: VideoDetailViewModel
    let previewTitle: String
    let horizontalInset: CGFloat
    var fixedLineLimit: Int?
    @Binding var isDescExpanded: Bool

    var body: some View {
        let titleText = info?.title ?? previewTitle
        let hasDesc = info.map { !$0.desc.isEmpty && $0.desc != "-" } ?? false
        let canExpand = info != nil && (hasDesc || !titleText.isEmpty || !model.tags.isEmpty)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(titleText)
                .appFont(.editorialTitle)
                .fontWeight(.bold)
                .lineLimit(fixedLineLimit ?? (isDescExpanded ? nil : 2))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canExpand {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .appDisclosureRotation(isExpanded: isDescExpanded)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard canExpand else { return }
            withAnimation(motion.animation(normal: .snappy(duration: 0.22, extraBounce: 0))) {
                isDescExpanded.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canExpand ? .isButton : [])
        .accessibilityHint(
            canExpand
                ? (isDescExpanded ? Text("Show Less") : Text("Show More"))
                : Text("")
        )
        .padding(.horizontal, horizontalInset)
    }
}

struct VideoDetailStatsLineView: View {
    let info: VideoInfo
    let model: VideoDetailViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text("\(FormatUtils.viewCount(info.stat.view)) plays")
            Text("\(FormatUtils.viewCount(info.stat.danmaku)) danmaku")
            if let online = model.onlineCount, !online.isEmpty {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                    Text("\(online) watching")
                }
            }
            Spacer()
            Text(FormatUtils.timeAgo(from: info.pubdate))
        }
        .appFont(.screenStat)
        .foregroundStyle(.secondary)
    }
}

struct VideoDetailOwnerRowView: View {
    let info: VideoInfo
    let model: VideoDetailViewModel
    let fillsWidth: Bool

    @Environment(AppCoordinator.self) private var coordinator
    @State private var followRequestInFlight = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarImage(urlString: info.owner.face, size: 36)

            Text(info.owner.name)
                .appFont(.screenOwner)
                .fontWeight(.medium)
                .lineLimit(fillsWidth ? nil : 1)

            if fillsWidth { Spacer() }

            if let following = model.isFollowingUp {
                Button {
                    Task {
                        followRequestInFlight = true
                        await model.toggleFollowUp()
                        followRequestInFlight = false
                    }
                } label: {
                    (following ? Text("Following") : Text("+ Follow"))
                        .appFont(.controlLabel)
                        .fontWeight(.semibold)
                        .foregroundStyle(following ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            following
                                ? AnyShapeStyle(Color(.tertiarySystemFill))
                                : AnyShapeStyle(Color.biliAccent),
                            in: Capsule()
                        )
                        .appStateLabelFeedback(isOn: following, userActionInFlight: followRequestInFlight)
                }
                .buttonStyle(.appControl)
                .disabled(followRequestInFlight)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            coordinator.navigate(to: .userSpace(info.owner.mid))
        }
    }
}

struct VideoDetailCreatorAndActionsView: View {
    let info: VideoInfo
    let model: VideoDetailViewModel
    let columnWidth: CGFloat
    let horizontalInset: CGFloat
    let showsCommentsCapsule: Bool
    let stagePresentation: DetailStagePresentation
    let usesCompactPhoneActions: Bool
    let favoriteRequestInFlight: Bool
    let onOpenComments: () -> Void
    let onPresentFavorite: () -> Void
    let onShareCard: (VideoInfo) -> Void

    var body: some View {
        if usesCompactPhoneActions {
            VStack(alignment: .leading, spacing: 12) {
                VideoDetailOwnerRowView(info: info, model: model, fillsWidth: true)
                VideoDetailActionBarView(
                    info: info,
                    model: model,
                    compact: true,
                    favoriteRequestInFlight: favoriteRequestInFlight,
                    onPresentFavorite: onPresentFavorite,
                    onShareCard: onShareCard
                )
            }
            .padding(.horizontal, horizontalInset)
        } else if columnWidth >= VideoDetailLayoutMetrics.wideHeaderSingleRowWidth {
            HStack(spacing: 12) {
                VideoDetailOwnerRowView(info: info, model: model, fillsWidth: false)
                Spacer(minLength: 0)
                if showsCommentsCapsule {
                    VideoDetailHeroCommentsCapsule(
                        info: info,
                        model: model,
                        stagePresentation: stagePresentation,
                        onOpenComments: onOpenComments
                    )
                }
                VideoDetailActionBarView(
                    info: info,
                    model: model,
                    compact: false,
                    favoriteRequestInFlight: favoriteRequestInFlight,
                    onPresentFavorite: onPresentFavorite,
                    onShareCard: onShareCard
                )
            }
            .padding(.horizontal, horizontalInset)
        } else if columnWidth >= VideoDetailLayoutMetrics.compactCapsuleMinimumWidth {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VideoDetailOwnerRowView(info: info, model: model, fillsWidth: false)
                    Spacer(minLength: 0)
                    if showsCommentsCapsule {
                        VideoDetailHeroCommentsCapsule(
                            info: info,
                            model: model,
                            stagePresentation: stagePresentation,
                            onOpenComments: onOpenComments
                        )
                    }
                }
                VideoDetailActionBarView(
                    info: info,
                    model: model,
                    compact: false,
                    favoriteRequestInFlight: favoriteRequestInFlight,
                    onPresentFavorite: onPresentFavorite,
                    onShareCard: onShareCard
                )
            }
            .padding(.horizontal, horizontalInset)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                VideoDetailOwnerRowView(info: info, model: model, fillsWidth: true)
                    .padding(.horizontal, horizontalInset)
                ScrollView(.horizontal, showsIndicators: false) {
                    VideoDetailActionBarView(
                        info: info,
                        model: model,
                        compact: false,
                        favoriteRequestInFlight: favoriteRequestInFlight,
                        onPresentFavorite: onPresentFavorite,
                        onShareCard: onShareCard
                    )
                    .padding(.horizontal, horizontalInset)
                }
                .scrollClipDisabled()
            }
        }
    }
}

struct VideoDetailHeroBarView: View {
    let info: VideoInfo
    let model: VideoDetailViewModel
    let previewTitle: String
    let columnWidth: CGFloat
    let horizontalInset: CGFloat
    let stagePresentation: DetailStagePresentation
    let favoriteRequestInFlight: Bool
    @Binding var isDescExpanded: Bool
    let onHeroBarHeightChange: (CGFloat) -> Void
    let onOpenComments: () -> Void
    let onPresentFavorite: () -> Void
    let onShareCard: (VideoInfo) -> Void

    var body: some View {
        CinematicHeroBar {
            VideoDetailTitleHeaderView(
                info: info,
                model: model,
                previewTitle: previewTitle,
                horizontalInset: 0,
                fixedLineLimit: 1,
                isDescExpanded: $isDescExpanded
            )
        } leading: {
            VideoDetailOwnerRowView(info: info, model: model, fillsWidth: false)
        } trailing: {
            let actions = HStack(spacing: 8) {
                VideoDetailHeroCommentsCapsule(
                    info: info,
                    model: model,
                    stagePresentation: stagePresentation,
                    onOpenComments: onOpenComments
                )
                VideoDetailActionBarView(
                    info: info,
                    model: model,
                    compact: false,
                    favoriteRequestInFlight: favoriteRequestInFlight,
                    onPresentFavorite: onPresentFavorite,
                    onShareCard: onShareCard
                )
            }
            if columnWidth >= VideoDetailLayoutMetrics.wideHeaderSingleRowWidth {
                actions
            } else {
                ScrollView(.horizontal, showsIndicators: false) { actions }
                    .scrollClipDisabled()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            onHeroBarHeightChange(height)
        }
        .padding(.horizontal, horizontalInset)
    }
}

struct VideoDetailHeroCommentsCapsule: View {
    let info: VideoInfo
    let model: VideoDetailViewModel
    let stagePresentation: DetailStagePresentation
    let onOpenComments: () -> Void

    @ViewBuilder
    var body: some View {
        if stagePresentation == .hero, !model.commentsClosed {
            Button(action: onOpenComments) {
                DetailActionButtonLabel {
                    Image(systemName: "text.bubble")
                        .font(.body)
                } caption: {
                    Text(FormatUtils.viewCount(info.stat.reply))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
            }
            .buttonStyle(.appControl)
            .accessibilityLabel(Text("Comments"))
            .transition(.opacity)
        }
    }
}

struct VideoDetailActionBarView: View {
    let info: VideoInfo
    let model: VideoDetailViewModel
    let compact: Bool
    let favoriteRequestInFlight: Bool
    let onPresentFavorite: () -> Void
    let onShareCard: (VideoInfo) -> Void

    @State private var showCoinDialog = false
    @State private var coinRequestInFlight = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            DetailActionButton(
                icon: model.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                label: FormatUtils.viewCount(info.stat.like),
                isActive: model.isLiked,
                count: info.stat.like,
                compact: compact,
                accessibilityTitle: "Like"
            ) {
                await model.toggleLike()
            }
            DetailActionButton(
                icon: model.isCoined ? "b.circle.fill" : "b.circle",
                label: FormatUtils.viewCount(info.stat.coin),
                isActive: model.isCoined,
                count: info.stat.coin,
                externalActionInFlight: coinRequestInFlight,
                compact: compact,
                accessibilityTitle: "Coin"
            ) {
                if model.maxCoins - model.coinCount >= 2 {
                    showCoinDialog = true
                } else {
                    await model.addCoin(multiply: 1)
                }
            }
            .confirmationDialog("Coin this video", isPresented: $showCoinDialog, titleVisibility: .visible) {
                Button("Give 1 Coin") { addCoinFromDialog(1) }
                Button("Give 2 Coins") { addCoinFromDialog(2) }
            }
            DetailActionButton(
                icon: model.isFavorited ? "star.fill" : "star",
                label: FormatUtils.viewCount(info.stat.favorite),
                isActive: model.isFavorited,
                count: info.stat.favorite,
                externalActionInFlight: favoriteRequestInFlight,
                compact: compact,
                accessibilityTitle: "Favorite"
            ) {
                await model.loadFavFolders()
                onPresentFavorite()
            }
            DetailActionButton(
                icon: model.isInWatchLater ? "clock.fill" : "clock",
                label: String(localized: "Watch"),
                isActive: model.isInWatchLater,
                compact: compact,
                showsCaption: !compact,
                accessibilityTitle: "Watch Later"
            ) {
                await model.toggleWatchLater()
            }
            shareMenu
        }
    }

    private func addCoinFromDialog(_ coins: Int) {
        Task {
            coinRequestInFlight = true
            await model.addCoin(multiply: coins)
            coinRequestInFlight = false
        }
    }

    private var shareMenu: some View {
        Menu {
            Button {
                onShareCard(info)
            } label: {
                Label("System Share", systemImage: "square.and.arrow.up")
            }

            Button {
                UIPasteboard.general.string = "https://www.bilibili.com/video/\(info.bvid)"
                Task { await model.shareVideo() }
            } label: {
                Label("Copy Link", systemImage: "link")
            }

            Button {
                UIPasteboard.general.string = info.bvid
            } label: {
                Label("Copy BV ID", systemImage: "doc.on.doc")
            }

            Button {
                UIPasteboard.general.string = String(info.aid)
            } label: {
                Label("Copy AV ID", systemImage: "number")
            }
        } label: {
            DetailActionButtonLabel(
                compact: compact,
                compactIconOnly: false,
                isActive: model.hasShared
            ) {
                Image(systemName: model.hasShared ? "arrowshape.turn.up.right.fill" : "arrowshape.turn.up.right")
                    .font(compact ? .subheadline : .body)
                    .foregroundStyle(Color.primary)
            } caption: {
                Text(FormatUtils.viewCount(info.stat.share))
                    .appFont(.controlLabel)
                    .foregroundStyle(Color.primary)
            }
        }
        .accessibilityLabel(Text("Share"))
        .accessibilityValue(Text(info.stat.share, format: .number))
    }
}

struct VideoDetailDescriptionBlockView: View {
    @AppMotion private var motion
    let info: VideoInfo
    let model: VideoDetailViewModel
    let horizontalInset: CGFloat
    let isActiveVideoRoute: Bool
    @Binding var isDescExpanded: Bool
    let onSelectMusic: (MusicDestination) -> Void

    @State private var showDescriptionActions = false

    @ViewBuilder
    var body: some View {
        let hasDesc = !info.desc.isEmpty && info.desc != "-"
        let tags = model.tags
        if hasDesc || !tags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if hasDesc {
                    EmoteText.linkified(
                        info.desc, links: info.descLinks, accent: .biliAccent
                    )
                        .appFont(.screenSummary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .linkAwareLongPress(minimumDuration: 0.4) {
                            showDescriptionActions = true
                        }
                        .linkAwareTap {
                            withAnimation(motion.animation(normal: .snappy(duration: 0.22, extraBounce: 0))) {
                                isDescExpanded.toggle()
                            }
                        }
                        .confirmationDialog(
                            "", isPresented: $showDescriptionActions, titleVisibility: .hidden
                        ) {
                            Button {
                                UIPasteboard.general.string = info.desc
                            } label: {
                                Text("Copy Description")
                            }
                        }
                }

                if !tags.isEmpty {
                    VideoDetailDescriptionTagsView(
                        model: model,
                        tags: tags,
                        isActiveVideoRoute: isActiveVideoRoute,
                        onSelectMusic: onSelectMusic
                    )
                }
            }
            .padding(.horizontal, horizontalInset)
        }
    }
}

private struct VideoDetailDescriptionTagsView: View {
    let model: VideoDetailViewModel
    let tags: [VideoTag]
    let isActiveVideoRoute: Bool
    let onSelectMusic: (MusicDestination) -> Void

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openURL) private var openURL

    @ViewBuilder
    var body: some View {
        let tagSource = model.currentTagSource
        let musicTags = tags.filter(\.isMusic)
        let normalTags = tags.filter { !$0.isMusic }

        if !musicTags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(musicTags) { music in
                    let destination = model.musicDestination(for: music, source: tagSource)
                    Button {
                        guard isActiveVideoRoute,
                              let current = model.musicDestination(for: music, source: tagSource) else { return }
                        coordinator.contentLinks.cancel()
                        onSelectMusic(current)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note")
                            Text(music.tagName)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if destination != nil {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.biliAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.biliAccent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: AppRadius.thumbnail)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(destination == nil)
                }
            }
        }

        if !normalTags.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(normalTags) { tag in
                    Button {
                        if let jump = tag.jumpUrl, jump.hasPrefix("http"),
                           let url = URL(string: jump.httpsURL) {
                            openURL(url)
                        } else {
                            coordinator.navigate(to: .search(.all, keyword: tag.tagName))
                        }
                    } label: {
                        Text(tag.tagName)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(.secondary)
                            .background(AppFill.nested, in: Capsule())
                            .frame(minHeight: 36)
                            .contentShape(.interaction, Capsule().inset(by: -4))
                    }
                    .buttonStyle(.appControl)
                }
            }
        }
    }
}
