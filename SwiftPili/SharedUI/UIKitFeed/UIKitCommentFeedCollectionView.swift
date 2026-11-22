import SwiftUI
import UIKit

/// Configuration payload passed from `UIKitCommentFeedCollectionView` into its
/// UIKit collection view controller.
@MainActor
struct UIKitCommentFeedConfiguration {
    var headerItems: [UIKitCommentFeedItem] = []
    var items: [UIKitCommentFeedItem] = []
    var footerContent: AnyView?
    var footerFingerprint: AnyHashableSendable?
    var skeletonCount: Int = 0
    var highlightedItemID: AnyHashableSendable?
    var scrollToItemID: AnyHashableSendable?
    var scrollToPosition: UICollectionView.ScrollPosition = .centeredVertically
    var showsItemDividers: Bool = false
    var dividerLeadingInset: CGFloat = 0
    var itemSpacing: CGFloat = AppSpacing.l
    var headerSpacing: CGFloat = AppSpacing.s
    var horizontalInset: CGFloat = AppSpacing.l
    var topInset: CGFloat = AppSpacing.s
    var maxContentWidth: CGFloat?
    var bottomClearance: CGFloat = 0
    var ignoresBottomSafeArea: Bool = false
    var showsScrollIndicators: Bool = true
    var keyboardDismissMode: UIScrollView.KeyboardDismissMode = .onDrag
    var thresholdOffset: Int = 4
    var onRefresh: (@MainActor () async -> Bool)?
    var onScrollOffsetChange: ((CGFloat) -> Void)?
    var onWillDisplayItemAt: ((Int) -> Void)?
}

/// Reusable SwiftUI-hosted `UICollectionView` engine for comment lists, reply
/// threads, and detail comment surfaces with prefetching, pull-to-refresh,
/// scroll-to-target, highlight state, dividers, and environment preservation.
@MainActor
struct UIKitCommentFeedCollectionView: View {
    private var config: UIKitCommentFeedConfiguration

    @Environment(\.self) private var hostEnvironment
    @State private var bottomSafeAreaInset: CGFloat = 0

    init(
        headerItems: [UIKitCommentFeedItem] = [],
        items: [UIKitCommentFeedItem],
        footerContent: AnyView? = nil,
        footerFingerprint: AnyHashableSendable? = nil,
        skeletonCount: Int = 0,
        highlightedItemID: AnyHashableSendable? = nil,
        scrollToItemID: AnyHashableSendable? = nil,
        scrollToPosition: UICollectionView.ScrollPosition = .centeredVertically,
        showsItemDividers: Bool = false,
        dividerLeadingInset: CGFloat = 0,
        itemSpacing: CGFloat = AppSpacing.l,
        headerSpacing: CGFloat = AppSpacing.s,
        horizontalInset: CGFloat = AppSpacing.l,
        topInset: CGFloat = AppSpacing.s,
        maxContentWidth: CGFloat? = nil,
        bottomClearance: CGFloat = 0,
        ignoresBottomSafeArea: Bool = false,
        showsScrollIndicators: Bool = true,
        keyboardDismissMode: UIScrollView.KeyboardDismissMode = .onDrag,
        thresholdOffset: Int = 4,
        onRefresh: (@MainActor () async -> Bool)? = nil,
        onScrollOffsetChange: ((CGFloat) -> Void)? = nil,
        onWillDisplayItemAt: ((Int) -> Void)? = nil
    ) {
        config = UIKitCommentFeedConfiguration(
            headerItems: headerItems,
            items: items,
            footerContent: footerContent,
            footerFingerprint: footerFingerprint,
            skeletonCount: skeletonCount,
            highlightedItemID: highlightedItemID,
            scrollToItemID: scrollToItemID,
            scrollToPosition: scrollToPosition,
            showsItemDividers: showsItemDividers,
            dividerLeadingInset: dividerLeadingInset,
            itemSpacing: itemSpacing,
            headerSpacing: headerSpacing,
            horizontalInset: horizontalInset,
            topInset: topInset,
            maxContentWidth: maxContentWidth,
            bottomClearance: bottomClearance,
            ignoresBottomSafeArea: ignoresBottomSafeArea,
            showsScrollIndicators: showsScrollIndicators,
            keyboardDismissMode: keyboardDismissMode,
            thresholdOffset: thresholdOffset,
            onRefresh: onRefresh,
            onScrollOffsetChange: onScrollOffsetChange,
            onWillDisplayItemAt: onWillDisplayItemAt
        )
    }

    init<RowContent: View>(
        comments: [CommentResult.CommentItem],
        headerContent: AnyView? = nil,
        headerFingerprint: AnyHashableSendable? = nil,
        footerContent: AnyView? = nil,
        footerFingerprint: AnyHashableSendable? = nil,
        skeletonCount: Int = 0,
        highlightedItemID: AnyHashableSendable? = nil,
        scrollToItemID: AnyHashableSendable? = nil,
        scrollToPosition: UICollectionView.ScrollPosition = .centeredVertically,
        showsItemDividers: Bool = false,
        dividerLeadingInset: CGFloat = 0,
        itemSpacing: CGFloat = AppSpacing.l,
        headerSpacing: CGFloat = AppSpacing.s,
        horizontalInset: CGFloat = AppSpacing.l,
        topInset: CGFloat = AppSpacing.s,
        maxContentWidth: CGFloat? = nil,
        bottomClearance: CGFloat = 0,
        ignoresBottomSafeArea: Bool = false,
        showsScrollIndicators: Bool = true,
        keyboardDismissMode: UIScrollView.KeyboardDismissMode = .onDrag,
        thresholdOffset: Int = 4,
        onRefresh: (@MainActor () async -> Bool)? = nil,
        onScrollOffsetChange: ((CGFloat) -> Void)? = nil,
        onWillDisplayItemAt: ((Int) -> Void)? = nil,
        @ViewBuilder rowContent: @escaping @MainActor (CommentResult.CommentItem) -> RowContent
    ) {
        let headers: [UIKitCommentFeedItem] = headerContent.map { view in
            [UIKitCommentFeedItem(
                id: "comment-feed-header",
                fingerprint: headerFingerprint ?? AnyHashableSendable(0),
                hasExplicitFingerprint: headerFingerprint != nil,
                content: { view }
            )]
        } ?? []
        let rows = comments.map { comment in
            UIKitCommentFeedItem(comment: comment) {
                rowContent(comment)
            }
        }
        self.init(
            headerItems: headers,
            items: rows,
            footerContent: footerContent,
            footerFingerprint: footerFingerprint,
            skeletonCount: skeletonCount,
            highlightedItemID: highlightedItemID,
            scrollToItemID: scrollToItemID,
            scrollToPosition: scrollToPosition,
            showsItemDividers: showsItemDividers,
            dividerLeadingInset: dividerLeadingInset,
            itemSpacing: itemSpacing,
            headerSpacing: headerSpacing,
            horizontalInset: horizontalInset,
            topInset: topInset,
            maxContentWidth: maxContentWidth,
            bottomClearance: bottomClearance,
            ignoresBottomSafeArea: ignoresBottomSafeArea,
            showsScrollIndicators: showsScrollIndicators,
            keyboardDismissMode: keyboardDismissMode,
            thresholdOffset: thresholdOffset,
            onRefresh: onRefresh,
            onScrollOffsetChange: onScrollOffsetChange,
            onWillDisplayItemAt: onWillDisplayItemAt
        )
    }

    var body: some View {
        if config.ignoresBottomSafeArea {
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

                representable(bottomInset: bottomSafeAreaInset)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        } else {
            representable(bottomInset: 0)
        }
    }

    private func representable(bottomInset: CGFloat) -> UIKitCommentFeedRepresentable {
        UIKitCommentFeedRepresentable(
            config: config,
            hostEnvironment: hostEnvironment,
            externalBottomSafeAreaInset: bottomInset
        )
    }

    private func updateBottomSafeArea(_ inset: CGFloat) {
        let clamped = max(0, inset)
        guard abs(bottomSafeAreaInset - clamped) > 0.5 else { return }
        bottomSafeAreaInset = clamped
    }
}

private struct UIKitCommentFeedRepresentable: UIViewControllerRepresentable {
    let config: UIKitCommentFeedConfiguration
    let hostEnvironment: EnvironmentValues
    let externalBottomSafeAreaInset: CGFloat

    func makeUIViewController(context: Context) -> UIKitCommentFeedViewController {
        let controller = UIKitCommentFeedViewController()
        controller.apply(
            config: config,
            hostEnvironment: hostEnvironment,
            externalBottomSafeAreaInset: externalBottomSafeAreaInset
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: UIKitCommentFeedViewController, context: Context) {
        uiViewController.apply(
            config: config,
            hostEnvironment: hostEnvironment,
            externalBottomSafeAreaInset: externalBottomSafeAreaInset
        )
    }

    static func dismantleUIViewController(_ uiViewController: UIKitCommentFeedViewController, coordinator: ()) {
        uiViewController.tearDown()
    }
}
