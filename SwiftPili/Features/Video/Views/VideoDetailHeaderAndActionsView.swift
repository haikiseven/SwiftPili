import SwiftUI
import UIKit

struct VideoDetailColumnView: View {
    private enum ContentPhase: Hashable {
        case loading(VideoID)
        case loaded(aid: Int, videoID: VideoID)
    }

    @AppMotion private var motion
    let model: VideoDetailViewModel
    let requestedVideoID: VideoID
    let previewTitle: String
    let previewOwnerName: String
    let columnWidth: CGFloat
    let horizontalInset: CGFloat
    let showsHeroBar: Bool
    let showsCommentsCapsule: Bool
    let stagePresentation: DetailStagePresentation
    let isCompact: Bool
    let usesCompactPhoneActions: Bool
    let isActiveVideoRoute: Bool
    var isTransitionSettled: Bool = true
    let favoriteRequestInFlight: Bool
    let commentPresentation: CommentZoomPresentation
    let onHeroBarHeightChange: (CGFloat) -> Void
    let onOpenComments: () -> Void
    let onPresentFavorite: () -> Void
    let onShareCard: (VideoInfo) -> Void
    let onSelectMusic: (MusicDestination) -> Void
    var onSelectSeasonEpisode: ((VideoInfo.UGCSeason.Episode) -> Void)? = nil
    let onRetry: () -> Void

    @State private var isDescExpanded = false

    private var metadataRevealTransition: AnyTransition {
        motion.transition(
            normal: .asymmetric(
                insertion: .modifier(
                    active: VideoDetailMetadataRiseModifier(opacity: 0, yOffset: 6),
                    identity: VideoDetailMetadataRiseModifier(opacity: 1, yOffset: 0)
                ),
                removal: .opacity
            )
        )
    }

    var body: some View {
        let info: VideoInfo? = model.matchesLoadedVideo(requestedVideoID) ? model.videoInfo : nil
        let contentPhase: ContentPhase = info.map { .loaded(aid: $0.aid, videoID: requestedVideoID) }
            ?? .loading(requestedVideoID)
        if info != nil || model.isLoading || model.error == nil {
            VStack(alignment: .leading, spacing: 18) {
                if showsHeroBar {
                    if let info {
                        VStack(alignment: .leading, spacing: 18) {
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
                        }
                        .transition(.opacity)
                    } else {
                        VideoDetailHeroBarSkeletonView(
                            previewTitle: previewTitle,
                            previewOwnerName: previewOwnerName,
                            horizontalInset: horizontalInset,
                            onHeroBarHeightChange: onHeroBarHeightChange
                        )
                        .transition(.opacity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if info != nil || !previewTitle.isEmpty {
                            VideoDetailTitleHeaderView(
                                info: info,
                                model: model,
                                previewTitle: previewTitle,
                                horizontalInset: horizontalInset,
                                isDescExpanded: $isDescExpanded
                            )
                        } else {
                            VideoDetailTitleSkeletonView(horizontalInset: horizontalInset)
                        }
                        if let info {
                            VideoDetailStatsLineView(info: info, model: model)
                                .padding(.horizontal, horizontalInset)
                                .transition(metadataRevealTransition)
                        } else {
                            VideoDetailStatsLineSkeletonView(horizontalInset: horizontalInset)
                                .transition(.opacity)
                        }
                    }
                }

                if let info {
                    VStack(alignment: .leading, spacing: 18) {
                        if !showsHeroBar {
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
                        if let staff = info.staff, staff.count >= 2 {
                            VideoDetailJointCreatorsStripView(
                                staff: staff,
                                horizontalInset: horizontalInset
                            )
                        }
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
                        if let season = info.ugcSeason, !season.allEpisodes.isEmpty {
                            VideoDetailUGCSeasonSectionView(
                                season: season,
                                info: info,
                                model: model,
                                horizontalInset: horizontalInset,
                                onSelectSeasonEpisode: onSelectSeasonEpisode
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
                            isCompact: isCompact,
                            isTransitionSettled: isTransitionSettled
                        )
                    }
                    .transition(metadataRevealTransition)
                } else {
                    VideoDetailLoadingSkeletonView(
                        previewOwnerName: previewOwnerName,
                        columnWidth: columnWidth,
                        horizontalInset: horizontalInset,
                        showsHeroBar: showsHeroBar,
                        isCompact: isCompact,
                        usesCompactPhoneActions: usesCompactPhoneActions
                    )
                    .transition(.opacity)
                }
            }
            .animation(
                motion.feedbackAnimation(normal: .easeOut(duration: 0.22)),
                value: contentPhase
            )
            .onChange(of: requestedVideoID) { _, _ in
                isDescExpanded = false
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

private struct VideoDetailMetadataRiseModifier: ViewModifier {
    let opacity: Double
    let yOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: yOffset)
    }
}

private struct VideoDetailSkeletonPulse: ViewModifier {
    @AppMotion private var motion
    @State private var isDimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(isDimmed ? 0.45 : 0.85)
            .onAppear {
                guard !motion.reducesGeometry else { return }
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    isDimmed = true
                }
            }
    }
}

private struct VideoDetailTitleSkeletonView: View {
    let horizontalInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppFill.inset)
                .frame(maxWidth: .infinity)
                .frame(height: 18)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppFill.inset)
                .frame(width: 210, height: 18)
        }
        .padding(.horizontal, horizontalInset)
        .modifier(VideoDetailSkeletonPulse())
        .accessibilityHidden(true)
    }
}

private struct VideoDetailHeroBarSkeletonView: View {
    let previewTitle: String
    let previewOwnerName: String
    let horizontalInset: CGFloat
    let onHeroBarHeightChange: (CGFloat) -> Void

    var body: some View {
        CinematicHeroBar {
            if !previewTitle.isEmpty {
                Text(previewTitle)
                    .appFont(.editorialTitle)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppFill.inset)
                    .frame(width: 260, height: 22)
                    .modifier(VideoDetailSkeletonPulse())
            }
        } leading: {
            HStack(spacing: 10) {
                Circle()
                    .fill(AppFill.inset)
                    .frame(width: 36, height: 36)
                if !previewOwnerName.isEmpty {
                    Text(previewOwnerName)
                        .appFont(.screenOwner)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Capsule()
                        .fill(AppFill.inset)
                        .frame(width: 92, height: 14)
                }
            }
            .modifier(VideoDetailSkeletonPulse())
        } trailing: {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule()
                        .fill(AppFill.inset)
                        .frame(width: 66, height: 34)
                }
            }
            .modifier(VideoDetailSkeletonPulse())
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            onHeroBarHeightChange(height)
        }
        .padding(.horizontal, horizontalInset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(previewTitle.isEmpty ? Text("Loading…") : Text(previewTitle))
    }
}

private struct VideoDetailStatsLineSkeletonView: View {
    let horizontalInset: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(AppFill.inset)
                .frame(width: 84, height: 12)
            Capsule()
                .fill(AppFill.inset)
                .frame(width: 68, height: 12)
            Spacer()
            Capsule()
                .fill(AppFill.inset)
                .frame(width: 48, height: 12)
        }
        .padding(.horizontal, horizontalInset)
        .modifier(VideoDetailSkeletonPulse())
        .accessibilityHidden(true)
    }
}

private struct VideoDetailLoadingSkeletonView: View {
    let previewOwnerName: String
    let columnWidth: CGFloat
    let horizontalInset: CGFloat
    let showsHeroBar: Bool
    let isCompact: Bool
    let usesCompactPhoneActions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeroBar {
                VideoDetailStatsLineSkeletonView(horizontalInset: horizontalInset)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(AppFill.inset)
                            .frame(width: 36, height: 36)
                        if !previewOwnerName.isEmpty {
                            Text(previewOwnerName)
                                .appFont(.screenOwner)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Capsule()
                                .fill(AppFill.inset)
                                .frame(width: 112, height: 14)
                        }
                        Spacer(minLength: 8)
                        Capsule()
                            .fill(AppFill.inset)
                            .frame(width: 70, height: 28)
                    }

                    if usesCompactPhoneActions {
                        HStack(spacing: 6) {
                            ForEach(0..<5, id: \.self) { _ in
                                Capsule()
                                    .fill(AppFill.inset)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 34)
                            }
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(0..<5, id: \.self) { _ in
                                    Capsule()
                                        .fill(AppFill.inset)
                                        .frame(width: 68, height: 34)
                                }
                            }
                        }
                        .scrollDisabled(true)
                    }
                }
                .padding(.horizontal, horizontalInset)
                .modifier(VideoDetailSkeletonPulse())
            }

            if isCompact {
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(AppFill.inset.opacity(0.65))
                    .frame(height: 68)
                    .padding(.horizontal, horizontalInset)
                    .modifier(VideoDetailSkeletonPulse())
            }

            relatedSkeleton
                .modifier(VideoDetailSkeletonPulse())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading…"))
    }

    @ViewBuilder
    private var relatedSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(AppFill.inset)
                .frame(width: 72, height: 15)
                .padding(.horizontal, horizontalInset)

            if isCompact {
                let columnCount = columnWidth >= VideoDetailLayoutMetrics.compactCapsuleMinimumWidth ? 3 : 2
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount),
                    spacing: 12
                ) {
                    ForEach(0..<(columnCount * 2), id: \.self) { _ in
                        skeletonCard
                    }
                }
                .padding(.horizontal, horizontalInset)
            } else {
                let cardWidth = columnWidth >= VideoDetailLayoutMetrics.compactCapsuleMinimumWidth
                    ? VideoDetailLayoutMetrics.shelfCardWidth
                    : VideoDetailLayoutMetrics.phoneShelfCardWidth
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(0..<4, id: \.self) { _ in
                            skeletonCard
                                .frame(width: cardWidth)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                }
                .scrollDisabled(true)
            }
        }
        .padding(.top, 4)
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(AppFill.inset.opacity(0.65))
                .aspectRatio(16 / 9, contentMode: .fit)
            Capsule()
                .fill(AppFill.inset.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 12)
            Capsule()
                .fill(AppFill.nested)
                .frame(width: 96, height: 10)
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
            HStack(spacing: 10) {
                AvatarImage(urlString: info.owner.face, size: 36)

                Text(info.owner.name)
                    .appFont(.screenOwner)
                    .fontWeight(.medium)
                    .lineLimit(fillsWidth ? nil : 1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                coordinator.navigate(to: .userSpace(info.owner.mid))
            }

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
            } else if AuthManager.shared.isLoggedIn,
                      info.owner.mid > 0,
                      String(info.owner.mid) != AuthManager.shared.dedeUserID {
                Text("+ Follow")
                    .appFont(.controlLabel)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .hidden()
                    .background(Color(.tertiarySystemFill).opacity(0.55), in: Capsule())
                    .accessibilityHidden(true)
            }
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
    @State private var tripleRequestInFlight = false
    @State private var tripleHoldProgress: CGFloat = 0

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            TripleComboLikeButton(
                label: FormatUtils.viewCount(info.stat.like),
                isActive: model.isLiked,
                count: info.stat.like,
                compact: compact,
                externalActionInFlight: tripleRequestInFlight,
                holdProgress: $tripleHoldProgress,
                onTap: { await model.toggleLike() },
                onTripleCombo: {
                    guard !tripleRequestInFlight else { return }
                    tripleRequestInFlight = true
                    _ = await model.performTripleCombo()
                    tripleRequestInFlight = false
                }
            )

            DetailActionButton(
                icon: model.isCoined ? "b.circle.fill" : "b.circle",
                label: FormatUtils.viewCount(info.stat.coin),
                isActive: model.isCoined || tripleHoldProgress > 0.35,
                count: info.stat.coin,
                externalActionInFlight: coinRequestInFlight || tripleRequestInFlight,
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
                isActive: model.isFavorited || tripleHoldProgress > 0.65,
                count: info.stat.favorite,
                externalActionInFlight: favoriteRequestInFlight || tripleRequestInFlight,
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
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onShareCard(info)
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
        .buttonStyle(.appControl)
        .accessibilityIdentifier("videoDetail.share")
        .accessibilityLabel(Text("Share"))
        .accessibilityValue(Text(info.stat.share, format: .number))
    }
}

private struct TripleComboLikeButton: View {
    let label: String
    let isActive: Bool
    let count: Int
    let compact: Bool
    let externalActionInFlight: Bool
    @Binding var holdProgress: CGFloat
    let onTap: () async -> Void
    let onTripleCombo: () async -> Void

    @AppMotion private var motion
    @State private var tapInFlight = false
    @State private var holdTask: Task<Void, Never>?
    @State private var didFireLongPress = false

    private static let holdDurationSeconds: Double = 0.85
    private static let ringDelayMs = 150

    var body: some View {
        let isCharging = holdProgress > 0.01
        DetailActionButtonLabel(
            compact: compact,
            compactIconOnly: false,
            isActive: isActive || isCharging
        ) {
            ZStack {
                if isCharging {
                    Circle()
                        .stroke(Color.biliAccent.opacity(0.22), lineWidth: 2)
                        .frame(width: compact ? 22 : 24, height: compact ? 22 : 24)
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(
                            Color.biliAccent,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: compact ? 22 : 24, height: compact ? 22 : 24)
                }
                Image(systemName: (isActive || isCharging) ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(compact ? .subheadline : .body)
                    .foregroundStyle((isActive || isCharging) ? .biliAccent : .primary)
                    .scaleEffect(isCharging ? (1.0 + 0.08 * holdProgress) : 1.0)
                    .appToggleFeedback(
                        isOn: isActive,
                        userActionInFlight: tapInFlight || externalActionInFlight
                    )
            }
        } caption: {
            Text(label)
                .font(compact ? .footnote : .subheadline)
                .fontWeight(.medium)
                .appCountFeedback(value: count)
        }
        .onTapGesture {
            guard !didFireLongPress, !tapInFlight, !externalActionInFlight else { return }
            Task {
                tapInFlight = true
                await onTap()
                tapInFlight = false
            }
        }
        .onLongPressGesture(
            minimumDuration: Self.holdDurationSeconds,
            maximumDistance: 24,
            perform: {
                didFireLongPress = true
                cancelHoldAnimation(resetInstantly: false)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task { await onTripleCombo() }
            },
            onPressingChanged: { pressing in
                if pressing {
                    didFireLongPress = false
                    startHoldAnimation()
                } else {
                    cancelHoldAnimation(resetInstantly: false)
                    if didFireLongPress {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            didFireLongPress = false
                        }
                    }
                }
            }
        )
        .onDisappear {
            cancelHoldAnimation(resetInstantly: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text("Like"))
        .accessibilityHint(Text("Hold for Triple Combo"))
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAction(named: Text("Triple Combo")) {
            Task { await onTripleCombo() }
        }
    }

    private func startHoldAnimation() {
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.ringDelayMs))
            guard !Task.isCancelled else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let remaining = max(0.2, Self.holdDurationSeconds - Double(Self.ringDelayMs) / 1000.0)
            let step1 = remaining * 0.35
            let step2 = remaining * 0.30
            let step3 = remaining * 0.35
            withAnimation(motion.animation(normal: .linear(duration: step1))) {
                holdProgress = 0.35
            }
            try? await Task.sleep(for: .milliseconds(Int((step1 * 1000).rounded())))
            guard !Task.isCancelled else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(motion.animation(normal: .linear(duration: step2))) {
                holdProgress = 0.65
            }
            try? await Task.sleep(for: .milliseconds(Int((step2 * 1000).rounded())))
            guard !Task.isCancelled else { return }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            withAnimation(motion.animation(normal: .linear(duration: step3))) {
                holdProgress = 1.0
            }
        }
    }

    private func cancelHoldAnimation(resetInstantly: Bool) {
        holdTask?.cancel()
        holdTask = nil
        if resetInstantly {
            holdProgress = 0
        } else {
            withAnimation(motion.animation(normal: .easeOut(duration: 0.16))) {
                holdProgress = 0
            }
        }
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
