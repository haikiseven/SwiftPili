import SwiftUI
import UIKit

extension VideoDetailView {
    func claimPlayerLeaseIfNeeded() -> PlayerOwnerLease? {
        guard isActiveVideoRoute else { return nil }
        if let existing = viewModel.playerLease, player.isCurrentOwner(existing) {
            return existing
        }
        player.endForeignOwnerForRouteActivation(incomingOwner: screenOwner)
        let lease = player.claimOwnerLease(owner: screenOwner)
        viewModel.adoptPlayerLease(lease)
        return lease
    }

    func activateIfNeeded(settlesNavigationAdmission: Bool) async {
        let targetID = videoID
        defer {
            if settlesNavigationAdmission {
                if isActiveVideoRoute {
                    coordinator.settleVideoNavigation(targetID)
                } else {
                    coordinator.cancelVideoNavigation(targetID)
                }
            }
        }
        guard isActiveVideoRoute, let lease = claimPlayerLeaseIfNeeded() else {
            if !isActiveVideoRoute {
                PlayerLog.log("[Navigation] historical VOD route activation ignored")
            }
            return
        }
        _ = await viewModel.load(id: targetID, owner: screenOwner, lease: lease)
        await handlePendingCommentNavigationIfNeeded()
    }

    func handlePendingCommentNavigationIfNeeded() async {
        let model = viewModel
        let requestedID = videoID
        let sourceGeneration = model.commentSourceGeneration
        guard isActiveVideoRoute,
              let request = coordinator.pendingCommentNavigation,
              request.anchor.videoID == requestedID,
              model.videoInfo != nil else { return }

        while model.commentsAwaitingInitialResponse,
              viewModel === model, videoID == requestedID,
              model.commentSourceGeneration == sourceGeneration,
              isActiveVideoRoute, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled, isActiveVideoRoute, viewModel === model,
              videoID == requestedID, model.commentSourceGeneration == sourceGeneration,
              model.hasCommentSource(for: requestedID),
              coordinator.consumeCommentNavigation(request, for: requestedID) else { return }

        openComments()
        let anchor = request.anchor
        let rootRpid = anchor.rootRpid ?? anchor.rpid
        let location = await model.locateComment(rpid: rootRpid)
        guard !Task.isCancelled, isActiveVideoRoute, viewModel === model,
              videoID == requestedID, model.commentSourceGeneration == sourceGeneration,
              model.hasCommentSource(for: requestedID),
              model.isCurrentCommentLocation(location) else { return }
        guard case .found(let intent) = location,
              let root = model.comments.first(where: { $0.rpid == rootRpid }) else {
            model.showToast(String(localized: "Comment is unavailable"), style: .error)
            return
        }
        if anchor.isNestedReply {
            openCommentThread(CommentThreadTarget(
                oid: intent.receipt.source.aid, type: 1, root: root, highlightRpid: anchor.rpid
            ))
        } else {
            commentTargetRpid = anchor.rpid
        }
    }

    func recordPageOffsets(_ offsets: [Int: CGFloat]) {
        pageOffsetStore.offsets.merge(offsets) { _, new in new }
        updatePlayerCondensation()
    }

    func updatePlayerCondensation() {
        guard !isWideLayout, player.isPortraitContent, !player.isFullscreenPresentationActive,
              player.ownerKey == screenOwner else { return }
        if player.portraitCondenseLocked { return }
        let now = CACurrentMediaTime()
        guard now - lastCondenseFlipAt > 0.4 else { return }
        let offset = pageOffsetStore.offsets[commentPresentation.isPresented ? 1 : 0] ?? 0
        let shouldCondense = PortraitVODCondensationPolicy.shouldAutoCollapse(
            offset: offset,
            isCondensed: player.inlineCondensed,
            hasManualChoice: player.portraitCondenseLocked
        )
        guard shouldCondense else { return }
        lastCondenseFlipAt = now
        PlayerLog.log(
            "[condense] auto-collapse "
            + "offset=\(Int(offset)) threshold=\(Int(PortraitVODCondensationPolicy.collapseThreshold)) "
            + "condensed=\(player.inlineCondensed)→\(shouldCondense) "
            + "locked=\(player.portraitCondenseLocked)"
        )
        withAnimation(motion.animation(normal: .spring(duration: 0.3))) {
            player.inlineCondensed = shouldCondense
        }
    }

    func offerDownload(_ info: VideoInfo) {
        let cid = viewModel.currentCid ?? info.cid
        if let existing = DownloadManager.shared.existing(bvid: info.bvid, cid: cid) {
            if existing.filesExist {
                viewModel.showToast(String(localized: "Already downloaded"), style: .success)
                return
            }
            guard DownloadManager.shared.delete(existing) else {
                viewModel.showToast(String(localized: "Download is being exported"), style: .progress)
                return
            }
        }
        if DownloadManager.shared.isActive(bvid: info.bvid, cid: cid) {
            viewModel.showToast(String(localized: "Download in progress"), style: .progress)
            return
        }
        let isImmediate = DownloadManager.shared.hasImmediateQualityList(
            aid: info.aid, cid: cid
        )
        if !isImmediate {
            viewModel.showToast(String(localized: "Preparing…"), style: .progress)
        }
        downloadRequestSerial &+= 1
        let serial = downloadRequestSerial
        Task {
            do {
                let qualities = try await DownloadManager.shared.availableQualities(
                    aid: info.aid, cid: cid
                )
                guard !Task.isCancelled,
                      downloadRequestSerial == serial,
                      viewModel.videoInfo?.aid == info.aid,
                      (viewModel.currentCid ?? viewModel.videoInfo?.cid) == cid
                else { return }
                activeSheet = .download(DownloadQualityPresentation(
                    info: info, cid: cid, qualities: qualities
                ))
            } catch {
                guard !Task.isCancelled, downloadRequestSerial == serial else { return }
                viewModel.showToast(error.localizedDescription, style: .error)
            }
        }
    }

    func shareItems(for info: VideoInfo) -> [Any] {
        if let shareImage = shareState.image { return [shareImage] }
        if let url = URL(string: "https://www.bilibili.com/video/\(info.bvid)") { return [url] }
        return [info.title]
    }

    func prepareShareCard(_ info: VideoInfo) {
        guard shareState.requestID == nil, !shareState.isPresenting, isActiveVideoRoute else { return }
        let id = UUID()
        let model = viewModel
        let request = ShareCardRenderer.Request(
            coverURL: info.pic, title: info.title, uploader: info.owner.name, description: info.desc,
            linkURL: "https://www.bilibili.com/video/\(info.bvid)",
            linkDisplay: "bilibili.com/video/\(info.bvid)",
            accent: UIColor(Color.biliAccent).resolvedColor(with: UITraitCollection.current)
        )
        shareState.requestID = id
        shareState.preparation = Task {
            defer {
                if shareState.requestID == id {
                    shareState.requestID = nil
                    shareState.preparation = nil
                }
            }
            guard let image = try? await ShareCardRenderer.prepare(request),
                  !Task.isCancelled, shareState.requestID == id,
                  isActiveVideoRoute, viewModel === model, model.videoInfo?.bvid == info.bvid else { return }
            shareState.image = image
            shareState.isPresenting = true
            ActivitySharePresenter.present(items: shareItems(for: info)) { completed in
                shareState.isPresenting = false
                guard completed else { return }
                Task { await viewModel.shareVideo() }
            }
        }
    }

    func cancelSharePreparation() {
        shareState.preparation?.cancel()
        shareState.preparation = nil
        shareState.requestID = nil
    }

    func startDownload(_ info: VideoInfo, cid: Int, quality: Int) {
        let duration = info.pages?.first(where: { $0.cid == cid })?.duration ?? info.duration
        viewModel.showToast(String(localized: "Download started"), style: .progress)
        Task {
            await DownloadManager.shared.startDownload(
                aid: info.aid, cid: cid, bvid: info.bvid, title: info.title,
                coverURL: info.pic, ownerName: info.owner.name,
                durationSeconds: duration, quality: quality
            )
        }
    }
}

struct DownloadQualityPresentation: Identifiable {
    let id = UUID()
    let info: VideoInfo
    let cid: Int
    let qualities: [DownloadQualityOption]
}

struct FavoriteFolderSheet: View {
    let folders: [FavFolderListResult.FavFolder]
    @State var selection: Set<Int>
    let onConfirm: (Set<Int>) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            List(folders) { folder in
                Button {
                    if selection.contains(folder.id) {
                        selection.remove(folder.id)
                    } else {
                        selection.insert(folder.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        FolderIconView(size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.title)
                                .foregroundStyle(.primary)
                            if let count = folder.mediaCount {
                                Text("\(count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: selection.contains(folder.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selection.contains(folder.id)
                                ? AnyShapeStyle(.biliAccent)
                                : AnyShapeStyle(.quaternary))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Add to Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onConfirm(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .overlay {
                if folders.isEmpty {
                    ContentUnavailableView(
                        "No Folders",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Could not load your favorite folders. Check the log for details.")
                    )
                }
            }
        }
        .appAdaptiveSheet(padSizing: .form)
    }
}

struct DownloadQualitySheet: View {
    let qualities: [DownloadQualityOption]
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            List {
                ForEach(qualities, id: \.code) { quality in
                    Button {
                        onSelect(quality.code)
                    } label: {
                        HStack {
                            Text(quality.label)
                            Spacer()
                            if let bytes = quality.estimatedBytes {
                                Text(DownloadStoragePolicy.byteLabel(bytes))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Download Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct VideoReportSheet: View {
    let aid: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            AuthedBiliWebView(url: URL(string: "https://www.bilibili.com/appeal/?avid=\(aid)")!)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Report Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .appAdaptiveSheet(compactDetents: [.large], padSizing: .page)
    }
}
