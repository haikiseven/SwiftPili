import Observation
import SwiftUI
import UIKit

// MARK: - Comment Reaction Controls (Like + Mutually Exclusive Cloud Dislike)

struct CommentLikeButton: View {
    let comment: CommentResult.CommentItem
    var state: CommentActionState?

    @State private var fallbackState = CommentActionState()

    private var activeState: CommentActionState { state ?? fallbackState }

    var body: some View {
        let reaction = activeState.currentReaction(for: comment)
        Button {
            activeState.toggleLike(for: comment)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: reaction.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .appToggleFeedback(isOn: reaction.liked, userActionInFlight: activeState.likeInFlight)
                Text(FormatUtils.viewCount(reaction.likeCount))
                    .monospacedDigit()
                    .appCountFeedback(value: reaction.likeCount)
            }
            .appFont(.commentAction)
            .fontWeight(.medium)
            .foregroundStyle(reaction.liked ? Color.biliAccent : Color.primary.opacity(0.68))
            .padding(.vertical, 4)
            .contentShape(Rectangle().inset(by: -7))
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(reaction.liked ? Text("Cancel Like") : Text("Like"))
    }
}

struct CommentDislikeButton: View {
    let comment: CommentResult.CommentItem
    let state: CommentActionState

    var body: some View {
        let reaction = state.currentReaction(for: comment)
        Button {
            state.toggleHate(for: comment)
        } label: {
            Image(systemName: reaction.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                .appToggleFeedback(isOn: reaction.disliked, userActionInFlight: state.hateInFlight)
                .appFont(.commentAction)
                .fontWeight(.medium)
                .foregroundStyle(reaction.disliked ? Color.biliAccent : Color.primary.opacity(0.68))
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
                .contentShape(Rectangle().inset(by: -7))
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(reaction.disliked ? Text("Cancel Dislike") : Text("Dislike"))
    }
}

struct CommentReplyActionButton: View {
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

struct CommentMoreActionButton: View {
    let comment: CommentResult.CommentItem
    let state: CommentActionState
    var onDelete: (() -> Void)?

    var body: some View {
        Menu {
            CommentActionMenuContent(
                comment: comment,
                state: state,
                onReply: state.replyHandler,
                onDelete: onDelete,
                reportsInline: false
            )
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

// MARK: - Local + Cloud Filtered Comment Row Wrapper

struct ContentFilterCommentRowContainer<Content: View>: View {
    let comment: CommentResult.CommentItem
    var bypass: Bool = false
    @ViewBuilder let content: () -> Content

    @AppMotion private var motion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false

    var body: some View {
        let filterStore = LocalContentFilterStore.shared
        let _ = (
            filterStore.revision,
            BlocklistManager.shared.isEnabled,
            BlocklistManager.shared.blockedMids.count
        )

        if bypass || isExpanded {
            content()
        } else if filterStore.matchComment(mid: comment.mid, content: comment.content.displayMessage) != nil {
            if filterStore.collapseFilteredComments {
                collapsedBar
            } else {
                EmptyView()
            }
        } else {
            content()
        }
    }

    private var collapsedBar: some View {
        Button {
            withAnimation(motion.animation(normal: .easeInOut(duration: 0.2))) {
                isExpanded = true
            }
        } label: {
            HStack(spacing: AppSpacing.xs + 2) {
                Image(systemName: "eye.slash")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Locally filtered a comment, tap to view")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
                Spacer(minLength: AppSpacing.s)
                Text("Expand")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.biliAccent)
                    .fixedSize()
            }
            .padding(.horizontal, AppSpacing.m)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if dynamicTypeSize.isAccessibilitySize {
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(AppFill.inset)
                } else {
                    Capsule(style: .continuous)
                        .fill(AppFill.inset)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Expands the filtered comment"))
    }
}

// MARK: - Action Menu Content

private struct CommentActionMenuContent: View {
    let comment: CommentResult.CommentItem
    let state: CommentActionState
    var onReply: ((CommentResult.CommentItem) -> Void)?
    var onDelete: (() -> Void)?
    let reportsInline: Bool

    private var isOwnComment: Bool {
        AuthManager.shared.dedeUserID == String(comment.mid)
    }

    var body: some View {
        let reaction = state.currentReaction(for: comment)
        let isLocallyBlocked = LocalContentFilterStore.shared.isUPBlockedLocally(comment.mid)

        Button {
            UIPasteboard.general.string = comment.content.message
        } label: {
            Label("Copy Text", systemImage: "doc.on.doc")
        }

        if let onReply {
            Button {
                onReply(comment)
            } label: {
                Label("Reply", systemImage: "bubble.right")
            }
        }

        if AuthManager.shared.isLoggedIn, comment.oid != nil {
            Button {
                state.toggleHate(for: comment)
            } label: {
                Label(
                    reaction.disliked ? "Cancel Dislike" : "Dislike",
                    systemImage: reaction.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown"
                )
            }
            .disabled(state.hateInFlight || state.likeInFlight)
        }

        if !isOwnComment {
            if isLocallyBlocked {
                Button {
                    state.toggleLocalBlockUser(for: comment)
                } label: {
                    Label("Unblock User Locally", systemImage: "person.crop.circle.badge.checkmark")
                }
            } else {
                Button(role: .destructive) {
                    state.toggleLocalBlockUser(for: comment)
                } label: {
                    Label("Locally Block User", systemImage: "person.slash")
                }
            }
        }

        Button {
            state.presentAddKeywordSheet(for: comment)
        } label: {
            Label("Add Comment Filter Keyword…", systemImage: "line.3.horizontal.decrease.circle")
        }

        if AuthManager.shared.isLoggedIn, comment.oid != nil {
            if reportsInline {
                Button {
                    state.showReportReasons = true
                } label: {
                    Label("Report", systemImage: "flag")
                }
            } else {
                Menu {
                    ForEach(CommentAPI.reportReasons, id: \.code) { reason in
                        Button(reason.label) { state.submitReport(reason: reason.code, for: comment) }
                    }
                } label: {
                    Label("Report", systemImage: "flag")
                }
            }
        }

        if AuthManager.shared.isLoggedIn, !isOwnComment {
            if BlocklistManager.shared.blockedMids.contains(comment.mid) {
                Button {
                    state.setBlocked(false, for: comment)
                } label: {
                    Label("Remove from Bilibili Blacklist", systemImage: "hand.raised.slash")
                }
                .disabled(BlocklistManager.shared.isMutating(mid: comment.mid))
            } else {
                Button(role: .destructive) {
                    state.setBlocked(true, for: comment)
                } label: {
                    Label("Add to Bilibili Blacklist", systemImage: "hand.raised")
                }
                .disabled(BlocklistManager.shared.isMutating(mid: comment.mid))
            }
        }

        if isOwnComment, onDelete != nil, let oid = comment.oid {
            Button(role: .destructive) {
                state.deleteOwn(oid: oid, comment: comment, onDelete: onDelete)
            } label: {
                Label("Delete Comment", systemImage: "trash")
            }
        }
    }
}

// MARK: - CommentActionState

@MainActor
@Observable
final class CommentActionState {
    enum Presentation { case actions, otherReport, addKeyword }

    struct ReactionState: Equatable, Sendable {
        var liked: Bool
        var disliked: Bool
        var likeCount: Int
    }

    var isArmed = false
    var showActions = false
    var showReportReasons = false
    var showOtherReportPrompt = false
    var otherReportText = ""
    var showAddKeywordSheet = false
    var keywordDraft = ""
    var keywordDraftIsRegex = false
    var keywordSourceText = ""
    var reportResult: String?
    var blockResultSource: BlocklistManager.AccountSource?

    var likeInFlight = false
    var hateInFlight = false
    private var reactionCommentID: Int?
    private var reactionOverride: ReactionState?

    @ObservationIgnored var replyHandler: ((CommentResult.CommentItem) -> Void)?
    @ObservationIgnored private let service = CommentActionService()
    @ObservationIgnored private var pending: Presentation?

    @discardableResult
    func syncReplyHandler(_ handler: ((CommentResult.CommentItem) -> Void)?) -> Bool {
        replyHandler = handler
        return true
    }

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
        case .addKeyword: showAddKeywordSheet = true
        }
    }

    // MARK: - Like / Dislike (Mutually Exclusive)

    func currentReaction(for comment: CommentResult.CommentItem) -> ReactionState {
        if reactionCommentID == comment.rpid, let reactionOverride {
            return reactionOverride
        }
        return ReactionState(
            liked: comment.action == 1,
            disliked: comment.action == 2,
            likeCount: comment.like
        )
    }

    func toggleLike(for comment: CommentResult.CommentItem) {
        guard !likeInFlight, !hateInFlight else { return }
        guard service.isLoggedIn else { return }
        guard let oid = comment.oid else {
            PlayerLog.log("[Comment] like unavailable: reply \(comment.rpid) carries no oid")
            return
        }
        let previous = currentReaction(for: comment)
        let desiredLike = !previous.liked
        let nextCount = max(0, previous.likeCount + (desiredLike ? 1 : -1))
        let next = ReactionState(
            liked: desiredLike,
            disliked: desiredLike ? false : previous.disliked,
            likeCount: nextCount
        )
        reactionCommentID = comment.rpid
        reactionOverride = next
        likeInFlight = true
        let target = CommentActionService.Target(oid: oid, type: comment.type ?? 1, rpid: comment.rpid)
        let rpid = comment.rpid
        Task {
            do {
                _ = try await CommentAPI.likeComment(
                    oid: target.oid,
                    type: target.type,
                    rpid: target.rpid,
                    like: desiredLike
                )
            } catch {
                if self.reactionCommentID == rpid {
                    self.reactionOverride = previous
                }
                if !BiliAPIRetryPolicy.isCancellation(error) {
                    PlayerLog.log("[Comment] like failed: \(error)")
                    AppNoticeCenter.shared.showError(String(localized: "Like failed"))
                }
            }
            self.likeInFlight = false
        }
    }

    func toggleHate(for comment: CommentResult.CommentItem) {
        guard !hateInFlight, !likeInFlight else { return }
        guard service.isLoggedIn else { return }
        guard let oid = comment.oid else {
            PlayerLog.log("[Comment] hate unavailable: reply \(comment.rpid) carries no oid")
            return
        }
        let previous = currentReaction(for: comment)
        let desiredHate = !previous.disliked
        let nextCount = (desiredHate && previous.liked)
            ? max(0, previous.likeCount - 1)
            : previous.likeCount
        let next = ReactionState(
            liked: desiredHate ? false : previous.liked,
            disliked: desiredHate,
            likeCount: nextCount
        )
        reactionCommentID = comment.rpid
        reactionOverride = next
        hateInFlight = true
        let target = CommentActionService.Target(oid: oid, type: comment.type ?? 1, rpid: comment.rpid)
        let rpid = comment.rpid
        Task {
            do {
                _ = try await CommentAPI.hateComment(
                    oid: target.oid,
                    type: target.type,
                    rpid: target.rpid,
                    hate: desiredHate
                )
            } catch {
                if self.reactionCommentID == rpid {
                    self.reactionOverride = previous
                }
                if !BiliAPIRetryPolicy.isCancellation(error) {
                    PlayerLog.log("[Comment] hate failed: \(error)")
                    AppNoticeCenter.shared.showError(String(localized: "Dislike failed"))
                }
            }
            self.hateInFlight = false
        }
    }

    // MARK: - Local Content Filter Actions

    func toggleLocalBlockUser(for comment: CommentResult.CommentItem) {
        let store = LocalContentFilterStore.shared
        let rawName = comment.member.uname.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawName.isEmpty ? "UID \(comment.mid)" : rawName
        let mid = comment.mid
        let face = comment.member.avatar.httpsURL

        if store.isUPBlockedLocally(mid) {
            store.unblockUP(mid: mid)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            ContentFilterUndoToastCenter.shared.show(
                message: String(format: String(localized: "Unblocked user \"%@\" locally"), displayName),
                systemImage: "person.crop.circle.badge.checkmark"
            ) {
                store.blockUP(mid: mid, name: displayName, face: face)
            }
        } else {
            store.blockUP(mid: mid, name: displayName, face: face)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            ContentFilterUndoToastCenter.shared.show(
                message: String(format: String(localized: "Locally blocked user \"%@\""), displayName),
                systemImage: "person.slash"
            ) {
                store.unblockUP(mid: mid)
            }
        }
    }

    func presentAddKeywordSheet(for comment: CommentResult.CommentItem) {
        let trimmed = comment.content.displayMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        keywordSourceText = trimmed
        keywordDraft = trimmed.count <= 20 ? trimmed : ""
        keywordDraftIsRegex = false
        present(.addKeyword)
    }

    // MARK: - Cloud Report / Delete / Blacklist

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

// MARK: - Long-Press Modifier & Dialog Host

private struct CommentContextActions: ViewModifier {
    let comment: CommentResult.CommentItem
    let state: CommentActionState
    var onReply: ((CommentResult.CommentItem) -> Void)?
    var onDelete: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .linkAwareLongPress(minimumDuration: 0.4) {
                state.present(.actions)
            }
            .background {
                if state.isArmed {
                    CommentActionDialogs(
                        comment: comment,
                        state: state,
                        onReply: onReply,
                        onDelete: onDelete
                    )
                }
            }
    }
}

private struct CommentActionDialogs: View {
    let comment: CommentResult.CommentItem
    @Bindable var state: CommentActionState
    var onReply: ((CommentResult.CommentItem) -> Void)?
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
                CommentActionMenuContent(
                    comment: comment,
                    state: state,
                    onReply: onReply ?? state.replyHandler,
                    onDelete: onDelete,
                    reportsInline: true
                )
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
            .sheet(isPresented: $state.showAddKeywordSheet) {
                CommentAddFilterKeywordSheet(
                    sourceText: state.keywordSourceText,
                    keyword: $state.keywordDraft,
                    isRegex: $state.keywordDraftIsRegex
                ) { pattern, isRegex in
                    let store = LocalContentFilterStore.shared
                    if let added = store.addCommentKeyword(pattern, isRegex: isRegex) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        ContentFilterUndoToastCenter.shared.show(
                            message: String(format: String(localized: "Added comment filter \"%@\""), added.pattern),
                            systemImage: "line.3.horizontal.decrease.circle"
                        ) {
                            store.removeCommentKeyword(id: added.id)
                        }
                    }
                }
                .presentationDetents([.medium])
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

private struct CommentAddFilterKeywordSheet: View {
    let sourceText: String
    @Binding var keyword: String
    @Binding var isRegex: Bool
    let onCommit: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var regexError: String? {
        guard isRegex else { return nil }
        return LocalContentFilterStore.validateRegex(trimmedKeyword)
    }

    private var canSubmit: Bool {
        !trimmedKeyword.isEmpty && regexError == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if !sourceText.isEmpty {
                    Section {
                        Text(sourceText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                        if keyword != sourceText {
                            Button("Use Full Comment Text") {
                                keyword = sourceText
                            }
                            .font(.footnote.weight(.medium))
                        }
                    } header: {
                        Text("Original Comment")
                    }
                }

                Section {
                    TextField("Enter keyword or regex to filter", text: $keyword)
                        .focused($isFieldFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit {
                            if canSubmit { commitAndDismiss() }
                        }

                    Toggle("Regular Expression", isOn: $isRegex)

                    if let regexError {
                        Label(regexError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Comment Filter Rule")
                } footer: {
                    Text("Comments containing this keyword will be filtered locally on this device.")
                }
            }
            .navigationTitle("Add Comment Filter Keyword")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { commitAndDismiss() }
                        .disabled(!canSubmit)
                }
            }
            .onAppear {
                isFieldFocused = true
            }
        }
    }

    private func commitAndDismiss() {
        let value = trimmedKeyword
        guard !value.isEmpty, regexError == nil else { return }
        onCommit(value, isRegex)
        dismiss()
    }
}

struct TapToReply: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        content.linkAwareTap(isEnabled: action != nil) {
            action?()
        }
    }
}

extension View {
    func commentContextActions(
        _ comment: CommentResult.CommentItem,
        state: CommentActionState,
        onReply: ((CommentResult.CommentItem) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        modifier(CommentContextActions(comment: comment, state: state, onReply: onReply, onDelete: onDelete))
    }
}
