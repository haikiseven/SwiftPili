import Observation
import SwiftUI

struct CommentLoadFeedbackView: View {
    let feedback: CommentLoadFeedback
    let isLoading: Bool
    let isEmpty: Bool
    /// Keeps a steady footer height while additional pages remain so toggling
    /// `isLoading` does not bounce the bottom edge; collapses cleanly at EOF.
    var hasMore = false
    let retry: () -> Void

    private var hasVisibleContent: Bool {
        isLoading || feedback.failure != nil || isEmpty
    }

    var body: some View {
        if hasVisibleContent || hasMore {
            VStack(spacing: 10) {
                if isLoading {
                    ProgressView("Loading comments…")
                } else if let failure = feedback.failure {
                    Label(failureText(failure), systemImage: "exclamationmark.bubble")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry", action: retry)
                } else if isEmpty, feedback.hasLoaded {
                    Text("Be the first to comment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if isEmpty {
                    Button("Load comments", action: retry)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.vertical, 12)
        }
    }

    private func failureText(_ failure: CommentLoadFeedback.Failure) -> LocalizedStringKey {
        switch failure {
        case .initial: "Couldn't load comments."
        case .refresh: "Couldn't refresh comments. Previous results are still shown."
        case .pagination: "Couldn't load more comments."
        }
    }
}

enum CommentListFooterFingerprint: Hashable, Sendable {
    case closed
    case feedback(
        hasLoaded: Bool,
        failure: CommentLoadFeedback.Failure?,
        isLoading: Bool,
        isEmpty: Bool,
        hasMore: Bool,
        lineage: UUID?
    )
}

/// Shared footer assembly for UIKit-hosted comment lists (closed state,
/// initial-skeleton suppression, or `CommentLoadFeedbackView`).
@MainActor
enum CommentListFooter {
    struct State {
        let commentsClosed: Bool
        let showsInitialSkeletons: Bool
        let feedback: CommentLoadFeedback
        let isLoading: Bool
        let isEmpty: Bool
        var hasMore = false
        let lineage: UUID?
        var closedTopPadding: CGFloat = 40
    }

    static func make(
        _ state: State,
        retry: @escaping () -> Void
    ) -> (content: AnyView?, fingerprint: AnyHashableSendable?) {
        if state.commentsClosed {
            let closedView = ContentUnavailableView("Comments are turned off", systemImage: "exclamationmark.bubble")
                .padding(.top, state.closedTopPadding)
            return (AnyView(closedView), AnyHashableSendable(CommentListFooterFingerprint.closed))
        }
        if state.showsInitialSkeletons { return (nil, nil) }
        if !state.isLoading, state.feedback.failure == nil, !state.isEmpty, !state.hasMore {
            return (nil, nil)
        }
        let feedbackView = CommentLoadFeedbackView(
            feedback: state.feedback,
            isLoading: state.isLoading,
            isEmpty: state.isEmpty,
            hasMore: state.hasMore,
            retry: retry
        )
        let fingerprint = CommentListFooterFingerprint.feedback(
            hasLoaded: state.feedback.hasLoaded,
            failure: state.feedback.failure,
            isLoading: state.isLoading,
            isEmpty: state.isEmpty,
            hasMore: state.hasMore,
            lineage: state.lineage
        )
        return (AnyView(feedbackView), AnyHashableSendable(fingerprint))
    }
}

/// Shared sheet header bar for comment lists: "Comments + count", optional
/// sort control, and circular Close button.
struct CommentSheetListHeader: View {
    let total: Int
    let sortSelection: CommentSort?
    let anchors: CommentZoomAnchors
    let onSelectSort: ((CommentSort) -> Void)?
    let onClose: () -> Void

    var body: some View {
        CommentSheetHeaderBar {
            CommentSectionHeading(total: total)
        } trailing: {
            HStack(alignment: .center, spacing: AppSpacing.s) {
                if let sortSelection, let onSelectSort {
                    CommentSortBar(selection: sortSelection, onSelect: onSelectSort)
                }
                CommentHeaderCircleButton(
                    systemName: "xmark",
                    accessibilityLabel: "Close comments",
                    anchors: anchors,
                    role: .closeControl,
                    action: onClose
                )
            }
        }
    }
}

struct CommentListRowFingerprint: Hashable, Sendable {
    let upMid: Int?
    let oid: Int
    let type: Int
    let sort: CommentSort
    let lineage: UUID?
}

/// Shared top header chrome for sheet-hosted comment lists and reply threads.
struct CommentSheetHeaderBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: AppSpacing.s) {
                leading()
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, AppSpacing.l)
            .padding(.top, AppSpacing.m)
            .padding(.bottom, AppSpacing.s)
            Divider()
                .opacity(0.35)
        }
        .frame(minHeight: 54)
    }
}

/// Shared "Comments + count" heading for sheet and panel comment headers.
struct CommentSectionHeading: View {
    let total: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Comments")
                .appFont(.sectionTitle)
                .fontWeight(.semibold)
            if total > 0 {
                Text(FormatUtils.viewCount(total))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shared in-place reply-thread presentation state for surfaces hosted inside
/// `CommentReplyZoomContainer` (sheet comment lists and iPad split panels).
@MainActor
@Observable
final class InlineCommentReplyState {
    @ObservationIgnored let presentation = CommentZoomPresentation()
    var target: CommentThreadTarget?

    func open(_ next: CommentThreadTarget, presentInline: Bool) {
        presentation.cancelPendingAction()
        presentation.anchors.sourceProvider = { nil }
        target = next
        if presentInline {
            presentation.isPresented = true
        }
    }

    func close() {
        presentation.cancelPendingAction()
        let threadID = target?.id
        presentation.dismissThenPerform { [weak self] in
            self?.finishDismissal(threadID)
        }
    }

    func finishDismissal(_ threadID: CommentThreadTarget.Identity?) {
        guard !presentation.isPresented, target?.id == threadID else { return }
        target = nil
        presentation.anchors.sourceProvider = nil
    }

    func reset() {
        presentation.cancelPendingAction()
        presentation.isPresented = false
        target = nil
        presentation.anchors.sourceProvider = nil
    }

    func adaptPresentation(isInline: Bool) {
        presentation.cancelPendingAction()
        presentation.isPresented = isInline && target != nil
    }
}

/// Embedded reply-thread screen for sheet-hosted comment feeds using
/// `CommentReplyZoomContainer`, with circular Back and Close controls and no
/// manual refresh button (pull-to-refresh is provided by `CommentThreadView`).
struct CommentSheetReplyView: View {
    let target: CommentThreadTarget
    let upMid: Int?
    let anchors: CommentZoomAnchors
    let onBack: () -> Void
    let onClose: () -> Void
    let onAvatarTap: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            CommentSheetHeaderBar {
                HStack(spacing: AppSpacing.s) {
                    CommentHeaderCircleButton(
                        systemName: "chevron.left",
                        accessibilityLabel: "Back",
                        anchors: anchors,
                        role: .backControl,
                        action: onBack
                    )
                    Text("Thread")
                        .appFont(.sectionTitle)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                CommentHeaderCircleButton(
                    systemName: "xmark",
                    accessibilityLabel: "Close comments",
                    anchors: anchors,
                    role: .closeControl,
                    action: onClose
                )
            }
            CommentThreadView(
                oid: target.oid,
                rootComment: target.root,
                highlightRpid: target.highlightRpid,
                type: target.type,
                upMid: upMid,
                isStandalonePage: false,
                onAvatarTap: onAvatarTap
            )
            .id(target.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
