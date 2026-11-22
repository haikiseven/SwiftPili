import SwiftUI
import UIKit

struct MomentDetailSnapshotInput: Equatable {
    let dynamicID: String
    let section: MomentDetailView.InteractionSection
    let stateFingerprint: StateFingerprint
    let cardFingerprint: CardFingerprint?
    let headerFingerprint: HeaderFingerprint
    let commentFingerprints: [UIKitCommentItemFingerprint]
    let forwardIDs: [String]
    let reactionIDs: [String]
    let footerFingerprint: FooterFingerprint?
    let showsReactionBanner: Bool
    let skeletonCount: Int
    let composerClearance: CGFloat

    struct StateFingerprint: Equatable, Hashable, Sendable {
        let isLoading: Bool
        let error: String?
    }

    struct CardFingerprint: Equatable, Hashable, Sendable {
        let id: String
        let liked: Bool
        let likeCount: Int
        let commentCount: Int?
        let forwardCount: Int?
    }

    struct HeaderFingerprint: Equatable, Hashable, Sendable {
        let section: MomentDetailView.InteractionSection
        let commentSort: CommentSort
        let hasCommentSource: Bool
        let commentTotal: Int
        let forwardCount: Int
        let likeCount: Int
        let isAccessibilitySize: Bool
    }

    struct CommentsFooterState: Equatable, Hashable, Sendable {
        let closed: Bool
        let hasOID: Bool
        let loading: Bool
        let empty: Bool
        let loaded: Bool
        let failure: CommentLoadFeedback.Failure?
    }

    struct ForwardsFooterState: Equatable, Hashable, Sendable {
        let loading: Bool
        let loaded: Bool
        let haveMore: Bool
        let empty: Bool
        let failure: MomentDetailViewModel.InteractionLoadFailure?
        let count: Int
        let reported: Int?
    }

    struct LikesFooterState: Equatable, Hashable, Sendable {
        let loggedIn: Bool
        let loading: Bool
        let loaded: Bool
        let haveMore: Bool
        let needCont: Bool
        let unclassified: Bool
        let empty: Bool
        let failure: MomentDetailViewModel.InteractionLoadFailure?
        let count: Int
        let reported: Int?
    }

    enum FooterFingerprint: Equatable, Hashable, Sendable {
        case comments(CommentsFooterState)
        case forwards(ForwardsFooterState)
        case likes(LikesFooterState)
    }
}

struct MomentDetailCollectionActions {
    let onRefresh: @MainActor () async -> Bool
    let onLoadMoreComments: () -> Void
    let onLoadMoreForwards: () -> Void
    let onLoadMoreReactions: () -> Void
    let onOpenPost: (String) -> Void
    let onOpenProfile: (Int) -> Void
    let onOpenVideo: (VideoRouteTarget) -> Void
    let onOpenArticle: (Int) -> Void
    let onOpenLiveRoom: (Int) -> Void
    let onImageTap: (ImagePreviewItem) -> Void
    let onRepost: () -> Void
    let onFocusComment: () -> Void
    let onToggleLike: () -> Void
    let makeStateView: () -> AnyView
    let makeHeaderView: () -> AnyView
    let makeCommentRow: (CommentResult.CommentItem) -> AnyView
    let makeForwardRow: (DynamicForwardItem) -> AnyView
    let makeReactionRow: (MomentDetailViewModel.ReactionEntry) -> AnyView
    let makeReactionBanner: () -> AnyView
    let makeFooterView: () -> AnyView
}

@MainActor
struct MomentDetailCollectionView: View {
    let input: MomentDetailSnapshotInput
    let item: DynamicFeedResult.DynamicItem?
    let comments: [CommentResult.CommentItem]
    let forwards: [DynamicForwardItem]
    let reactions: [MomentDetailViewModel.ReactionEntry]
    let liked: Bool
    let likeCount: Int
    let actions: MomentDetailCollectionActions

    @Environment(\.self) private var hostEnvironment
    @State private var bottomSafeAreaInset: CGFloat = 0

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateBottomSafeArea(proxy.safeAreaInsets.bottom) }
                    .onChange(of: proxy.safeAreaInsets.bottom) { _, inset in
                        updateBottomSafeArea(inset)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            MomentDetailCollectionRepresentable(
                view: self,
                hostEnvironment: hostEnvironment,
                externalBottomSafeAreaInset: bottomSafeAreaInset
            )
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private func updateBottomSafeArea(_ inset: CGFloat) {
        let clamped = max(0, inset)
        guard abs(bottomSafeAreaInset - clamped) > 0.5 else { return }
        bottomSafeAreaInset = clamped
    }
}

private struct MomentDetailCollectionRepresentable: UIViewControllerRepresentable {
    let view: MomentDetailCollectionView
    let hostEnvironment: EnvironmentValues
    let externalBottomSafeAreaInset: CGFloat

    func makeUIViewController(context: Context) -> MomentDetailCollectionViewController {
        let controller = MomentDetailCollectionViewController()
        controller.apply(
            view: view,
            hostEnvironment: hostEnvironment,
            externalBottomSafeAreaInset: externalBottomSafeAreaInset
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: MomentDetailCollectionViewController, context: Context) {
        uiViewController.apply(
            view: view,
            hostEnvironment: hostEnvironment,
            externalBottomSafeAreaInset: externalBottomSafeAreaInset
        )
    }

    static func dismantleUIViewController(_ uiViewController: MomentDetailCollectionViewController, coordinator: ()) {
        uiViewController.tearDown()
    }
}

enum MomentDetailSectionKey: Hashable, Sendable {
    case state, card, interactions
}

enum MomentDetailCellKey: Hashable, Sendable {
    case state
    case card(String)
    case header
    case comment(Int)
    case commentSkeleton(Int)
    case forward(String)
    case reaction(String)
    case reactionBanner
    case footer
}

@MainActor
final class MomentDetailPanelBackgroundView: UICollectionReusableView {
    static let kind = "moment-detail-panel-background"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = AppRadius.panel
        layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
