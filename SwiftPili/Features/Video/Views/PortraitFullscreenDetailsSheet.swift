import SwiftUI
import UIKit

struct PortraitFullscreenDetailsSheet: View {
    @AppMotion private var motion
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    let model: VideoDetailViewModel
    let coordinator: AppCoordinator
    let isRouteActive: @MainActor () -> Bool
    var onCollapseToStandardView: (@MainActor () -> Void)? = nil
    let onNavigateRoute: @MainActor (Route) -> Void
    let onSelectSeasonEpisode: @MainActor (
        VideoInfo.UGCSeason.Episode,
        VideoInfo.UGCSeason,
        String
    ) -> Void
    let onSyncContext: @MainActor () -> Void

    @State private var followRequestInFlight = false
    @State private var showDescriptionActions = false
    @State private var selectedMusic: MusicDestination?
    @State private var sheetContentWidth: CGFloat = WindowMetricsFallback.currentWidth

    var body: some View {
        NavigationStack {
            ObservedModel(model) { observedModel in
                ZStack(alignment: .bottom) {
                    if let info = observedModel.videoInfo {
                        detailsScrollContent(info: info, model: observedModel)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.width
                            } action: { newWidth in
                                if newWidth > 1, abs(sheetContentWidth - newWidth) > 0.5 {
                                    sheetContentWidth = newWidth
                                }
                            }
                            .modifier(PortraitDetailsSheetLinkHandoff { url, context in
                                handleURL(url, context: context)
                            })
                            .contentLinks(isCurrent: { isRouteActive() })
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    sheetToastOverlay(model: observedModel)
                }
            }
            .navigationTitle("Details & Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCollapseToStandardView {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                            onCollapseToStandardView()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.topthird.inset.filled")
                                    .font(.caption.weight(.semibold))
                                Text("Standard View")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        .accessibilityIdentifier("portrait.details.standardView")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(coordinator)
        .accentContentBoundary()
        .appAdaptiveSheet(compactDetents: [.medium, .large], padSizing: .form)
        .sheet(item: $selectedMusic) { destination in
            MusicDetailSheet(destination: destination) {
                selectedMusic = nil
            }
            .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .system).colorScheme)
        }
    }

    @ViewBuilder
    private func detailsScrollContent(
        info: VideoInfo,
        model: VideoDetailViewModel
    ) -> some View {
        let player = PlayerViewModel.shared
        let activeChapters = (model.playerLease != nil && player.currentOwnerLease == model.playerLease)
            ? player.videoChapters
            : []

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleAndStatsHeader(info: info, model: model)
                    .padding(.horizontal, 16)

                creatorRow(info: info, model: model)
                    .padding(.horizontal, 16)

                if let staff = info.staff, staff.count >= 2 {
                    jointCreatorsStrip(staff: staff)
                }

                if !activeChapters.isEmpty {
                    PortraitDetailsChapterSectionView(
                        chapters: activeChapters,
                        player: player,
                        onDismiss: { dismiss() }
                    )
                }

                if let pages = info.pages, pages.count > 1 {
                    VideoDetailPartsSelectorView(
                        pages: pages,
                        model: model,
                        horizontalInset: 16
                    )
                }

                if let season = info.ugcSeason, !season.allEpisodes.isEmpty {
                    VideoDetailUGCSeasonSectionView(
                        season: season,
                        info: info,
                        model: model,
                        horizontalInset: 16,
                        onSelectSeasonEpisode: { ep in
                            onSelectSeasonEpisode(ep, season, info.owner.name)
                        }
                    )
                }

                descriptionAndTagsSection(info: info, model: model)

                if !model.relatedVideos.isEmpty {
                    relatedVideosSection(videos: model.relatedVideos)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 36)
        }
    }

    private func titleAndStatsHeader(
        info: VideoInfo,
        model: VideoDetailViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(info.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            VideoDetailStatsLineView(info: info, model: model)

            if !info.bvid.isEmpty || info.aid > 0 {
                HStack(spacing: 8) {
                    if !info.bvid.isEmpty {
                        copyableIDCapsule(
                            label: info.bvid,
                            accessibilityTitle: "Copy BV ID",
                            model: model
                        )
                    }
                    if info.aid > 0 {
                        copyableIDCapsule(
                            label: "av\(info.aid)",
                            accessibilityTitle: "Copy AV ID",
                            model: model
                        )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func copyableIDCapsule(
        label: String,
        accessibilityTitle: LocalizedStringKey,
        model: VideoDetailViewModel
    ) -> some View {
        Button {
            UIPasteboard.general.string = label
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            model.showToast(String(localized: "Copied"), style: .success)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .font(.caption2.monospaced().weight(.medium))
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(AppFill.inset, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(verbatim: label))
    }

    private func creatorRow(
        info: VideoInfo,
        model: VideoDetailViewModel
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                guard info.owner.mid > 0 else { return }
                dismissAndNavigate(to: .userSpace(info.owner.mid))
            } label: {
                HStack(spacing: 10) {
                    AvatarImage(urlString: info.owner.face, size: 38)

                    Text(info.owner.name)
                        .appFont(.screenOwner)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(info.owner.mid <= 0)

            Spacer(minLength: 8)

            if let following = model.isFollowingUp {
                Button {
                    guard !followRequestInFlight else { return }
                    Task {
                        followRequestInFlight = true
                        await model.toggleFollowUp()
                        followRequestInFlight = false
                        onSyncContext()
                    }
                } label: {
                    (following ? Text("Following") : Text("+ Follow"))
                        .appFont(.controlLabel)
                        .fontWeight(.semibold)
                        .lineLimit(1)
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
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .hidden()
                    .background(Color(.tertiarySystemFill).opacity(0.55), in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            AppFill.inset,
            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        )
    }

    private func jointCreatorsStrip(staff: [VideoInfo.StaffMember]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionHeader("Joint Creators", count: staff.count)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(staff) { member in
                        Button {
                            guard member.mid > 0 else { return }
                            dismissAndNavigate(to: .userSpace(member.mid))
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
                            .contentShape(
                                RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                            )
                        }
                        .buttonStyle(.appControl)
                        .disabled(member.mid <= 0)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func descriptionAndTagsSection(
        info: VideoInfo,
        model: VideoDetailViewModel
    ) -> some View {
        let hasDesc = !info.desc.isEmpty && info.desc != "-"
        let tags = model.tags
        if hasDesc || !tags.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if hasDesc {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            DetailSectionHeader("Video Description")
                            Spacer(minLength: 8)
                            Button {
                                UIPasteboard.general.string = info.desc
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                model.showToast(String(localized: "Description copied"), style: .success)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2.weight(.semibold))
                                    Text("Copy")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(AppFill.inset, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.appControl)
                            .accessibilityLabel(Text("Copy Description"))
                        }

                        EmoteText.linkified(
                            info.desc,
                            links: info.descLinks,
                            accent: .biliAccent
                        )
                        .appFont(.screenSummary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            AppFill.inset,
                            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        )
                        .linkAwareLongPress(minimumDuration: 0.4) {
                            showDescriptionActions = true
                        }
                        .confirmationDialog(
                            "",
                            isPresented: $showDescriptionActions,
                            titleVisibility: .hidden
                        ) {
                            Button {
                                UIPasteboard.general.string = info.desc
                                model.showToast(String(localized: "Description copied"), style: .success)
                            } label: {
                                Text("Copy Description")
                            }
                        }
                    }
                }

                if !tags.isEmpty {
                    sheetTagsSection(model: model, tags: tags)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func sheetTagsSection(
        model: VideoDetailViewModel,
        tags: [VideoTag]
    ) -> some View {
        let tagSource = model.currentTagSource
        let musicTags = tags.filter(\.isMusic)
        let normalTags = tags.filter { !$0.isMusic }

        if !musicTags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(musicTags) { music in
                    let destination = model.musicDestination(for: music, source: tagSource)
                    Button {
                        guard isRouteActive(),
                              let current = model.musicDestination(for: music, source: tagSource) else {
                            return
                        }
                        coordinator.contentLinks.cancel()
                        selectedMusic = current
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
            PortraitDetailsNormalTagsView(
                tags: normalTags,
                onSelectTagSearch: { keyword in
                    dismissAndNavigate(to: .search(.all, keyword: keyword))
                }
            )
        }
    }

    private func relatedVideosSection(videos: [VideoCard]) -> some View {
        let columnCount = sheetContentWidth >= VideoDetailLayoutMetrics.compactCapsuleMinimumWidth ? 3 : 2
        let cardColumnWidth = FeedColumnPolicy.columnWidth(
            availableWidth: max(0, sheetContentWidth - 32),
            count: columnCount,
            spacing: 12
        )
        return VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader("Related", count: videos.count)
                .padding(.horizontal, 16)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount),
                spacing: 12
            ) {
                ForEach(videos) { video in
                    Button {
                        selectRelatedVideo(video)
                    } label: {
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
                    .buttonStyle(.plain)
                    .contextMenu {
                        relatedVideoContextMenu(for: video)
                    }
                }
            }
            .rowCardColumnWidth(cardColumnWidth)
            .padding(.horizontal, 16)
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

    private func selectRelatedVideo(_ video: VideoCard) {
        let target = VideoDetailRouteTargetFactory.relatedTarget(for: video).withoutZoom
        dismiss()
        if PlayerViewModel.shared.isFullscreen {
            PlayerViewModel.shared.exitFullscreen()
        }
        _ = coordinator.navigateToVideo(target)
    }

    private func sheetToastOverlay(model: VideoDetailViewModel) -> some View {
        let visibleToast = model.toast.flatMap { $0.style == .error ? nil : $0 }
        return Group {
            if let toast = visibleToast {
                ToastView(message: toast)
                    .padding(.bottom, 16)
            }
        }
        .animation(motion.feedbackAnimation(normal: .spring(duration: 0.3)), value: visibleToast)
        .allowsHitTesting(false)
    }

    private func handleURL(
        _ url: URL,
        context: ContentLinkContext?
    ) -> OpenURLAction.Result {
        if let seconds = EmoteText.seekSeconds(from: url) {
            let player = PlayerViewModel.shared
            if player.mode.isSeekable,
               player.currentURL != nil,
               player.duration <= 0 || seconds <= player.duration {
                PlayerLog.log("[Player] details sheet timestamp tapped → seek \(Int(seconds))s")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.seek(to: seconds)
                if !player.isPlaying {
                    player.play()
                }
            }
            dismiss()
            return .handled
        }

        if BiliURLParser.handlesContent(url) {
            guard let origin = coordinator.contentLinkOrigin(context) else { return .discarded }
            coordinator.contentLinks.open(url, context: origin) { route in
                origin.beforeNavigate()
                dismissAndNavigate(to: route)
            }
            return .handled
        }

        return .systemAction
    }

    private func dismissAndNavigate(to route: Route) {
        dismiss()
        onNavigateRoute(route)
    }
}

private struct PortraitDetailsChapterSectionView: View {
    let chapters: [VideoChapter]
    let player: PlayerViewModel
    let onDismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionHeader("Chapters", count: chapters.count)
                .padding(.horizontal, 16)

            PortraitDetailsChapterChipRow(
                chapters: chapters,
                player: player,
                onDismiss: onDismiss
            )
        }
    }
}

private struct PortraitDetailsChapterChipRow: View {
    let chapters: [VideoChapter]
    let player: PlayerViewModel
    let onDismiss: @MainActor () -> Void

    var body: some View {
        let activeChapterID = player.chapter(at: player.displayTime)?.id
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chapters) { chapter in
                    PortraitDetailsChapterChip(
                        chapter: chapter,
                        isCurrent: chapter.id == activeChapterID
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        player.seek(to: chapter.from)
                        if !player.isPlaying {
                            player.play()
                        }
                        onDismiss()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct PortraitDetailsChapterChip: View {
    let chapter: VideoChapter
    let isCurrent: Bool
    let action: @MainActor () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                Text(verbatim: FormatUtils.duration(Int(chapter.from)))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isCurrent ? Color.biliAccent : .secondary)
                Text(verbatim: chapter.title)
                    .font(.caption.weight(isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? Color.biliAccent : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(isCurrent ? Color.biliAccent.opacity(0.14) : AppFill.inset, in: shape)
            .overlay {
                if isCurrent {
                    shape.strokeBorder(Color.biliAccent.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.appControl)
    }
}

private struct PortraitDetailsNormalTagsView: View {
    let tags: [VideoTag]
    let onSelectTagSearch: (String) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags) { tag in
                Button {
                    if let jump = tag.jumpUrl, jump.hasPrefix("http"),
                       let url = URL(string: jump.httpsURL) {
                        openURL(url)
                    } else {
                        onSelectTagSearch(tag.tagName)
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

private struct PortraitDetailsSheetLinkHandoff: ViewModifier {
    @Environment(\.contentLinkContext) private var context
    @Environment(\.openURL) private var upstream
    let open: @MainActor (URL, ContentLinkContext?) -> OpenURLAction.Result

    func body(content: Content) -> some View {
        content
            .environment(\.contentLinkDefersToParent, true)
            .environment(\.openURL, OpenURLAction { url in
                if EmoteText.seekSeconds(from: url) != nil || BiliURLParser.handlesContent(url) {
                    return open(url, context)
                }
                upstream(url)
                return .handled
            })
    }
}
