import Kingfisher
import SwiftUI

struct CommentRowView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    let comment: CommentResult.CommentItem
    var upMid: Int?
    var showsInlineReplies = true
    var onReply: ((CommentResult.CommentItem) -> Void)?
    var onViewThread: ((CommentResult.CommentItem) -> Void)?
    var onOpenReply: ((CommentResult.CommentItem, Int) -> Void)?
    var onImageTap: ((ImagePreviewItem) -> Void)?
    var onAvatarTap: ((Int) -> Void)?
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

                CommentVideoTitleChip(message: comment.content.displayMessage)

                actionRow

                if showsInlineReplies, comment.rcount > 0,
                   !replyPreviews.isEmpty || onViewThread != nil {
                    inlineRepliesSection
                }
            }
        }
    }

    private var inlineRepliesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(replyPreviews) { sub in
                subReplyRow(sub)
            }

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

    static func mediaItems(_ comment: CommentResult.CommentItem) -> [MediaGridView.Media] {
        if let pictures = comment.content.pictures, !pictures.isEmpty {
            return pictures.compactMap { pic -> MediaGridView.Media? in
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
            .contentShape(Rectangle())
            .onTapGesture { onOpenReply?(comment, sub.rpid) }
    }

    static func subReplyFont(isRegularWidth: Bool) -> EmoteTextFont {
        .points(
            CommentMetrics.subReplyPointSize(isRegularWidth: isRegularWidth),
            relativeTo: AppTypeScale.style(.commentBody, isRegularWidth: isRegularWidth).uiTextStyle
        )
    }

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

            if let vote = sub.content.vote, let voteId = vote.id {
                VoteCardView(voteId: voteId, initialTitle: vote.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func emoteMap(_ comment: CommentResult.CommentItem) -> [String: String] {
        comment.content.emoteURLs
    }
}

struct CommentLikeButton: View {
    let comment: CommentResult.CommentItem

    @State private var likeState = CommentActionService.LikeState()
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
            .appFont(.commentAction)
            .fontWeight(.medium)
            .foregroundStyle(state.liked ? Color.biliAccent : Color.primary.opacity(0.68))
            .padding(.vertical, 4)
            .contentShape(Rectangle().inset(by: -7))
        }
        .buttonStyle(.appControl)
    }

    private func toggle() {
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
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

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

    func arm() { isArmed = true }

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

private struct CommentContextActions: ViewModifier {
    let comment: CommentResult.CommentItem
    let state: CommentActionState
    var onDelete: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .onLongPressGesture(minimumDuration: 0.4) {
                state.present(.actions)
            }
            .background {
                if state.isArmed {
                    CommentActionDialogs(comment: comment, state: state, onDelete: onDelete)
                }
            }
    }
}

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

struct CommentDecorationBadge: View {
    let member: CommentResult.CommentItem.CommentMember
    @AppStorage("show_comment_ornaments") private var showOrnaments = false
    @State private var loadedURL: URL?

    var body: some View {
        if showOrnaments, let cardbg = member.userSailing?.cardbg,
           let image = cardbg.image, !image.isEmpty,
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
                .accessibilityHidden(loadedURL != url)
                .allowsHitTesting(false)
        }
    }
}

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

struct CommentThreadTarget: Identifiable {
    struct Identity: Hashable {
        let oid: Int
        let type: Int
        let rootRpid: Int
    }

    let oid: Int
    let type: Int
    let root: CommentResult.CommentItem
    var highlightRpid: Int?

    var id: Identity { Identity(oid: oid, type: type, rootRpid: root.rpid) }
}

struct CommentThreadView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isRegularWidth: Bool { sizeClass == .regular }

    let oid: Int
    let rootComment: CommentResult.CommentItem
    var highlightRpid: Int?
    var type: Int = 1
    var upMid: Int?
    var isStandalonePage = true
    var onAvatarTap: ((Int) -> Void)?

    @State private var thread = CommentThreadStore()

    private struct ComposerCapture {
        let store: CommentThreadStore
        let source: CommentThreadStore.Context
        let context: CommentComposerUploadOwner.Context
    }
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
            guard composerIsCurrent(captured) else { return }
            composerFocus.dismiss()
            withAnimation(motion.animation(normal: CollapsibleComposer.composerCollapseAnimation)) {
                isComposerExpanded = false
            }
        }
    }

    private enum HighlightExit: String {
        case found
        case targetIsRoot = "target-is-root"
        case endOfThread = "eof"
        case cancelled
        case superseded
        case unavailable
        case repeatedResponse = "repeated-page"
        case noProgress = "no-progress"
        case requestFailed = "request-failed"
    }

    private func scrollToHighlight(generation: UInt64) async {
        guard !didScrollToHighlight, let target = highlightRpid else { return }
        didScrollToHighlight = true
        guard highlightMayContinue(generation: generation, target: target, pages: 0, detail: nil) else { return }

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

    private static let repeatedResponseTolerance = 2

    private static let highlightStallTolerance = 3
}

extension View {
    func dismissingSheetOnBiliLink(
        coordinator: AppCoordinator,
        dismiss: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        contentLinks(beforeNavigate: dismiss)
    }
}

@MainActor
private enum CommentVideoTitleChipMemo {
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

private struct CommentVideoTitleChip: View {
    let message: String

    @State private var videoID: VideoID?
    @State private var title: String?
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
            if resolvedMessage == message { return }
            if videoID != nil { videoID = nil }
            if title != nil { title = nil }
            if resolvedMessage != nil { resolvedMessage = nil }
            guard case .resolved(let target, _) = BiliLinkResolver.resolve(text: message),
                  case .video(let id) = target
            else {
                CommentVideoTitleChipMemo.record(.init(videoID: nil, title: nil), for: message)
                resolvedMessage = message
                return
            }
            videoID = id
            let resolved = await BiliVideoTitleCache.shared.title(for: id)
            guard !Task.isCancelled else { return }
            title = resolved
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
