import SwiftUI
import UIKit

@MainActor
final class UIKitFolderIconView: UIView {
    private let iconView = UIImageView(image: UIImage(systemName: "folder.fill"))
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        layer.cornerRadius = size * 0.24
        layer.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(weight: .medium)
        addSubview(iconView)

        let iconSize = size * 0.42
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
        ])
        refreshAccent()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            refreshAccent()
        }
    }

    func refreshAccent() {
        let accent = UIColor(AccentStore.shared.semanticAccent)
        backgroundColor = accent.withAlphaComponent(0.14)
        iconView.tintColor = accent
    }
}

@MainActor
final class FavoriteFolderShelfCell: UICollectionViewListCell {
    private enum ShelfItem {
        case skeleton(Int)
        case media(FavoriteContentResult.FavoriteMedia)
        case seeMore
    }

    private static let compactStatusHeight: CGFloat = 44

    private let headerButton = UIButton(type: .custom)
    private let folderIcon = UIKitFolderIconView(size: 28)
    private let titleLabel = UILabel()
    private let privateIconView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let countLabel = UILabel()
    private let countPill = UIView()
    private let seeMoreLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let statusContainer = UIView()
    private let statusStack = UIStackView()
    private let statusIcon = UIImageView()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    private lazy var shelfLayout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        return layout
    }()
    private lazy var shelfCollectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: shelfLayout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceHorizontal = true
        view.clipsToBounds = true
        view.dataSource = self
        view.delegate = self
        view.prefetchDataSource = self
        return view
    }()
    private let prefetchCoordinator = UIKitPrefetchCoordinator()
    private var shelfHeightConstraint: NSLayoutConstraint?
    private var headerLeadingConstraint: NSLayoutConstraint?
    private var headerTrailingConstraint: NSLayoutConstraint?
    private var statusLeadingConstraint: NSLayoutConstraint?
    private var statusTrailingConstraint: NSLayoutConstraint?

    private var shelfItems: [ShelfItem] = []
    private var cardWidth: CGFloat = 128
    private var cardHeight: CGFloat = 80
    private var coverPresentation = CoverPresentationStore.shared.presentation
    private var onOpenFolder: (() -> Void)?
    private var onSelectVideo: ((VideoRouteTarget) -> Void)?
    private var onRetryPreview: (() -> Void)?

    private var previewRegistration:
        UICollectionView.CellRegistration<FavoriteShelfPreviewCell, FavoriteContentResult.FavoriteMedia>?
    private var skeletonRegistration:
        UICollectionView.CellRegistration<FavoriteShelfSkeletonCardCell, Int>?
    private var seeMoreRegistration:
        UICollectionView.CellRegistration<FavoriteShelfSeeMoreCell, CGSize>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        automaticallyUpdatesBackgroundConfiguration = false
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .clear
        backgroundConfiguration = background

        setupHeader()
        setupShelf()
        registerShelfCells()
        activateConstraints()
    }

    private func setupHeader() {
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.addTarget(self, action: #selector(handleHeaderTap), for: .touchUpInside)
        headerButton.addTarget(self, action: #selector(handleHeaderTouchDown), for: [.touchDown, .touchDragEnter])
        headerButton.addTarget(
            self,
            action: #selector(handleHeaderTouchUp),
            for: [.touchDragExit, .touchUpInside, .touchUpOutside, .touchCancel]
        )
        contentView.addSubview(headerButton)

        let row = UIStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isUserInteractionEnabled = false
        headerButton.addSubview(row)

        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        privateIconView.tintColor = .secondaryLabel
        privateIconView.contentMode = .scaleAspectFit
        privateIconView.isHidden = true
        privateIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        privateIconView.setContentHuggingPriority(.required, for: .horizontal)

        countPill.backgroundColor = .tertiarySystemFill
        countPill.layer.cornerCurve = .continuous
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.textColor = .secondaryLabel
        countLabel.numberOfLines = 1
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countPill.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(equalTo: countPill.topAnchor, constant: 2),
            countLabel.bottomAnchor.constraint(equalTo: countPill.bottomAnchor, constant: -2),
            countLabel.leadingAnchor.constraint(equalTo: countPill.leadingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: countPill.trailingAnchor, constant: -6),
        ])

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        seeMoreLabel.text = String(localized: "See More")
        seeMoreLabel.textColor = .secondaryLabel
        seeMoreLabel.numberOfLines = 1
        seeMoreLabel.adjustsFontForContentSizeCategory = true
        seeMoreLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevronView.tintColor = .secondaryLabel
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addArrangedSubview(folderIcon)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(privateIconView)
        row.addArrangedSubview(countPill)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(seeMoreLabel)
        row.addArrangedSubview(chevronView)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: headerButton.topAnchor),
            row.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: headerButton.bottomAnchor),
        ])
    }

    private func setupShelf() {
        shelfCollectionView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(shelfCollectionView)

        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.backgroundColor = .tertiarySystemFill
        statusContainer.layer.cornerRadius = AppRadius.control
        statusContainer.layer.cornerCurve = .continuous
        statusContainer.isHidden = true
        contentView.addSubview(statusContainer)

        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.spacing = 8
        statusContainer.addSubview(statusStack)

        statusIcon.contentMode = .scaleAspectFit
        statusIcon.tintColor = .tertiaryLabel
        statusIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusSpacer = UIView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var retryConfig = UIButton.Configuration.plain()
        retryConfig.title = String(localized: "Retry")
        retryConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        retryButton.configuration = retryConfig
        retryButton.addTarget(self, action: #selector(handleRetryTap), for: .touchUpInside)
        retryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        retryButton.setContentHuggingPriority(.required, for: .horizontal)

        statusStack.addArrangedSubview(statusIcon)
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(statusSpacer)
        statusStack.addArrangedSubview(retryButton)

        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 12),
            statusStack.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -8),
            statusStack.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
        ])
    }

    private func registerShelfCells() {
        previewRegistration = UICollectionView.CellRegistration<
            FavoriteShelfPreviewCell,
            FavoriteContentResult.FavoriteMedia
        > { [weak self] cell, _, item in
            guard let self else { return }
            cell.configure(
                item: item,
                cardWidth: cardWidth,
                cardHeight: cardHeight,
                coverPresentation: coverPresentation
            )
        }
        skeletonRegistration = UICollectionView.CellRegistration<
            FavoriteShelfSkeletonCardCell,
            Int
        > { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(cardWidth: cardWidth, cardHeight: cardHeight)
        }
        seeMoreRegistration = UICollectionView.CellRegistration<
            FavoriteShelfSeeMoreCell,
            CGSize
        > { cell, _, size in
            cell.configure(size: size)
        }
    }

    private func activateConstraints() {
        let shelfHeight = shelfCollectionView.heightAnchor.constraint(equalToConstant: 140)
        shelfHeightConstraint = shelfHeight
        let headerLeading = headerButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        let headerTrailing = headerButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        let statusLeading = statusContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        let statusTrailing = statusContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        headerLeadingConstraint = headerLeading
        headerTrailingConstraint = headerTrailing
        statusLeadingConstraint = statusLeading
        statusTrailingConstraint = statusTrailing

        NSLayoutConstraint.activate([
            headerButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            headerLeading,
            headerTrailing,
            headerButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),

            shelfCollectionView.topAnchor.constraint(equalTo: headerButton.bottomAnchor, constant: 10),
            shelfCollectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shelfCollectionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            shelfCollectionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            shelfHeight,

            statusLeading,
            statusTrailing,
            statusContainer.topAnchor.constraint(equalTo: shelfCollectionView.topAnchor),
            statusContainer.bottomAnchor.constraint(equalTo: shelfCollectionView.bottomAnchor),
        ])
    }

    func configure(
        row: FavoriteFolderRowData,
        containerWidth: CGFloat,
        coverPresentation: CoverPresentation,
        onOpenFolder: @escaping () -> Void,
        onSelectVideo: @escaping (VideoRouteTarget) -> Void,
        onRetryPreview: (() -> Void)? = nil
    ) {
        self.onOpenFolder = onOpenFolder
        self.onSelectVideo = onSelectVideo
        self.onRetryPreview = onRetryPreview
        self.coverPresentation = coverPresentation

        folderIcon.refreshAccent()
        headerButton.alpha = 1.0

        let traits = traitCollection
        let resolvedWidth = containerWidth > 1 ? containerWidth : FeedWidth.fullContainerSeed
        let margin = FeedColumnPolicy.horizontalMargin(for: resolvedWidth)
        headerLeadingConstraint?.constant = margin
        headerTrailingConstraint?.constant = -margin
        statusLeadingConstraint?.constant = margin
        statusTrailingConstraint?.constant = -margin
        shelfLayout.sectionInset = UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)

        let availableShelfWidth = max(240, resolvedWidth - margin * 2)
        cardWidth = FeedColumnPolicy.shelfCardWidth(availableWidth: availableShelfWidth)
        cardHeight = coverPresentation.height(forWidth: cardWidth)

        configureHeaderLabels(row: row, traits: traits)
        configureShelfItems(row: row, traits: traits)

        prefetchCoordinator.cancelAll()
        shelfLayout.invalidateLayout()
        shelfCollectionView.reloadData()
    }

    private func configureHeaderLabels(row: FavoriteFolderRowData, traits: UITraitCollection) {
        titleLabel.text = row.folder.title
        titleLabel.font = UIKitFeedFont.systemFont(textStyle: .subheadline, weight: .semibold, traitCollection: traits)

        let showsPrivate = row.folder.isPrivate
        privateIconView.isHidden = !showsPrivate
        if showsPrivate {
            privateIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                font: UIKitFeedFont.systemFont(textStyle: .caption2, weight: .semibold, traitCollection: traits)
            )
        }

        if let count = row.folder.mediaCount {
            countPill.isHidden = false
            countLabel.text = "\(count)"
            countLabel.font = UIKitFeedFont.systemFont(
                textStyle: .caption,
                weight: .medium,
                monospacedDigit: true,
                traitCollection: traits
            )
            countPill.layer.cornerRadius = ceil(countLabel.font.lineHeight + 4) / 2
        } else {
            countPill.isHidden = true
        }

        seeMoreLabel.font = UIKitFeedFont.systemFont(textStyle: .caption, weight: .medium, traitCollection: traits)
        chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: UIKitFeedFont.systemFont(textStyle: .caption2, weight: .semibold, traitCollection: traits)
        )
        statusLabel.font = UIKitFeedFont.systemFont(textStyle: .caption, traitCollection: traits)
        statusIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: UIKitFeedFont.systemFont(textStyle: .caption, weight: .medium, traitCollection: traits)
        )
        retryButton.tintColor = UIColor(AccentStore.shared.semanticAccent)

        var accessibilityParts = [row.folder.title]
        if showsPrivate { accessibilityParts.append(String(localized: "Private")) }
        accessibilityParts.append(String(localized: "See More"))
        headerButton.accessibilityLabel = accessibilityParts.joined(separator: ", ")
    }

    private func configureShelfItems(row: FavoriteFolderRowData, traits: UITraitCollection) {
        let titleFont = UIKitFeedFont.font(for: .shelfCardTitle, weight: .medium, traitCollection: traits)
        let metaFont = UIKitFeedFont.font(for: .cardMeta, traitCollection: traits)
        let cardTotalHeight = cardHeight + 5 + ceil(titleFont.lineHeight * 2) + 5 + ceil(metaFont.lineHeight) + 2

        if row.isPreviewFailed && row.previews.isEmpty {
            statusContainer.isHidden = false
            statusIcon.image = UIImage(systemName: "exclamationmark.triangle")
            statusIcon.tintColor = .secondaryLabel
            statusLabel.text = String(localized: "Failed to load preview")
            statusLabel.textColor = .secondaryLabel
            retryButton.isHidden = onRetryPreview == nil
            shelfCollectionView.isHidden = true
            shelfHeightConstraint?.constant = Self.compactStatusHeight
            shelfItems = []
        } else if !row.isPreviewLoaded {
            statusContainer.isHidden = true
            shelfCollectionView.isHidden = false
            shelfCollectionView.isUserInteractionEnabled = false
            shelfHeightConstraint?.constant = cardTotalHeight
            shelfItems = (0..<3).map { .skeleton($0) }
        } else if row.previews.isEmpty {
            statusContainer.isHidden = false
            statusIcon.image = UIImage(systemName: "folder")
            statusIcon.tintColor = .tertiaryLabel
            statusLabel.text = String(localized: "Empty Folder")
            statusLabel.textColor = .tertiaryLabel
            retryButton.isHidden = true
            shelfCollectionView.isHidden = true
            shelfHeightConstraint?.constant = Self.compactStatusHeight
            shelfItems = []
        } else {
            statusContainer.isHidden = true
            shelfCollectionView.isHidden = false
            shelfCollectionView.isUserInteractionEnabled = true
            shelfHeightConstraint?.constant = cardTotalHeight
            var next: [ShelfItem] = row.previews.map { .media($0) }
            if let count = row.folder.mediaCount, count > row.previews.count {
                next.append(.seeMore)
            }
            shelfItems = next
        }
    }

    @objc private func handleHeaderTap() {
        onOpenFolder?()
    }

    @objc private func handleHeaderTouchDown() {
        if UIAccessibility.isReduceMotionEnabled {
            headerButton.alpha = 0.6
        } else {
            UIView.animate(withDuration: 0.1) { self.headerButton.alpha = 0.6 }
        }
    }

    @objc private func handleHeaderTouchUp() {
        if UIAccessibility.isReduceMotionEnabled {
            headerButton.alpha = 1.0
        } else {
            UIView.animate(withDuration: 0.16) { self.headerButton.alpha = 1.0 }
        }
    }

    @objc private func handleRetryTap() {
        onRetryPreview?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        prefetchCoordinator.cancelAll()
        onOpenFolder = nil
        onSelectVideo = nil
        onRetryPreview = nil
        headerButton.alpha = 1.0
        shelfItems = []
        shelfCollectionView.setContentOffset(.zero, animated: false)
    }
}

extension FavoriteFolderShelfCell: UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout,
    UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        shelfItems.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        switch shelfItems[indexPath.item] {
        case .skeleton(let index):
            guard let reg = skeletonRegistration else { return UICollectionViewCell() }
            return collectionView.dequeueConfiguredReusableCell(using: reg, for: indexPath, item: index)
        case .media(let media):
            guard let reg = previewRegistration else { return UICollectionViewCell() }
            return collectionView.dequeueConfiguredReusableCell(using: reg, for: indexPath, item: media)
        case .seeMore:
            guard let reg = seeMoreRegistration else { return UICollectionViewCell() }
            let tileWidth = (cardWidth * 2 / 3).rounded()
            return collectionView.dequeueConfiguredReusableCell(
                using: reg,
                for: indexPath,
                item: CGSize(width: tileWidth, height: cardHeight)
            )
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let totalHeight = shelfHeightConstraint?.constant ?? (cardHeight + 56)
        switch shelfItems[indexPath.item] {
        case .seeMore:
            return CGSize(width: (cardWidth * 2 / 3).rounded(), height: totalHeight)
        case .skeleton, .media:
            return CGSize(width: cardWidth, height: totalHeight)
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch shelfItems[indexPath.item] {
        case .skeleton: return false
        case .media(let media): return media.isPlayableVideo
        case .seeMore: return true
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        switch shelfItems[indexPath.item] {
        case .skeleton:
            break
        case .media(let media):
            if let target = favoriteRouteTarget(media) {
                onSelectVideo?(target)
            }
        case .seeMore:
            onOpenFolder?()
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.prefetch(at: indexPaths) { [weak self] indexPath in
            guard let self, indexPath.item < shelfItems.count,
                  case .media(let media) = shelfItems[indexPath.item] else { return nil }
            return UIKitCoverPipeline.request(
                sources: VideoCoverSources(widescreen: media.cover ?? ""),
                drawnBox: CGSize(width: cardWidth, height: cardHeight),
                presentation: coverPresentation,
                scale: traitCollection.displayScale
            )
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        prefetchCoordinator.cancelPrefetching(at: indexPaths)
    }
}
