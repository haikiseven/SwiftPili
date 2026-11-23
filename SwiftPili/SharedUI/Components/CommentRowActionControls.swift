import Observation
import SwiftUI
import UIKit

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
            .linkAwareLongPress(minimumDuration: 0.4) {
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
        onDelete: (() -> Void)? = nil
    ) -> some View {
        modifier(CommentContextActions(comment: comment, state: state, onDelete: onDelete))
    }
}
