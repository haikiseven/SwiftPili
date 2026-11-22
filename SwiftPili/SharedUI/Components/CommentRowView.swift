import Kingfisher
import SwiftUI

struct CommentRowView: View {
    /// Read here rather than left to `.appFont`, because the comment BODY is
    /// an `EmoteText` and needs a concrete face: the inline stickers are cut
    /// from that font's metrics, so the type step has to reach them or a wide
    /// window would grow the words and leave the emotes behind.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    let comment: CommentResult.CommentItem
    /// mid of the video uploader — comments by them get an "UP" badge.
    var upMid: Int?
    /// The main feed shows a 3-reply preview inline; the thread view lists
    /// all replies itself and must disable this or every reply appears twice.
    var showsInlineReplies = true
    var onReply: ((CommentResult.CommentItem) -> Void)?
    var onViewThread: ((CommentResult.CommentItem) -> Void)?
    /// Tapping a specific reply in the inline preview: opens the thread AND
    /// says which reply to land on. Two arguments because a `CommentItem`
    /// carries no pointer to its ancestor — `root` and `parent` are not in
    /// `CodingKeys` — and the root is only in scope here because a preview reply
    /// is rendered lexically inside its root's row.
    var onOpenReply: ((CommentResult.CommentItem, Int) -> Void)?
    var onImageTap: ((ImagePreviewItem) -> Void)?
    /// Avatar tap → user profile. Defaults to pushing .userSpace on the
    /// main stack; sheet containers override it to dismiss themselves
    /// first (a push under an open sheet is invisible).
    var onAvatarTap: ((Int) -> Void)?
    /// Called after this row's comment was deleted on the server (own
    /// comments only); the parent removes it from its list.
    var onDelete: (() -> Void)?

    @Environment(AppCoordinator.self) private var coordinator
    @State private var actionState = CommentActionState()

    private func openProfile(_ mid: Int) {
        guard mid > 0 else { return }
        if let onAvatarTap {
            onAvatarTap(mid)
        } else {
            coordinator.navigate(to: .userSpace(mid))
        }
    }

    var body: some View {
        let _ = UIHitchMonitor.countBody("row")
        BlockedCollapsible(mid: comment.mid, uname: comment.member.uname) {
            CommentAIFilterRowContainer(comment: comment, upMid: upMid) { aiAssessment, onInspectAI in
                commentBody(aiAssessment: aiAssessment, onInspectAI: onInspectAI)
            }
        }
    }

    private func commentBody(
        aiAssessment: CommentAIAssessment?,
        onInspectAI: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarImage(urlString: comment.member.avatar.httpsURL, size: 36)
            .contentShape(Circle())
            .onTapGesture { openProfile(comment.mid) }

            // 3pt stack spacing keeps attachments tight; the body adds 2pt bottom padding for a 5pt gap below text.
            VStack(alignment: .leading, spacing: 3) {
                CommentAuthorHeader(
                    comment: comment,
                    upMid: upMid,
                    showsPinned: true,
                    actionState: actionState,
                    onDelete: onDelete,
                    aiAssessment: aiAssessment,
                    onInspectAI: onInspectAI
                )

                EmoteText(
                    message: comment.content.displayMessage,
                    emotes: Self.emoteMap(comment),
                    links: comment.content.resolvedLinks,
                    font: .app(AppTypeScale.style(.commentBody, isRegularWidth: isRegularWidth)),
                    collapsedLineLimit: 6,
                    detectTimestamps: true
                )
                .lineSpacing(2)
                .commentContextActions(comment, state: actionState, onDelete: onDelete)
                // Tapping body text opens reply when `onReply` is provided, while preserving `Text` link precedence and sibling media/card taps.
                .modifier(TapToReply(action: onReply.map { act in { act(comment) } }))
                .padding(.top, 1)
                .padding(.bottom, 2)

                if comment.upAction?.like == true {
                    UPLikedTag()
                }

                if let vote = comment.content.vote, let voteId = vote.id {
                    VoteCardView(voteId: voteId, initialTitle: vote.title)
                }

                let media = Self.mediaItems(comment)
                if !media.isEmpty {
                    commentImages(media)
                }

                if let note = comment.content.richText?.note {
                    NoteLinkChip(note: note)
                }

                // A resolvable video reference in the comment text gets its
                // TITLE, fetched after the row is on screen. The row renders
                // immediately either way: the chip is absent until a title
                // exists, so nothing here is on the layout path of the comment
                // itself.
                CommentVideoTitleChip(message: comment.content.displayMessage)

                actionRow

                if showsInlineReplies, comment.rcount > 0,
                   !replyPreviews.isEmpty || onViewThread != nil {
                    inlineRepliesSection
                }
            }
        }
    }

    /// Gated on the COUNT, not on the previews: this block is now the only route
    /// into the thread, so a comment whose payload carries `rcount` but no
    /// `replies` must still offer one.
    private var inlineRepliesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(replyPreviews) { sub in
                subReplyRow(sub)
            }

            // No longer gated on `rcount > 3`: with the action row's count button
            // gone, a comment with one to three replies would otherwise have no
            // labelled entry at all — only the preview rows' own taps.
            if let onViewThread {
                Button {
                    onViewThread(comment)
                } label: {
                    HStack(spacing: 3) {
                        if comment.rcount == 1 {
                            Text("1 reply")
                        } else {
                            Text("\(comment.rcount) replies")
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .imageScale(.small)
                            .fontWeight(.semibold)
                    }
                    .appFont(.commentAction)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.biliAccent)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appControl)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppFill.nested,
            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .onTapGesture {
            onViewThread?(comment)
        }
        .padding(.top, 5)
    }

    /// Primary interactive controls at the bottom of the comment: Like and Reply.
    /// The fan ornament and "⋯" secondary actions sit at the trailing edge of
    /// the author header so they never collide with these controls.
    private var actionRow: some View {
        HStack(spacing: 20) {
            CommentLikeButton(comment: comment)
            if let onReply {
                CommentReplyActionButton {
                    onReply(comment)
                }
            }
            Spacer()
        }
    }

    /// Up to three replies previewed inline.
    ///
    /// `rcount` can be non-zero with no `replies` in the payload, so the block
    /// below is gated on the COUNT and this may legitimately be empty — that
    /// is the case where the thread entry has to stand on its own.
    /// A slice, not an `Array`: this is read on every body pass of every row in
    /// a scrolling list (see `UIHitchMonitor.countBody("row")` above), and
    /// `prefix` hands back a view of the existing storage while `Array(...)`
    /// would allocate one per pass.
    private var replyPreviews: ArraySlice<CommentResult.CommentItem> {
        let replies = comment.replies ?? []
        let engine = CommentAIFilterEngine.shared
        guard engine.isEnabled, engine.config.mode == .hideCompletely else {
            return replies.prefix(3)
        }
        var visible: [CommentResult.CommentItem] = []
        visible.reserveCapacity(min(3, replies.count))
        for sub in replies where !engine.shouldHide(sub, upMid: upMid) {
            visible.append(sub)
            if visible.count == 3 { break }
        }
        return visible[...]
    }

    private func commentImages(_ media: [MediaGridView.Media]) -> some View {
        // Smaller than a moment's: a comment image is supporting evidence, not
        // the post. PiliPlus's sizing (third cells, a ⅔/½-width single for
        // anything not wide) inside the phone-column cap — see
        // `CommentMediaMetrics.gridGeometry`.
        let innerColumnWidth = envColumnWidth.flatMap { $0 > 48 ? $0 - 48 : nil }
        let gridMaxWidth = innerColumnWidth.map { min(CommentMediaMetrics.maxWidth, $0) }
            ?? CommentMediaMetrics.maxWidth
        return MediaGridView(
            media: media,
            layout: .comment,
            maxWidth: gridMaxWidth,
            sourceID: "comment:\(comment.rpid)"
        ) { item in
            onImageTap?(item)
        }
        .rowCardColumnWidth(innerColumnWidth)
        .padding(.top, 4)
    }

    /// A comment's attached media: regular picture comments carry
    /// `pictures`; note comments (笔记) carry their screenshots in
    /// `rich_text.note.images` instead — one grid renders either.
    static func mediaItems(_ comment: CommentResult.CommentItem) -> [MediaGridView.Media] {
        if let pictures = comment.content.pictures, !pictures.isEmpty {
            return pictures.compactMap { pic -> MediaGridView.Media? in
                // Same normalization as the note images below: bili hands
                // back protocol-relative and plain-http image URLs, and ATS
                // blocks the http ones silently.
                guard !pic.imgSrc.isEmpty, let url = URL(string: pic.imgSrc.httpsURL) else { return nil }
                var size: CGSize?
                if let w = pic.imgWidth, let h = pic.imgHeight, w > 0, h > 0 {
                    size = CGSize(width: w, height: h)
                }
                return MediaGridView.Media(url: url, pixelSize: size)
            }
        }
        return (comment.content.richText?.note?.images ?? []).compactMap { src in
            guard !src.isEmpty else { return nil }
            return URL(string: src.httpsURL).map { MediaGridView.Media(url: $0) }
        }
    }

    @ViewBuilder
    private func subReplyRow(_ sub: CommentResult.CommentItem) -> some View {
        if BlocklistManager.shared.isBlocked(sub.mid) {
            // No reveal in the 3-line preview — the thread view has one.
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                Text("Comment from a blocked user")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else if CommentAIFilterEngine.shared.config.mode == .autoCollapse,
                  let assessment = CommentAIFilterEngine.shared.assessment(for: sub, upMid: upMid),
                  assessment.matches(CommentAIFilterEngine.shared.config) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                Text("Suspected AI reply collapsed")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpenReply?(comment, sub.rpid) }
        } else {
            subReplyBody(sub)
        }
    }

    private func subReplyBody(_ sub: CommentResult.CommentItem) -> some View {
        subReplyContent(sub)
            // Tapping an inline preview reply opens the thread anchored to that reply.
            .contentShape(Rectangle())
            .onTapGesture { onOpenReply?(comment, sub.rpid) }
    }

    /// Nested-reply font (`CommentMetrics.subReplyPointSize`, 1pt below `.commentBody`) shared by author prefix, body text, and inline sticker metrics.
    static func subReplyFont(isRegularWidth: Bool) -> EmoteTextFont {
        .points(
            CommentMetrics.subReplyPointSize(isRegularWidth: isRegularWidth),
            relativeTo: AppTypeScale.style(.commentBody, isRegularWidth: isRegularWidth).uiTextStyle
        )
    }

    /// Whether this row is drawing on a wide window. One read, shared by the
    /// `EmoteText` faces below and by `subReplyFont`.
    var isRegularWidth: Bool { sizeClass == .regular }

    private func subReplyAuthorPrefix(_ sub: CommentResult.CommentItem) -> Text {
        let authorFont = Self.subReplyFont(isRegularWidth: isRegularWidth).weighted(.medium).swiftUIFont
        let name = Text(sub.member.uname)
            .font(authorFont)
            .foregroundStyle(Color.primary.opacity(0.88))
        let colon = Text("：")
            .font(authorFont)
            .foregroundStyle(.secondary)
        let base = sub.mid == upMid ? name + UPBadge.inlineText : name
        let engine = CommentAIFilterEngine.shared
        if engine.config.mode == .badgeOnly,
           let assessment = engine.assessment(for: sub, upMid: upMid),
           assessment.matches(engine.config) {
            let aiTag = Text(verbatim: " [AI]")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            return base + aiTag + colon
        }
        return base + colon
    }

    private func subReplyContent(_ sub: CommentResult.CommentItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            EmoteText(
                message: sub.content.displayMessage,
                emotes: Self.emoteMap(sub),
                links: sub.content.resolvedLinks,
                font: Self.subReplyFont(isRegularWidth: isRegularWidth),
                detectTimestamps: true,
                leadingText: subReplyAuthorPrefix(sub)
            )
            .lineSpacing(1.5)
            .lineLimit(2)

            // A stripped {vote:…} token must leave a card behind,
            // or the sub-reply loses its content entirely.
            if let vote = sub.content.vote, let voteId = vote.id {
                VoteCardView(voteId: voteId, initialTitle: vote.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// token → image URL for inline sticker rendering.
    static func emoteMap(_ comment: CommentResult.CommentItem) -> [String: String] {
        comment.content.emoteURLs
    }
}

/// Like button for a comment row. The comment structs in the lists are
/// immutable snapshots, so the optimistic toggle state lives here; the
/// server truth (action/like) seeds it and a failed call reverts it.
struct CommentLikeButton: View {
    let comment: CommentResult.CommentItem

    @State private var likeState = CommentActionService.LikeState()
    /// This button's like request is running: only a turn-on during it plays
    /// the bounce/haptic.
    @State private var likeInFlight = false
    private let actions = CommentActionService()

    private var state: (liked: Bool, count: Int) {
        likeState.current(for: comment)
    }

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .appToggleFeedback(isOn: state.liked, userActionInFlight: likeInFlight)
                Text(FormatUtils.viewCount(state.count))
                    .monospacedDigit()
                    .appCountFeedback(value: state.count)
            }
            // Bare glyph + count; expands hit target via `-7pt` inset while keeping compact 4pt visual vertical padding.
            .appFont(.commentAction)
            .fontWeight(.medium)
            .foregroundStyle(state.liked ? Color.biliAccent : Color.primary.opacity(0.68))
            .padding(.vertical, 4)
            .contentShape(Rectangle().inset(by: -7))
        }
        .buttonStyle(.appControl)
    }

    private func toggle() {
        // Set before `begin`, which flips the shown state optimistically in
        // this same update.
        likeInFlight = true
        guard let attempt = likeState.begin(for: comment, isLoggedIn: actions.isLoggedIn) else {
            likeInFlight = false
            return
        }
        Task {
            let result = await actions.setLike(attempt)
            likeState.settle(result, for: attempt)
            if case .failure(let error) = result, !error.isCancellation {
                AppNoticeCenter.shared.showError(String(localized: "Like failed"))
            }
            likeInFlight = false
        }
    }
}

/// Shared author header ("name + badges  time  IP" on a compact single row,
/// wrapping to two lines at accessibility Dynamic Type sizes) with trailing
/// fan ornament and "⋯" button.
private struct CommentAuthorHeader: View {
    let comment: CommentResult.CommentItem
    let upMid: Int?
    var showsPinned = false
    let actionState: CommentActionState
    var onDelete: (() -> Void)?
    var aiAssessment: CommentAIAssessment?
    var onInspectAI: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            accessibilityLayout
        } else {
            compactLayout
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                authorNameText
                if comment.mid == upMid {
                    UPBadge().fixedSize()
                }
                if showsPinned, comment.isPinned {
                    PinnedBadge().fixedSize()
                }
                if let aiAssessment, let onInspectAI {
                    CommentAIBadgeButton(score: aiAssessment.score, action: onInspectAI)
                        .fixedSize()
                }
                Spacer(minLength: 4)
                CommentDecorationBadge(member: comment.member)
                CommentMoreActionButton(comment: comment, state: actionState, onDelete: onDelete)
                    .fixedSize()
            }
            metaView
        }
    }

    private var accessibilityLayout: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    authorNameText
                    if comment.mid == upMid {
                        UPBadge().fixedSize()
                    }
                    if showsPinned, comment.isPinned {
                        PinnedBadge().fixedSize()
                    }
                }
                if let aiAssessment, let onInspectAI {
                    CommentAIBadgeButton(score: aiAssessment.score, action: onInspectAI)
                        .fixedSize()
                }
                metaView
            }
            Spacer(minLength: 6)
            CommentDecorationBadge(member: comment.member)
            CommentMoreActionButton(comment: comment, state: actionState, onDelete: onDelete)
                .fixedSize()
        }
    }

    private var authorNameText: some View {
        Text(comment.member.uname)
            .appFont(.commentAuthor)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var metaView: some View {
        HStack(spacing: 6) {
            Text(FormatUtils.timeAgo(from: comment.ctime))
            if let location = comment.ipLocation {
                Text(location)
            }
        }
        .appFont(.commentMeta)
        // Secondary, not tertiary: this is the comment's primary
        // metadata, and tertiary dropped below legibility on the
        // cinematic page's dark surface.
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Bare Reply icon button in a comment's bottom action row.
private struct CommentReplyActionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.right")
                .appFont(.commentAction)
                .fontWeight(.medium)
                .foregroundStyle(Color.primary.opacity(0.68))
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
                .contentShape(Rectangle().inset(by: -7))
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text("Reply"))
    }
}

/// Native "⋯" menu in the top-trailing corner of a comment's author header.
/// A `Menu` anchors its popover to this button itself, unlike a row-level
/// `confirmationDialog`, which anchors to the whole row on iPad.
private struct CommentMoreActionButton: View {
    let comment: CommentResult.CommentItem
    let state: CommentActionState
    var onDelete: (() -> Void)?

    var body: some View {
        Menu {
            CommentActionMenuContent(comment: comment, state: state, onDelete: onDelete, reportsInline: false)
        } label: {
            Image(systemName: "ellipsis")
                .appFont(.commentAction)
                .fontWeight(.medium)
                .foregroundStyle(Color.primary.opacity(0.68))
                .padding(.vertical, 4)
                .padding(.leading, 4)
                .contentShape(Rectangle().inset(by: -7))
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text("More"))
    }
}

/// Everything a comment's action menu or long-press sheet shows, in one place.
/// `reportsInline` is true for the long-press sheet, where "Report" opens the
/// reason sheet; the `⋯` menu instead nests the reasons in a native submenu.
private struct CommentActionMenuContent: View {
    let comment: CommentResult.CommentItem
    let state: CommentActionState
    var onDelete: (() -> Void)?
    let reportsInline: Bool

    private var isOwnComment: Bool {
        AuthManager.shared.dedeUserID == String(comment.mid)
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = comment.content.message
        } label: {
            Text("Copy Text")
        }
        if AuthManager.shared.isLoggedIn, comment.oid != nil {
            if reportsInline {
                Button {
                    state.showReportReasons = true
                } label: {
                    Text("Report")
                }
            } else {
                Menu {
                    ForEach(CommentAPI.reportReasons, id: \.code) { reason in
                        Button(reason.label) { state.submitReport(reason: reason.code, for: comment) }
                    }
                } label: {
                    Text("Report")
                }
            }
        }
        if AuthManager.shared.isLoggedIn, !isOwnComment {
            if BlocklistManager.shared.blockedMids.contains(comment.mid) {
                Button {
                    state.setBlocked(false, for: comment)
                } label: {
                    Text("Unblock User")
                }
                .disabled(BlocklistManager.shared.isMutating(mid: comment.mid))
            } else {
                Button(role: .destructive) {
                    state.setBlocked(true, for: comment)
                } label: {
                    Text("Block User")
                }
                .disabled(BlocklistManager.shared.isMutating(mid: comment.mid))
            }
        }
        if isOwnComment, onDelete != nil, let oid = comment.oid {
            Button(role: .destructive) {
                state.deleteOwn(oid: oid, comment: comment, onDelete: onDelete)
            } label: {
                Text("Delete Comment")
            }
        }
    }
}

/// Presentation and in-flight state shared by a comment row's `⋯` menu and its
/// long-press sheet. The row owns one; the dialogs and alerts it drives
/// (`CommentActionDialogs`) are mounted only once an action needs them, so a
/// row that is never acted on builds none of them.
@MainActor
@Observable
final class CommentActionState {
    enum Presentation { case actions, otherReport }

    var isArmed = false
    var showActions = false
    var showReportReasons = false
    var showOtherReportPrompt = false
    var otherReportText = ""
    var reportResult: String?
    var blockResultSource: BlocklistManager.AccountSource?

    @ObservationIgnored private let service = CommentActionService()
    @ObservationIgnored private var pending: Presentation?

    /// Mounts the dialogs for results that arrive later (network outcomes).
    func arm() { isArmed = true }

    /// Presents now if the dialogs exist; otherwise mounts them first and
    /// presents from their `onAppear`, so a presentation never depends on a
    /// binding that was already true at mount.
    func present(_ presentation: Presentation) {
        if isArmed {
            apply(presentation)
        } else {
            pending = presentation
            isArmed = true
        }
    }

    func consumePending() {
        guard let presentation = pending else { return }
        pending = nil
        apply(presentation)
    }

    private func apply(_ presentation: Presentation) {
        switch presentation {
        case .actions: showActions = true
        case .otherReport: showOtherReportPrompt = true
        }
    }

    /// "Other" REQUIRES a description — the server rejects it empty.
    func submitReport(reason: Int, for comment: CommentResult.CommentItem) {
        if reason == 0 {
            present(.otherReport)
        } else if let oid = comment.oid {
            report(oid: oid, reason: reason, comment: comment)
        }
    }

    func report(oid: Int, reason: Int, content: String = "", comment: CommentResult.CommentItem) {
        arm()
        Task {
            let target = CommentActionService.Target(oid: oid, type: comment.type ?? 1, rpid: comment.rpid)
            let outcome = await service.report(target, reason: reason, content: content)
            blockResultSource = nil
            switch outcome {
            case .success:
                reportResult = String(localized: "Report submitted")
            case .failure(let error):
                reportResult = String(localized: "Report failed: \(error.localizedDescription)")
            }
        }
    }

    func deleteOwn(oid: Int, comment: CommentResult.CommentItem, onDelete: (() -> Void)?) {
        arm()
        Task {
            let target = CommentActionService.Target(oid: oid, type: comment.type ?? 1, rpid: comment.rpid)
            switch await service.delete(target) {
            case .success:
                onDelete?()
            case .failure(let error):
                blockResultSource = nil
                reportResult = String(localized: "Delete failed: \(error.localizedDescription)")
            }
        }
    }

    /// The manager remains the sole server-backed blocked-set owner.
    func setBlocked(_ blocked: Bool, for comment: CommentResult.CommentItem) {
        arm()
        switch service.prepareBlocked(blocked, mid: comment.mid) {
        case .busy:
            return
        case .authRequired:
            blockResultSource = nil
            reportResult = String(localized: "Operation failed: \(BiliError.authRequired.localizedDescription)")
        case .admitted(let request):
            Task {
                let outcome = await service.setBlocked(request)
                guard request.source == BlocklistManager.AccountSource.capture() else { return }
                if case .failed(let error) = outcome, !error.isCancellation, !Task.isCancelled {
                    blockResultSource = request.source
                    reportResult = String(localized: "Operation failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// Long-press actions on a comment's text: the same actions as the `⋯` menu,
/// presented as an action sheet.
private struct CommentContextActions: ViewModifier {
    let comment: CommentResult.CommentItem
    let state: CommentActionState
    /// Removes the row from its list after a successful server delete;
    /// nil hides the delete action entirely.
    var onDelete: (() -> Void)?

    func body(content: Content) -> some View {
        content
            // Deliberately NOT .contextMenu: its lift animation snapshots
            // the row into a rounded, magnified preview — a tall comment's
            // preview exceeded the screen and iOS clipped it away
            // entirely. Long-press goes straight to an action sheet: no
            // frame, no magnification, same actions.
            .onLongPressGesture(minimumDuration: 0.4) {
                state.present(.actions)
            }
            // A background has the content's own frame, so the iPad popover
            // keeps the anchor it had when the dialogs were attached to the
            // content itself.
            .background {
                if state.isArmed {
                    CommentActionDialogs(comment: comment, state: state, onDelete: onDelete)
                }
            }
    }
}

/// The presentation half of `CommentContextActions`; also hosts the alerts the
/// `⋯` menu's actions report through.
private struct CommentActionDialogs: View {
    let comment: CommentResult.CommentItem
    @Bindable var state: CommentActionState
    var onDelete: (() -> Void)?

    private static let exactTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private var visibleResult: String? {
        if let source = state.blockResultSource, source != BlocklistManager.AccountSource.capture() { return nil }
        return state.reportResult
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: BlocklistManager.AccountSource.capture()) { _, source in
                if let blockResultSource = state.blockResultSource, blockResultSource != source {
                    state.reportResult = nil
                    state.blockResultSource = nil
                }
            }
            .onAppear { state.consumePending() }
            .confirmationDialog(
                Self.exactTimeFormatter.string(
                    from: Date(timeIntervalSince1970: TimeInterval(comment.ctime))
                ),
                isPresented: $state.showActions,
                titleVisibility: .visible
            ) {
                CommentActionMenuContent(comment: comment, state: state, onDelete: onDelete, reportsInline: true)
            }
            .confirmationDialog(
                "Report",
                isPresented: $state.showReportReasons,
                titleVisibility: .visible
            ) {
                ForEach(CommentAPI.reportReasons, id: \.code) { reason in
                    Button(reason.label) { state.submitReport(reason: reason.code, for: comment) }
                }
            }
            // Shared verdict alert (report AND block failures) — the
            // message carries the context, so no title.
            .alert(
                Text(verbatim: ""),
                isPresented: Binding(
                    get: { visibleResult != nil },
                    set: {
                        if !$0 {
                            state.reportResult = nil
                            state.blockResultSource = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(visibleResult ?? "")
            }
            .alert("Report", isPresented: $state.showOtherReportPrompt) {
                TextField(String(localized: "Describe the problem"), text: $state.otherReportText)
                Button("Report", role: .destructive) {
                    let text = state.otherReportText.trimmingCharacters(in: .whitespacesAndNewlines)
                    state.otherReportText = ""
                    guard !text.isEmpty, let oid = comment.oid else { return }
                    state.report(oid: oid, reason: 0, content: text, comment: comment)
                }
                Button("Cancel", role: .cancel) { state.otherReportText = "" }
            } message: {
                Text("A description is required for this report type.")
            }
    }
}

extension View {
    fileprivate func commentContextActions(
        _ comment: CommentResult.CommentItem,
        state: CommentActionState,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        modifier(CommentContextActions(comment: comment, state: state, onDelete: onDelete))
    }
}

/// Outlined pinned-comment state badge, visually distinct from the filled `UPBadge` identity pill.
struct PinnedBadge: View {
    var body: some View {
        Text("Pinned")
            .appFont(.overlayBadge)
            .fontWeight(.bold)
            .foregroundStyle(Color.biliAccent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.badge)
                    .strokeBorder(Color.biliAccent.opacity(0.6), lineWidth: 0.5)
            )
    }
}

/// Uploader badge shown next to the video creator's name in comments.
struct UPBadge: View {
    @MainActor
    private static var cachedInlineImage: (key: String, image: UIImage)?

    var body: some View {
        Text("UP")
            .appFont(.overlayBadge)
            .fontWeight(.heavy)
            .fontDesign(.rounded)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(AccentStore.shared.badgeFill, in: RoundedRectangle(cornerRadius: AppRadius.badge))
    }

    /// Inline `Text` representation of the UP pill for compact single-flow
    /// sub-reply previews (`昵称 [UP]：评论内容`), using baseline metadata on
    /// the rendered `UIImage` so the badge centers optically without expanding
    /// paragraph line height.
    @MainActor
    static var inlineText: Text {
        let store = AccentStore.shared
        let cacheKey = "\(store.theme?.rawValue ?? "default"):\(store.scope.rawValue)"
        let image: UIImage
        if let cached = cachedInlineImage, cached.key == cacheKey {
            image = cached.image
        } else {
            let rendered = renderInlinePill(fill: UIColor(store.badgeFill))
            cachedInlineImage = (cacheKey, rendered)
            image = rendered
        }
        return Text(verbatim: " ")
            + Text(Image(uiImage: image))
                .font(EmoteTextFont.inlineAttachment)
                .baselineOffset(-1.5)
    }

    private static func renderInlinePill(fill: UIColor) -> UIImage {
        let baseFont = UIFont.systemFont(ofSize: 8.5, weight: .heavy)
        let font: UIFont = if let desc = baseFont.fontDescriptor.withDesign(.rounded) {
            UIFont(descriptor: desc, size: 8.5)
        } else {
            baseFont
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let label = "UP" as NSString
        let textSize = label.size(withAttributes: attrs)
        let size = CGSize(width: ceil(textSize.width) + 7, height: ceil(textSize.height) + 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            fill.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: AppRadius.badge).fill()
            let textOrigin = CGPoint(
                x: (size.width - textSize.width) * 0.5,
                y: (size.height - textSize.height) * 0.5
            )
            label.draw(at: textOrigin, withAttributes: attrs)
        }
    }
}

/// "UP主觉得很赞" — the uploader liked this comment.
struct UPLikedTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hand.thumbsup.fill")
                .font(.caption2)
                .imageScale(.small)
            Text("Liked by UP")
                .appFont(.overlayBadge)
                .fontWeight(.semibold)
        }
        .foregroundStyle(Color.biliAccent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.biliAccent.opacity(0.12), in: Capsule())
    }
}

/// Comment-card 装扮 (suit) — the card-background image with the fan
/// number overlaid on it, anchored at the trailing edge of the action row.
/// The card image is a wide banner, center-cropped into the fixed 80×24
/// box (requested pre-cropped from the CDN at exactly that box — same
/// region scaledToFill+clipped always showed). The fan number sits inside
/// the image. Gated on Settings → Comments → Show Comment Ornaments.
///
/// The 80×24 box is reserved unconditionally and visibility rides
/// `.opacity`: a frame that grew 0 → 80×24 when the CDN answered made the
/// badge pop in on every scroll-back, because the load state is fresh @State on
/// each cell realization and starts empty again even for a cache hit.
/// Reserving costs no layout here — both call sites mount this as an
/// `.overlay` on the action row, which never sizes its parent — and an
/// unloaded badge draws nothing, so the "80×24 blank gap" the zero-size
/// placeholder was added for cannot come back.
///
/// This site is INTENTIONALLY transparent (`.placeholder { Color.clear }`) and
/// gets no opaque loading cover: it is an ornament overlaid on the action row,
/// and covering it would paint a slab over the row's own controls.
struct CommentDecorationBadge: View {
    let member: CommentResult.CommentItem.CommentMember
    @AppStorage("show_comment_ornaments") private var showOrnaments = false
    /// Which cardbg URL the composed badge actually has pixels for — NOT a
    /// bare `loaded: Bool`, which cannot survive view reuse. A comment list
    /// re-uses this structural position for a DIFFERENT comment: that resets
    /// the KFImage (its `Context` is Hashable on the source, so the renderer's
    /// `.id(context)` changes) but not our `@State`, so a recycled row drew the
    /// previous suit's fan number over a badge with no image yet. Keyed to the
    /// URL, a stale value simply stops matching.
    ///
    /// Kingfisher's own loaded/failed branch cannot express this. It exposes
    /// "has no pixels" only as `placeholder`/`onFailureView` CONTENT, drawn
    /// UNDER nothing — and the fan number has to sit ON TOP of the image.
    /// Composing the number into the content instead (`contentConfigure`) would
    /// draw it on a FAILED load too, because Kingfisher renders that content at
    /// full opacity around an empty image.
    @State private var loadedURL: URL?

    var body: some View {
        if showOrnaments, let cardbg = member.userSailing?.cardbg,
           let image = cardbg.image, !image.isEmpty,
           // CDN-resized + decode-capped to the 80×24 box (CoverImage's
           // rule): the suit banner original is a full-width strip, and
           // every decorated row was decoding it whole for a badge.
           // `_1c` center-crops server-side — the same region the
           // scaledToFill+clipped below shows, so nothing moves visually.
           let url = URL(string: image.biliResized(
               toPixel: CGSize(width: 80 * UIScreen.main.scale, height: 24 * UIScreen.main.scale),
               crop: true
           )) {
            KFImage(url)
                .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 80, height: 24)))
                .scaleFactor(UIScreen.main.scale)
                .cancelOnDisappear(true)
                .onSuccess { _ in loadedURL = url }
                .onFailure { _ in loadedURL = nil }
                .placeholder { Color.clear }
                .resizable()
                .scaledToFill()
                .frame(width: 80, height: 24)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.badge))
                .overlay(alignment: .center) {
                    // No load check here: the opacity below hides the whole
                    // composed badge, number included.
                    if let fan = cardbg.fan, fan.isFan == 1,
                       let numDesc = fan.numDesc, !numDesc.isEmpty {
                        let tint = Color(biliHex: fan.color) ?? .white
                        Text(verbatim: "NO.\(numDesc)")
                            .appFont(.overlayBadge)
                            .fontWeight(.bold)
                            .fontDesign(.rounded)
                            .italic()
                            .foregroundStyle(tint)
                    }
                }
                .opacity(loadedURL == url ? 1 : 0)
                // opacity(0) hides pixels, not accessibility elements — without
                // this an unloaded badge still announces "NO.1234" to VoiceOver.
                .accessibilityHidden(loadedURL != url)
                .allowsHitTesting(false)
        }
    }
}

/// 笔记评论 — jump to the full note this comment was published from.
struct NoteLinkChip: View {
    let note: CommentResult.CommentItem.CommentContent.RichTextInfo.Note

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let clickUrl = note.clickUrl, let url = URL(string: clickUrl) {
            Button {
                openURL(url)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "note.text")
                    Text("View Full Note")
                    if let mtime = note.lastMtimeText, !mtime.isEmpty {
                        Text(mtime)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .imageScale(.small)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.biliAccent)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
        }
    }
}

/// Collapses content authored by a blacklisted user behind a one-line
/// placeholder; tapping reveals it for this row until it's rebuilt.
/// Blocking/unblocking from anywhere updates live — BlocklistManager is
/// @Observable and the check runs in body.
struct BlockedCollapsible<Content: View>: View {
    @AppMotion private var motion
    let mid: Int
    let uname: String
    @ViewBuilder var content: () -> Content

    @State private var revealed = false

    var body: some View {
        if BlocklistManager.shared.isBlocked(mid), !revealed {
            Button {
                withAnimation(motion.animation(normal: .easeInOut(duration: 0.2))) { revealed = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                    Text("Blocked user @\(uname) — comment hidden")
                        .lineLimit(1)
                    Spacer()
                    Text("Show Anyway")
                        .foregroundStyle(.biliAccent)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

extension Color {
    /// "#rrggbb" (BiliBili badge/suit colors) — nil for anything else.
    init?(biliHex: String?) {
        guard var hex = biliHex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// One thread opening, plus which reply to land on.
///
/// Captures the source when opened, so parent metadata cannot retarget it.
/// Highlight and display metadata do not change this source/root identity.
struct CommentThreadTarget: Identifiable {
    struct Identity: Hashable {
        let oid: Int
        let type: Int
        let rootRpid: Int
    }

    let oid: Int
    let type: Int
    let root: CommentResult.CommentItem
    /// nil = no particular reply; open at the top as before.
    var highlightRpid: Int?

    var id: Identity { Identity(oid: oid, type: type, rootRpid: root.rpid) }
}

struct CommentThreadView: View {
    /// Same reason as `CommentRowView`: the reply body is an `EmoteText` whose
    /// sticker boxes are cut from the face it is given.
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isRegularWidth: Bool { sizeClass == .regular }

    let oid: Int
    let rootComment: CommentResult.CommentItem
    /// Reply to scroll to on open; nil opens at the top.
    ///
    /// Declared HERE, immediately after `rootComment`, and not at the end of the
    /// property list. A struct's memberwise initializer requires call sites to
    /// pass arguments in declaration order, and these two are one identity —
    /// "this thread, that reply" — so every call site naturally writes them
    /// together. Appending it instead made all five call sites a compile error
    /// ("Argument 'type' must precede argument 'highlightRpid'").
    var highlightRpid: Int?
    /// Comment-area type (1 = video; dynamics use 11/17/12 etc.).
    var type: Int = 1
    var upMid: Int?
    /// Standalone sheet/push pages paint their own ambient browse background;
    /// embedded panels inherit the host surface.
    var isStandalonePage = true
    /// See CommentRowView.onAvatarTap — sheet hosts pass a dismiss-first
    /// closure; nil pushes on the main stack.
    var onAvatarTap: ((Int) -> Void)?

    @State private var thread = CommentThreadStore()

    private struct ComposerCapture {
        let store: CommentThreadStore
        let source: CommentThreadStore.Context
        let context: CommentComposerUploadOwner.Context
    }
    /// One-shot: a later page load must not yank the list back to the target.
    @State private var didScrollToHighlight = false
    @State private var locatedHighlightRpid: Int?
    @State private var highlightedReplyRpid: Int?
    @State private var highlightClearTask: Task<Void, Never>?
    @State private var previewImages: ImagePreviewItem?
    @State private var isComposerExpanded = false
    @State private var composerFocus = CommentComposerFocus()
    @AppMotion private var motion
    @Environment(AppCoordinator.self) private var coordinator

    private var threadContext: CommentThreadStore.Context {
        CommentThreadStore.Context(oid: oid, root: rootComment, type: type)
    }

    private func openProfile(_ mid: Int) {
        guard mid > 0 else { return }
        if let onAvatarTap {
            onAvatarTap(mid)
        } else {
            coordinator.navigate(to: .userSpace(mid))
        }
    }

    // Reached as a SHEET (video detail, bangumi detail) and as a PUSH (moment
    // detail, article reader, the dynamic comment sheet). The boundary belongs
    // on the view rather than at each presentation site — that is the rule
    // e5054a8 established, and the two sites that were patched individually are
    // exactly why: the other three were missed, and a pushed destination that
    // inherits nothing falls through to the tab tree's scope-BLIND
    // `.tint(navigationTint)`, so its iOS-drawn surfaces took the raw chosen
    // colour while its `Color.biliAccent` surfaces obeyed the scope. Applying
    // it here is idempotent for the two sites that already do it.
    var body: some View {
        accentedBody.accentContentBoundary()
            .contentLinks()
            .appNoticeOverlay(bottomPadding: 64)
    }

    @ViewBuilder
    private var accentedBody: some View {
        let composer = composerCapture
        let listReceipt = thread.listReceipt
        let headerItems = threadHeaderItems(composer: composer)
        let visibleReplies = CommentAIFilterEngine.shared.visibleComments(from: thread.replies, upMid: upMid)
        let replyItems = visibleReplies.map { reply in
            UIKitCommentFeedItem(
                comment: reply,
                extraFingerprint: AnyHashableSendable(thread.commentsClosed),
                prefetchAvatarPointSize: 30
            ) {
                replyRow(reply, composer: composer)
            }
        }
        let showsInitialSkeletons = thread.isLoading && thread.replies.isEmpty && !thread.commentsClosed
        let hasMoreReplies = thread.totalReplies.map { thread.replies.count < $0 } ?? !thread.loadFeedback.hasLoaded
        let showsFooter = !showsInitialSkeletons && (
            thread.commentsClosed || thread.isLoading || thread.loadFeedback.failure != nil
                || thread.replies.isEmpty || hasMoreReplies
        )
        let composerVisible = AuthManager.shared.isLoggedIn && oid > 0 && !thread.commentsClosed

        UIKitCommentFeedCollectionView(
            headerItems: headerItems,
            items: replyItems,
            footerContent: showsFooter ? AnyView(threadFooterView(hasMore: hasMoreReplies)) : nil,
            footerFingerprint: showsFooter ? AnyHashableSendable(ThreadFooterFingerprint(
                commentsClosed: thread.commentsClosed,
                hasLoaded: thread.loadFeedback.hasLoaded,
                failure: thread.loadFeedback.failure,
                isLoading: thread.isLoading,
                isEmpty: thread.replies.isEmpty,
                hasMore: hasMoreReplies
            )) : nil,
            skeletonCount: showsInitialSkeletons ? 4 : 0,
            highlightedItemID: highlightedReplyRpid.map(AnyHashableSendable.init),
            scrollToItemID: locatedHighlightRpid.map(AnyHashableSendable.init),
            scrollToPosition: .centeredVertically,
            showsItemDividers: true,
            dividerLeadingInset: 40,
            itemSpacing: 8,
            headerSpacing: 8,
            horizontalInset: AppSpacing.l,
            topInset: AppSpacing.l,
            bottomClearance: composerVisible ? 88 : AppSpacing.l,
            ignoresBottomSafeArea: true,
            keyboardDismissMode: .onDrag,
            thresholdOffset: 4,
            onRefresh: {
                guard let request = thread.prepareRefresh(in: threadContext) else { return false }
                await thread.perform(request)
                return false
            },
            onWillDisplayItemAt: { _ in
                guard let request = thread.prepareMore(in: threadContext, from: listReceipt) else { return }
                Task { await thread.perform(request) }
            }
        )
        .modifier(CommentThreadSurfaceBackground(isStandalonePage: isStandalonePage))
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if composerVisible {
                threadComposer(composer: composer)
            }
        }
        .task {
            let generation = thread.requestGeneration
            if !thread.loadFeedback.hasLoaded, thread.loadFeedback.failure == nil {
                await thread.loadMore(in: threadContext)
            }
            await scrollToHighlight(generation: generation)
        }
        .onDisappear {
            highlightClearTask?.cancel()
            highlightClearTask = nil
        }
        .imagePreview(item: $previewImages)
    }

    private func threadComposer(composer: ComposerCapture) -> some View {
        CollapsibleComposer(
            text: composerText(for: composer),
            pictures: composerPictures(for: composer),
            placeholder: CommentComposerBar.replyPlaceholder(
                to: thread.replyTarget?.member.uname ?? rootComment.member.uname
            ),
            replyBanner: thread.replyTarget.map { CommentComposerBar.replyBannerText(for: $0.member.uname) },
            isSending: thread.isSending,
            sendError: composerCanInteract(composer) ? thread.sendError : nil,
            focus: composerFocus,
            onCancelReply: {
                guard composerCanInteract(composer) else { return }
                composer.store.cancelReply(in: composer.source)
                composerFocus.dismiss()
            },
            onSend: { sendReply(from: composer) },
            uploadScope: composerUploadScope(for: composer),
            isInteractionCurrent: { composerCanInteract(composer) },
            expansion: $isComposerExpanded
        )
    }

    private func threadHeaderItems(composer: ComposerCapture) -> [UIKitCommentFeedItem] {
        let rootItem = UIKitCommentFeedItem(
            id: "thread-root-\(rootComment.rpid)",
            fingerprint: UIKitCommentItemFingerprint(rootComment)
        ) {
            CommentThreadRootRow(
                comment: rootComment,
                upMid: upMid,
                onReply: { _ in beginReply(to: nil, from: composer) },
                onImageTap: { item in previewImages = item },
                onAvatarTap: onAvatarTap
            )
        }
        let subheaderFingerprint = ThreadSubheaderFingerprint(
            replyTotal: rootComment.rcount + thread.postedCount
        )
        let subheaderItem = UIKitCommentFeedItem(
            id: "thread-replies-header",
            fingerprint: subheaderFingerprint
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle()
                    .fill(AppFill.nested)
                    .frame(height: 8)
                    .padding(.horizontal, -AppSpacing.l)
                HStack(spacing: 6) {
                    Text("Thread Replies")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("\(rootComment.rcount + thread.postedCount)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
        }
        return [rootItem, subheaderItem]
    }

    @ViewBuilder
    private func threadFooterView(hasMore: Bool) -> some View {
        if thread.commentsClosed {
            ContentUnavailableView("Replies are unavailable", systemImage: "bubble.left.and.bubble.right")
        } else {
            CommentLoadFeedbackView(
                feedback: thread.loadFeedback,
                isLoading: thread.isLoading,
                isEmpty: thread.replies.isEmpty,
                hasMore: hasMore,
                retry: retryReplies
            )
        }
    }

    private func retryReplies() {
        guard let request = thread.prepareRetry(in: threadContext) else { return }
        Task { await thread.perform(request) }
    }

    private func replyRow(
        _ reply: CommentResult.CommentItem,
        composer: ComposerCapture
    ) -> some View {
        CommentThreadReplyRow(
            reply: reply,
            upMid: upMid,
            isRegularWidth: isRegularWidth,
            commentsClosed: thread.commentsClosed,
            onAvatarTap: openProfile,
            onBeginReply: AuthManager.shared.isLoggedIn ? { beginReply(to: reply, from: composer) } : nil,
            onDelete: { thread.removeReply(rpid: reply.rpid) }
        )
    }

    // MARK: - In-place reply composer

    private func beginReply(to target: CommentResult.CommentItem?, from captured: ComposerCapture) {
        guard composerCanInteract(captured) else { return }
        captured.store.beginReply(to: target, in: captured.source)
        composerFocus.request()
        if !isComposerExpanded {
            // Root replies and the same retained target have no banner change.
            withAnimation(motion.animation(normal: CollapsibleComposer.composerExpandAnimation)) {
                isComposerExpanded = true
            }
        }
    }
}

private extension CommentThreadView {
    private var composerCapture: ComposerCapture {
        ComposerCapture(store: thread, source: threadContext, context: thread.composerContext)
    }

    private func composerIsCurrent(_ captured: ComposerCapture) -> Bool {
        thread === captured.store && oid == captured.source.oid && type == captured.source.type
            && rootComment.rpid == captured.source.root.rpid
            && captured.store.composerIsCurrent(in: captured.source, expected: captured.context)
    }

    private func composerCanInteract(_ captured: ComposerCapture) -> Bool {
        composerIsCurrent(captured) && !captured.store.commentsClosed
    }

    private func composerUploadScope(for captured: ComposerCapture) -> CommentComposerUploadScope {
        CommentComposerUploadScope(
            owner: captured.store.commentUpload, context: captured.context,
            isCurrent: { composerIsCurrent(captured) },
            onAdmission: {
                captured.store.imageSelectionWasAdmitted(in: captured.source, expected: captured.context)
            }
        )
    }

    private func composerText(for captured: ComposerCapture) -> Binding<String> {
        Binding(get: { captured.store.commentText }, set: { value in
            guard composerIsCurrent(captured) else { return }
            captured.store.commentText = value
        })
    }

    private func composerPictures(for captured: ComposerCapture) -> Binding<[ComposedPicture]> {
        Binding(get: { captured.store.commentPictures }, set: { value in
            guard composerIsCurrent(captured) else { return }
            captured.store.commentPictures = value
        })
    }

    private func sendReply(from captured: ComposerCapture) {
        guard composerCanInteract(captured) else { return }
        captured.store.sendReply(in: captured.source, expectedComposer: captured.context) {
            // Only this accepted, unchanged draft owns closing the panel; send
            // completion alone cannot close a revised draft during refresh.
            // This runs after clear writers and before the store advances the epoch.
            guard composerIsCurrent(captured) else { return }
            composerFocus.dismiss()
            withAnimation(motion.animation(normal: CollapsibleComposer.composerCollapseAnimation)) {
                isComposerExpanded = false
            }
        }
    }

    /// Pages until the highlighted reply is loaded, then scrolls to it.
    ///
    /// **There is no direct lookup.** Audited: `/x/v2/reply/reply` accepts only
    /// `oid`, `type`, `root`, `ps` and `pn` — no cursor, no `pagination_str`, and
    /// no way to seek by rpid. The `seek_rpid` parameter exists only on the
    /// top-level `/x/v2/reply/wbi/main` lazy-load endpoint, not for sub-replies,
    /// and no endpoint returns one comment by rpid. A larger `ps` does not help:
    /// the domain is 1-49 but the response caps at 20 items regardless. So
    /// sequential paging is forced, and the only question is what ends it.
    ///
    /// Not a page budget. An arbitrary limit made correctness depend on the
    /// target being near the beginning, which is backwards: sub-replies sort
    /// time-ASCENDING while the tapped previews are the main list's HOT picks, so
    /// a tapped reply is if anything biased toward being deep.
    ///
    /// Termination reasons are logged:
    ///  - **found** — the target is loaded; scroll to it.
    ///  - **eof** — `page.count` says everything is loaded and it is not here.
    ///  - **cancelled** — the `.task` was torn down by navigating away. This, not
    ///    a page cap, is what bounds a long search.
    ///  - **repeated-page** — the same effective page came back twice while the
    ///    server still claims more data. A server-side loop; stop.
    ///  - **no-progress** / **request-failed** — the list stopped growing for
    ///    another reason, or a request threw.
    ///  - **superseded** / **unavailable** — a refresh replaced this search's
    ///    list lifetime, or the current request found the replies closed.
    ///
    /// Every way the highlight search can end. Exactly one is logged per search,
    /// so a device capture always says why the target was or was not reached.
    private enum HighlightExit: String {
        case found
        case targetIsRoot = "target-is-root"
        case endOfThread = "eof"
        case cancelled
        case superseded
        case unavailable
        /// The server handed back the same effective page twice while still
        /// claiming more data exists.
        case repeatedResponse = "repeated-page"
        /// Progress stopped without a repeat and without reaching EOF.
        case noProgress = "no-progress"
        case requestFailed = "request-failed"
    }

    private func scrollToHighlight(generation: UInt64) async {
        guard !didScrollToHighlight, let target = highlightRpid else { return }
        didScrollToHighlight = true
        guard highlightMayContinue(generation: generation, target: target, pages: 0, detail: nil) else { return }

        // The root is not in `replies` and its row carries no id — landing on it
        // means staying at the top, which is already where we are.
        guard target != rootComment.rpid else {
            logHighlight(.targetIsRoot, target: target, pages: 0, detail: nil)
            return
        }

        var pagesFetched = 0
        var consecutiveStalls = 0
        var lastSignature: String?
        var repeatedSignatures = 0

        while !thread.replies.contains(where: { $0.rpid == target }) {
            guard highlightMayContinue(
                generation: generation, target: target, pages: pagesFetched, detail: lastSignature
            ) else { return }
            // Real EOF: every reply the server says exists has been loaded.
            if let total = thread.totalReplies, thread.replies.count >= total {
                logHighlight(.endOfThread, target: target, pages: pagesFetched,
                             detail: "loaded=\(thread.replies.count)/\(total)")
                return
            }

            let outcome = await thread.loadMore(in: threadContext)
            guard highlightMayContinue(
                generation: generation, target: target, pages: pagesFetched, detail: lastSignature
            ) else { return }

            switch outcome {
            case .failed, .cancelled, .superseded, .closed:
                logHighlight(highlightExit(for: outcome), target: target, pages: pagesFetched,
                             detail: lastSignature)
                return

            case .skipped:
                // A concurrent load holds the turn — that is a lost race with the
                // last-row `onAppear`, not the end of the list.
                consecutiveStalls += 1

            case .advanced(let signature), .stalled(let signature):
                pagesFetched += 1
                if case .advanced = outcome {
                    consecutiveStalls = 0
                } else {
                    consecutiveStalls += 1
                }
                guard !isRepeat(signature, of: &lastSignature, count: &repeatedSignatures) else {
                    logHighlight(.repeatedResponse, target: target,
                                 pages: pagesFetched, detail: signature)
                    return
                }
            }

            guard consecutiveStalls <= Self.highlightStallTolerance else {
                logHighlight(.noProgress, target: target, pages: pagesFetched,
                             detail: lastSignature)
                return
            }
            if consecutiveStalls > 0 {
                // Let whichever load holds `isLoading` finish, then retry.
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        applyLocatedHighlight(target, generation: generation, pages: pagesFetched, detail: lastSignature)
    }

    private func applyLocatedHighlight(_ target: Int, generation: UInt64, pages: Int, detail: String?) {
        guard highlightMayContinue(generation: generation, target: target, pages: pages, detail: detail) else { return }
        locatedHighlightRpid = target
        highlightedReplyRpid = target
        highlightClearTask?.cancel()
        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            highlightedReplyRpid = nil
        }
        logHighlight(.found, target: target, pages: pages, detail: detail)
    }

    private func highlightMayContinue(generation: UInt64, target: Int, pages: Int, detail: String?) -> Bool {
        let exit: HighlightExit?
        if Task.isCancelled {
            exit = .cancelled
        } else if thread.requestGeneration != generation {
            exit = .superseded
        } else if thread.commentsClosed {
            exit = .unavailable
        } else {
            exit = nil
        }
        guard let exit else { return true }
        logHighlight(exit, target: target, pages: pages, detail: detail)
        return false
    }

    private func highlightExit(for outcome: CommentThreadStore.PageLoad) -> HighlightExit {
        switch outcome {
        case .cancelled: .cancelled
        case .superseded: .superseded
        case .closed: .unavailable
        case .failed: .requestFailed
        case .advanced, .stalled, .skipped: .noProgress
        }
    }

    /// True when this signature matches the previous one often enough to call it
    /// a repeat. A REPEATED effective page is the loop the hardening guards
    /// against: `page` keeps incrementing and `count` keeps promising more, but
    /// the same ids come back.
    private func isRepeat(
        _ signature: String,
        of last: inout String?,
        count: inout Int
    ) -> Bool {
        if signature == last {
            count += 1
        } else {
            count = 0
        }
        last = signature
        return count >= Self.repeatedResponseTolerance
    }

    private func logHighlight(
        _ exit: HighlightExit,
        target: Int,
        pages: Int,
        detail: String?
    ) {
        PlayerLog.log(
            "[CommentThread] highlight root=\(rootComment.rpid) target=\(target) "
            + "exit=\(exit.rawValue) pages=\(pages) replies=\(thread.replies.count)"
            + (detail.map { " \($0)" } ?? "")
        )
    }

    /// Two identical page signatures in a row is a repeat; one could be a
    /// coincidence on a thread whose only page is stable.
    private static let repeatedResponseTolerance = 2

    /// How many consecutive no-progress rounds to tolerate before concluding the
    /// list really cannot grow. Three is enough to ride out a lost race with the
    /// last-row `onAppear`; more would mask a genuine dead end.
    private static let highlightStallTolerance = 3
}

extension View {
    /// In-content link routing for SHEET-hosted comment UIs. RootView's
    /// global OpenURLAction pushes bilibili destinations onto the tab's
    /// navigation stack — which sits UNDER an open sheet, so a tapped
    /// @mention appeared to do nothing. This override closes the hosting
    /// sheet first, then routes; non-bilibili links still go to Safari.
    func dismissingSheetOnBiliLink(
        coordinator: AppCoordinator,
        dismiss: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        contentLinks(beforeNavigate: dismiss)
    }
}

/// Resolved chip content per message, retained across lazy-row recycling. A
/// recreated chip seeds its State from here, so a row that scrolls back into
/// view draws its chip on the first frame instead of growing a frame later
/// (which shifted visible content when scrolling up). Bounded FIFO.
@MainActor
private enum CommentVideoTitleChipMemo {
    /// `nil` video: the message was resolved and carries no video link.
    struct Entry {
        let videoID: VideoID?
        let title: String?
    }

    private static let maxEntries = 256
    private static var entries: [String: Entry] = [:]
    private static var order: [String] = []

    static func entry(for message: String) -> Entry? { entries[message] }

    static func record(_ entry: Entry, for message: String) {
        if entries.updateValue(entry, forKey: message) == nil {
            order.append(message)
            if order.count > maxEntries { entries.removeValue(forKey: order.removeFirst()) }
        }
    }
}

/// Shows the title of a Bilibili video referenced in a comment.
///
/// Three properties matter here and each is deliberate:
///
/// - **Never blocks the row.** Identification and the fetch both happen in
///   `.task`, keyed on the message, so the comment's own text is laid out before
///   either runs. The chip simply is not there until a title exists.
/// - **One resolver.** The reference is found by `BiliLinkResolver`, the same
///   one the deep-link handler and the clipboard detector use — a bare `BV…`,
///   an `av…`, a full URL or a direct `b23.tv/BV…` all resolve here, and a
///   tracking-heavy shared URL resolves to the same identity as a clean one.
/// - **One routing path.** The tap is a `Link` to the canonical URL, so it goes
///   through the app's existing `OpenURLAction` → `BiliURLParser` route rather
///   than a second navigation mechanism.
///
/// An opaque `b23.tv` code is NOT followed: a comment list would fire a network
/// request per unresolved link while scrolling. Those render as plain links, as
/// they did before.
private struct CommentVideoTitleChip: View {
    let message: String

    @State private var videoID: VideoID?
    @State private var title: String?
    /// The message the State above was resolved for; a recycled row keeps
    /// State from another comment until the task runs.
    @State private var resolvedMessage: String?

    init(message: String) {
        self.message = message
        if let memo = CommentVideoTitleChipMemo.entry(for: message), memo.title != nil || memo.videoID == nil {
            _videoID = State(initialValue: memo.videoID)
            _title = State(initialValue: memo.title)
            _resolvedMessage = State(initialValue: message)
        }
    }

    var body: some View {
        Group {
            if let videoID, let title, let url = Self.canonicalURL(for: videoID) {
                let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.biliAccent)
                        Text(title)
                            .font(.footnote.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(AppFill.nested.opacity(0.6), in: shape)
                    .overlay(
                        shape
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    )
                    .contentShape(shape)
                }
                .buttonStyle(.appControl)
            }
        }
        .task(id: message) {
            // Already resolved for THIS message (seeded from the memo): nothing
            // to clear or fetch, so the row keeps its first-frame height.
            if resolvedMessage == message { return }
            // Clear FIRST. A recycled row keeps its @State until this task runs,
            // so without this the previous comment's title showed for a frame
            // under a different comment's text. Unchanged writes are skipped.
            if videoID != nil { videoID = nil }
            if title != nil { title = nil }
            if resolvedMessage != nil { resolvedMessage = nil }
            // Identification is pure and cheap, but it still belongs here
            // rather than in `body`: running it per body pass would repeat the
            // scan on every scroll-driven re-render.
            guard case .resolved(let target, _) = BiliLinkResolver.resolve(text: message),
                  case .video(let id) = target
            else {
                CommentVideoTitleChipMemo.record(.init(videoID: nil, title: nil), for: message)
                resolvedMessage = message
                return
            }
            videoID = id
            // Cached titles resolve without suspending long enough to flash.
            let resolved = await BiliVideoTitleCache.shared.title(for: id)
            guard !Task.isCancelled else { return }
            title = resolved
            // A failed lookup is not retained, so a later appearance retries.
            if let resolved {
                CommentVideoTitleChipMemo.record(.init(videoID: id, title: resolved), for: message)
                resolvedMessage = message
            }
        }
    }

    private static func canonicalURL(for id: VideoID) -> URL? {
        switch id {
        case .bvid(let bvid): URL(string: "https://www.bilibili.com/video/\(bvid)")
        case .aid(let aid): URL(string: "https://www.bilibili.com/video/av\(aid)")
        }
    }
}

/// Makes a comment's text tap into reply mode — and, when there is no reply
/// action, adds no gesture at all.
///
/// The conditional matters more than it looks. `.onTapGesture { closure?() }`
/// still installs a recogniser and still consumes the tap when the closure is
/// nil, so on a read-only comment surface (or while logged out, where the Reply
/// chip is correctly hidden) it would swallow link and timestamp taps in order
/// to run nothing. Attaching the gesture only when an action exists keeps those
/// surfaces exactly as they were.
private struct TapToReply: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
        } else {
            content
        }
    }
}

private struct ThreadSubheaderFingerprint: Hashable, Sendable {
    let replyTotal: Int
}

private struct ThreadFooterFingerprint: Hashable, Sendable {
    let commentsClosed: Bool
    let hasLoaded: Bool
    let failure: CommentLoadFeedback.Failure?
    let isLoading: Bool
    let isEmpty: Bool
    let hasMore: Bool
}

private struct CommentThreadRootRow: View {
    let comment: CommentResult.CommentItem
    let upMid: Int?
    let onReply: (CommentResult.CommentItem) -> Void
    let onImageTap: (ImagePreviewItem) -> Void
    let onAvatarTap: ((Int) -> Void)?

    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    var body: some View {
        CommentRowView(
            comment: comment,
            upMid: upMid,
            showsInlineReplies: false,
            onReply: onReply,
            onImageTap: onImageTap,
            onAvatarTap: onAvatarTap
        )
        .rowCardColumnWidth(envColumnWidth.flatMap { $0 > 24 ? $0 - 24 : nil })
        .padding(12)
    }
}

private struct CommentThreadReplyRow: View {
    let reply: CommentResult.CommentItem
    let upMid: Int?
    let isRegularWidth: Bool
    let commentsClosed: Bool
    let onAvatarTap: (Int) -> Void
    let onBeginReply: (() -> Void)?
    let onDelete: () -> Void

    @State private var actionState = CommentActionState()

    var body: some View {
        BlockedCollapsible(mid: reply.mid, uname: reply.member.uname) {
            CommentAIFilterRowContainer(comment: reply, upMid: upMid) { aiAssessment, onInspectAI in
                rowBody(aiAssessment: aiAssessment, onInspectAI: onInspectAI)
            }
        }
    }

    private func rowBody(
        aiAssessment: CommentAIAssessment?,
        onInspectAI: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarImage(urlString: reply.member.avatar.httpsURL, size: 30)
                .contentShape(Circle())
                .onTapGesture { onAvatarTap(reply.mid) }

            VStack(alignment: .leading, spacing: 4) {
                CommentAuthorHeader(
                    comment: reply,
                    upMid: upMid,
                    actionState: actionState,
                    onDelete: onDelete,
                    aiAssessment: aiAssessment,
                    onInspectAI: onInspectAI
                )

                EmoteText(
                    message: reply.content.displayMessage,
                    emotes: CommentRowView.emoteMap(reply),
                    links: reply.content.resolvedLinks,
                    font: .app(AppTypeScale.style(.commentBody, isRegularWidth: isRegularWidth)),
                    collapsedLineLimit: 6,
                    detectTimestamps: true
                )
                .lineSpacing(2)
                .modifier(TapToReply(action: onBeginReply))
                .padding(.top, 2)
                .padding(.bottom, 3)

                if reply.upAction?.like == true {
                    UPLikedTag()
                }

                if let vote = reply.content.vote, let voteId = vote.id {
                    VoteCardView(voteId: voteId, initialTitle: vote.title)
                }

                HStack(spacing: 20) {
                    CommentLikeButton(comment: reply)
                    if AuthManager.shared.isLoggedIn, !commentsClosed, let onBeginReply {
                        CommentReplyActionButton(action: onBeginReply)
                    }
                    Spacer()
                }
            }
        }
        .commentContextActions(reply, state: actionState, onDelete: onDelete)
    }
}

private struct CommentThreadSurfaceBackground: ViewModifier {
    let isStandalonePage: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isStandalonePage {
            content.appAmbientBrowseBackground()
        } else {
            content
        }
    }
}
