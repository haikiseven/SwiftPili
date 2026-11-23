import SwiftUI
import UIKit

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

struct CommentFeedEnvironmentSnapshot: Equatable {
    var colorScheme: ColorScheme = .light
    var dynamicTypeSize: DynamicTypeSize = .large
    var horizontalSizeClass: UserInterfaceSizeClass?
    var appSurface: AppSurface = .standard
    var layoutDirection: LayoutDirection = .leftToRight
    var rowCardColumnWidth: CGFloat?
    var displayScale: CGFloat = 2
    var locale: Locale = .autoupdatingCurrent
    var accessibilityReduceMotion: Bool = false
    var accessibilityReduceTransparency: Bool = false
    var imageDiagnosticsScreen: String = "-"
    var contentLinkDefersToParent: Bool = false
    var navigationZoomNamespace: Namespace.ID?
    var contentLinkStateKey: ContentLinkStateKey?
}

@MainActor
struct CommentFeedEnvironment {
    var snapshot = CommentFeedEnvironmentSnapshot()
    var rawEnvironment = EnvironmentValues()
    var coordinator: AppCoordinator?
    var noticeCenter: AppNoticeCenter?
    var openURL: OpenURLAction?
    var contentLinkContext: ContentLinkContext?
}

@MainActor
struct UIKitCommentFeedCollectionView: View {
    private var config: UIKitCommentFeedConfiguration

    @Environment(\.self) private var rawEnvironment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appSurface) private var appSurface
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.rowCardColumnWidth) private var rowCardColumnWidth
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.imageDiagnosticsScreen) private var imageDiagnosticsScreen
    @Environment(\.contentLinkDefersToParent) private var contentLinkDefersToParent
    @Environment(\.navigationZoomNamespace) private var navigationZoomNamespace
    @Environment(AppCoordinator.self) private var coordinator: AppCoordinator?
    @Environment(\.appNoticeCenter) private var noticeCenter
    @Environment(\.openURL) private var openURL
    @Environment(\.contentLinkContext) private var contentLinkContext
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

    private var feedEnvironment: CommentFeedEnvironment {
        CommentFeedEnvironment(
            snapshot: CommentFeedEnvironmentSnapshot(
                colorScheme: colorScheme,
                dynamicTypeSize: dynamicTypeSize,
                horizontalSizeClass: horizontalSizeClass,
                appSurface: appSurface,
                layoutDirection: layoutDirection,
                rowCardColumnWidth: rowCardColumnWidth,
                displayScale: displayScale,
                locale: locale,
                accessibilityReduceMotion: accessibilityReduceMotion,
                accessibilityReduceTransparency: accessibilityReduceTransparency,
                imageDiagnosticsScreen: imageDiagnosticsScreen,
                contentLinkDefersToParent: contentLinkDefersToParent,
                navigationZoomNamespace: navigationZoomNamespace,
                contentLinkStateKey: contentLinkContext?.stateKey
            ),
            rawEnvironment: rawEnvironment,
            coordinator: coordinator,
            noticeCenter: noticeCenter,
            openURL: openURL,
            contentLinkContext: contentLinkContext
        )
    }

    private func representable(bottomInset: CGFloat) -> UIKitCommentFeedRepresentable {
        UIKitCommentFeedRepresentable(
            config: config,
            environment: feedEnvironment,
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
    let environment: CommentFeedEnvironment
    let externalBottomSafeAreaInset: CGFloat

    func makeUIViewController(context: Context) -> UIKitCommentFeedViewController {
        let controller = UIKitCommentFeedViewController()
        controller.apply(
            config: config,
            environment: environment,
            externalBottomSafeAreaInset: externalBottomSafeAreaInset
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: UIKitCommentFeedViewController, context: Context) {
        uiViewController.apply(
            config: config,
            environment: environment,
            externalBottomSafeAreaInset: externalBottomSafeAreaInset
        )
    }

    static func dismantleUIViewController(_ uiViewController: UIKitCommentFeedViewController, coordinator: ()) {
        uiViewController.tearDown()
    }
}
