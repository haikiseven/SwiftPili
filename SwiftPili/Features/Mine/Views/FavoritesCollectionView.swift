import SwiftUI
import UIKit

struct FavoriteFolderRowData: Identifiable, Equatable {
    let folder: FavoriteFolderResult.FavoriteFolder
    let previews: [FavoriteContentResult.FavoriteMedia]
    let isPreviewLoaded: Bool
    let isPreviewFailed: Bool
    let needsPreview: Bool
    let isOwned: Bool

    var id: Int { folder.id }

    init(
        folder: FavoriteFolderResult.FavoriteFolder,
        previews: [FavoriteContentResult.FavoriteMedia],
        isPreviewLoaded: Bool,
        isPreviewFailed: Bool = false,
        needsPreview: Bool? = nil,
        isOwned: Bool = true
    ) {
        self.folder = folder
        self.previews = previews
        self.isPreviewLoaded = isPreviewLoaded
        self.isPreviewFailed = isPreviewFailed
        self.needsPreview = needsPreview ?? (!isPreviewLoaded && !isPreviewFailed)
        self.isOwned = isOwned
    }

    func hasVisualDifference(from other: Self) -> Bool {
        folder.id != other.folder.id
            || folder.title != other.folder.title
            || folder.mediaCount != other.folder.mediaCount
            || folder.attr != other.folder.attr
            || folder.upper?.name != other.folder.upper?.name
            || isPreviewLoaded != other.isPreviewLoaded
            || isPreviewFailed != other.isPreviewFailed
            || isOwned != other.isOwned
            || previews.map(\.resourceKey) != other.previews.map(\.resourceKey)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        !lhs.hasVisualDifference(from: rhs)
            && lhs.needsPreview == rhs.needsPreview
    }
}

struct FavoritesCollectionView: View {
    let rows: [FavoriteFolderRowData]
    var placeholderCount: Int = 0
    var placeholderLabel: String = ""
    var isMutating: Bool = false
    var previewGeneration: UInt64 = 0
    var onRefresh: (@MainActor () async -> Bool)?
    let onNeedPreview: (Int) -> Void
    var onRetryPreview: ((Int) -> Void)?
    var onNearEnd: (() -> Void)?
    let onOpenFolder: (Int, String) -> Void
    let onSelectVideo: (VideoRouteTarget) -> Void
    let onRequestDelete: (FavoriteFolderResult.FavoriteFolder) -> Void

    var body: some View {
        let config = FavoritesCollectionConfig(
            rows: rows,
            placeholderCount: placeholderCount,
            placeholderLabel: placeholderLabel,
            isMutating: isMutating,
            previewGeneration: previewGeneration,
            coverPresentation: CoverPresentationStore.shared.presentation,
            onNeedPreview: onNeedPreview,
            onRetryPreview: onRetryPreview,
            onNearEnd: onNearEnd,
            onOpenFolder: onOpenFolder,
            onSelectVideo: onSelectVideo,
            onRequestDelete: onRequestDelete
        )
        UIKitCollectionHost(
            onRefresh: onRefresh,
            makeController: { FavoritesCollectionViewController() },
            updateController: { controller in controller.update(config) }
        )
    }
}

@MainActor
private struct FavoritesCollectionConfig {
    let rows: [FavoriteFolderRowData]
    let placeholderCount: Int
    let placeholderLabel: String
    let isMutating: Bool
    let previewGeneration: UInt64
    let coverPresentation: CoverPresentation
    let onNeedPreview: (Int) -> Void
    let onRetryPreview: ((Int) -> Void)?
    let onNearEnd: (() -> Void)?
    let onOpenFolder: (Int, String) -> Void
    let onSelectVideo: (VideoRouteTarget) -> Void
    let onRequestDelete: (FavoriteFolderResult.FavoriteFolder) -> Void
}

private enum FavoritesSectionKey: Hashable, Sendable {
    case folders
    case skeletons
}

private enum FavoritesCellKey: Hashable, Sendable {
    case folder(Int)
    case skeleton(Int)
}

@MainActor
private final class FavoritesCollectionViewController: UIKitBaseCollectionViewController {
    private struct PaginationKey: Hashable {
        let count: Int
        let lastID: Int?
    }

    private var dataSource: UICollectionViewDiffableDataSource<FavoritesSectionKey, FavoritesCellKey>?
    private var currentSections: [FavoritesSectionKey] = []
    private var rows: [FavoriteFolderRowData] = []
    private var rowByID: [Int: FavoriteFolderRowData] = [:]
    private var rowIndexByID: [Int: Int] = [:]
    private var placeholderCount = 0
    private var placeholderLabel = ""
    private var isMutating = false
    private var previewGeneration: UInt64 = 0
    private var coverPresentation = CoverPresentationStore.shared.presentation

    private var onNeedPreview: (Int) -> Void = { _ in }
    private var onRetryPreview: ((Int) -> Void)?
    private var onNearEnd: (() -> Void)?
    private var onOpenFolder: (Int, String) -> Void = { _, _ in }
    private var onSelectVideo: (VideoRouteTarget) -> Void = { _ in }
    private var onRequestDelete: (FavoriteFolderResult.FavoriteFolder) -> Void = { _ in }
    private var geometryTask: Task<Void, Never>?
    private var previewCheckTask: Task<Void, Never>?

    override var allowsSelectionHighlight: Bool { false }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, layoutEnvironment in
            let isSkeleton = if let self, sectionIndex < self.currentSections.count {
                self.currentSections[sectionIndex] == .skeletons
            } else {
                false
            }
            var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
            listConfig.backgroundColor = .clear
            listConfig.showsSeparators = !isSkeleton
            if !isSkeleton {
                listConfig.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                    self?.trailingSwipeActions(at: indexPath)
                }
            }
            let section = NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: layoutEnvironment)
            if isSkeleton {
                section.interGroupSpacing = AppSpacing.s
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: AppSpacing.xs,
                    leading: 0,
                    bottom: AppSpacing.m,
                    trailing: 0
                )
            }
            return section
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        applySnapshot(reconfigureAll: false)
    }

    override func contentWidthDidChange(from oldWidth: CGFloat, to newWidth: CGFloat) {
        let oldCard = FeedColumnPolicy.shelfCardWidth(availableWidth: oldWidth)
        let newCard = FeedColumnPolicy.shelfCardWidth(availableWidth: newWidth)
        guard oldCard != newCard || abs(newWidth - lastReconfiguredWidth) > 1.5 else { return }
        collectionView.collectionViewLayout.invalidateLayout()
        scheduleGeometryReconfigure()
    }

    override func traitsDidChange() {
        scheduleGeometryReconfigure()
    }

    override func tearDown() {
        geometryTask?.cancel()
        geometryTask = nil
        previewCheckTask?.cancel()
        previewCheckTask = nil
        super.tearDown()
    }

    override func shouldSelectItem(at indexPath: IndexPath) -> Bool { false }

    override func willDisplayItem(at indexPath: IndexPath) {
        guard let key = dataSource?.itemIdentifier(for: indexPath),
              case .folder(let folderID) = key,
              let row = rowByID[folderID] else {
            return
        }
        if row.needsPreview {
            onNeedPreview(folderID)
        }
        if let onNearEnd, let index = rowIndexByID[folderID] {
            let pageKey = PaginationKey(count: rows.count, lastID: rows.last?.id)
            triggerNearEndPaginationIfNeeded(
                index: index,
                totalCount: rows.count,
                key: pageKey,
                action: onNearEnd
            )
        }
    }

    func update(_ config: FavoritesCollectionConfig) {
        onNeedPreview = config.onNeedPreview
        onRetryPreview = config.onRetryPreview
        onNearEnd = config.onNearEnd
        onOpenFolder = config.onOpenFolder
        onSelectVideo = config.onSelectVideo
        onRequestDelete = config.onRequestDelete
        isMutating = config.isMutating

        let rowsChanged = config.rows != rows
        let placeholderChanged = config.placeholderCount != placeholderCount
            || config.placeholderLabel != placeholderLabel
        let presentationChanged = config.coverPresentation != coverPresentation
        let generationChanged = config.previewGeneration != previewGeneration

        guard rowsChanged || placeholderChanged || presentationChanged || generationChanged else { return }

        let previousCount = rows.count
        let previousByID = rowByID
        let wasSkeleton = rows.isEmpty && placeholderCount > 0
        rows = config.rows
        rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rowIndexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        placeholderCount = config.placeholderCount
        placeholderLabel = config.placeholderLabel
        previewGeneration = config.previewGeneration
        coverPresentation = config.coverPresentation
        let isSkeletonNow = rows.isEmpty && placeholderCount > 0

        if rows.count != previousCount {
            resetPaginationGate()
        }

        if isViewLoaded {
            var reconfigure: [FavoritesCellKey] = []
            if !presentationChanged {
                for row in rows {
                    if let previous = previousByID[row.id] {
                        if previous.hasVisualDifference(from: row) {
                            reconfigure.append(.folder(row.id))
                        }
                    } else {
                        reconfigure.append(.folder(row.id))
                    }
                }
            }
            applySnapshot(reconfigureKeys: reconfigure, reconfigureAll: presentationChanged)
            if wasSkeleton != isSkeletonNow {
                collectionView.collectionViewLayout.invalidateLayout()
            }
        }
    }

    private func trailingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isMutating,
              let key = dataSource?.itemIdentifier(for: indexPath),
              case .folder(let folderID) = key,
              let row = rowByID[folderID],
              row.isOwned,
              !row.folder.isDefault else {
            return nil
        }
        let deleteAction = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete Folder")
        ) { [weak self] _, _, completion in
            self?.onRequestDelete(row.folder)
            completion(true)
        }
        deleteAction.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    private func configureDataSource() {
        let folderReg = UICollectionView.CellRegistration<FavoriteFolderShelfCell, FavoriteFolderRowData>(
            handler: { [weak self] cell, _, row in
                guard let self else { return }
                cell.configure(
                    row: row,
                    containerWidth: collectionView.bounds.width,
                    coverPresentation: coverPresentation,
                    onOpenFolder: { [weak self] in
                        self?.onOpenFolder(row.folder.id, row.folder.title)
                    },
                    onSelectVideo: { [weak self] target in
                        self?.onSelectVideo(target)
                    },
                    onRetryPreview: { [weak self] in
                        self?.onRetryPreview?(row.folder.id)
                    }
                )
            }
        )
        let skeletonReg = UICollectionView.CellRegistration<FavoriteFolderSkeletonCell, Int>(
            handler: { [weak self] cell, _, index in
                guard let self else { return }
                cell.configure(
                    containerWidth: collectionView.bounds.width,
                    coverPresentation: coverPresentation,
                    accessibilityLabel: index == 0 && !placeholderLabel.isEmpty ? placeholderLabel : nil
                )
            }
        )

        dataSource = UICollectionViewDiffableDataSource<FavoritesSectionKey, FavoritesCellKey>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, cellKey in
            guard let self else { return nil }
            switch cellKey {
            case .folder(let id):
                guard let row = rowByID[id] else { return nil }
                return collectionView.dequeueConfiguredReusableCell(using: folderReg, for: indexPath, item: row)
            case .skeleton(let index):
                return collectionView.dequeueConfiguredReusableCell(using: skeletonReg, for: indexPath, item: index)
            }
        }
    }

    private func applySnapshot(reconfigureKeys: [FavoritesCellKey] = [], reconfigureAll: Bool = false) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<FavoritesSectionKey, FavoritesCellKey>()

        if rows.isEmpty {
            if placeholderCount > 0 {
                snapshot.appendSections([.skeletons])
                snapshot.appendItems((0..<placeholderCount).map { .skeleton($0) }, toSection: .skeletons)
            }
        } else {
            snapshot.appendSections([.folders])
            snapshot.appendItems(rows.map { .folder($0.id) }, toSection: .folders)
        }

        if reconfigureAll {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        } else if !reconfigureKeys.isEmpty {
            let valid = Set(snapshot.itemIdentifiers)
            let targets = reconfigureKeys.filter { valid.contains($0) }
            if !targets.isEmpty { snapshot.reconfigureItems(targets) }
        }

        currentSections = snapshot.sectionIdentifiers
        lastReconfiguredWidth = currentContentWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        CATransaction.commit()
        scheduleVisiblePreviewRequests()
    }

    private func scheduleVisiblePreviewRequests() {
        previewCheckTask?.cancel()
        previewCheckTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.requestMissingPreviewsForVisibleItems()
        }
    }

    private func requestMissingPreviewsForVisibleItems() {
        guard let dataSource else { return }
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard let key = dataSource.itemIdentifier(for: indexPath),
                  case .folder(let folderID) = key,
                  let row = rowByID[folderID],
                  row.needsPreview else {
                continue
            }
            onNeedPreview(folderID)
        }
    }

    private func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            applySnapshot(reconfigureAll: true)
        }
    }
}

@MainActor
private final class FavoriteFolderSkeletonCell: UICollectionViewListCell {
    private let iconShape = UIView()
    private let titleShape = UIView()
    private let countShape = UIView()
    private let trailingShape = UIView()
    private let shelfClipContainer = UIView()
    private let cardsStack = UIStackView()
    private var cardColumns: [SkeletonCardView] = []
    private var headerLeadingConstraint: NSLayoutConstraint?
    private var headerTrailingConstraint: NSLayoutConstraint?
    private var cardsLeadingConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isUserInteractionEnabled = false
        automaticallyUpdatesBackgroundConfiguration = false
        backgroundConfiguration = .clear()

        iconShape.translatesAutoresizingMaskIntoConstraints = false
        iconShape.backgroundColor = .secondarySystemFill
        iconShape.layer.cornerRadius = 7
        iconShape.layer.cornerCurve = .continuous
        contentView.addSubview(iconShape)

        titleShape.translatesAutoresizingMaskIntoConstraints = false
        titleShape.backgroundColor = .secondarySystemFill
        titleShape.layer.cornerRadius = AppRadius.badge
        titleShape.layer.cornerCurve = .continuous
        contentView.addSubview(titleShape)

        countShape.translatesAutoresizingMaskIntoConstraints = false
        countShape.backgroundColor = .tertiarySystemFill
        countShape.layer.cornerRadius = 9
        countShape.layer.cornerCurve = .continuous
        contentView.addSubview(countShape)

        trailingShape.translatesAutoresizingMaskIntoConstraints = false
        trailingShape.backgroundColor = .tertiarySystemFill
        trailingShape.layer.cornerRadius = AppRadius.badge
        trailingShape.layer.cornerCurve = .continuous
        contentView.addSubview(trailingShape)

        shelfClipContainer.translatesAutoresizingMaskIntoConstraints = false
        shelfClipContainer.clipsToBounds = true
        contentView.addSubview(shelfClipContainer)

        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        cardsStack.axis = .horizontal
        cardsStack.alignment = .top
        cardsStack.spacing = 10
        shelfClipContainer.addSubview(cardsStack)

        for _ in 0..<4 {
            let card = SkeletonCardView()
            cardColumns.append(card)
            cardsStack.addArrangedSubview(card)
        }

        let headerLeading = iconShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        let headerTrailing = trailingShape.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        let cardsLeading = cardsStack.leadingAnchor.constraint(equalTo: shelfClipContainer.leadingAnchor, constant: 16)
        headerLeadingConstraint = headerLeading
        headerTrailingConstraint = headerTrailing
        cardsLeadingConstraint = cardsLeading

        NSLayoutConstraint.activate([
            headerLeading,
            iconShape.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            iconShape.widthAnchor.constraint(equalToConstant: 28),
            iconShape.heightAnchor.constraint(equalToConstant: 28),

            titleShape.leadingAnchor.constraint(equalTo: iconShape.trailingAnchor, constant: 8),
            titleShape.centerYAnchor.constraint(equalTo: iconShape.centerYAnchor),
            titleShape.widthAnchor.constraint(equalToConstant: 118),
            titleShape.heightAnchor.constraint(equalToConstant: 14),

            countShape.leadingAnchor.constraint(equalTo: titleShape.trailingAnchor, constant: 8),
            countShape.centerYAnchor.constraint(equalTo: iconShape.centerYAnchor),
            countShape.widthAnchor.constraint(equalToConstant: 28),
            countShape.heightAnchor.constraint(equalToConstant: 18),

            headerTrailing,
            trailingShape.centerYAnchor.constraint(equalTo: iconShape.centerYAnchor),
            trailingShape.widthAnchor.constraint(equalToConstant: 52),
            trailingShape.heightAnchor.constraint(equalToConstant: 12),

            shelfClipContainer.topAnchor.constraint(equalTo: iconShape.bottomAnchor, constant: 10),
            shelfClipContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shelfClipContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            shelfClipContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            cardsLeading,
            cardsStack.topAnchor.constraint(equalTo: shelfClipContainer.topAnchor),
            cardsStack.bottomAnchor.constraint(equalTo: shelfClipContainer.bottomAnchor),
        ])
    }

    func configure(
        containerWidth: CGFloat,
        coverPresentation: CoverPresentation,
        accessibilityLabel: String?
    ) {
        let resolvedWidth = containerWidth > 1 ? containerWidth : FeedWidth.fullContainerSeed
        let margin = FeedColumnPolicy.horizontalMargin(for: resolvedWidth)
        headerLeadingConstraint?.constant = margin
        headerTrailingConstraint?.constant = -margin
        cardsLeadingConstraint?.constant = margin

        let availableShelfWidth = max(240, resolvedWidth - margin * 2)
        let cardWidth = FeedColumnPolicy.shelfCardWidth(availableWidth: availableShelfWidth)
        let cardHeight = coverPresentation.height(forWidth: cardWidth)
        for card in cardColumns {
            card.configure(width: cardWidth, coverHeight: cardHeight)
        }

        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
    }

    @MainActor
    private final class SkeletonCardView: UIView {
        private let coverShape = UIView()
        private let titleOne = UIView()
        private let titleTwo = UIView()
        private let metaShape = UIView()
        private var widthConstraint: NSLayoutConstraint?
        private var coverHeightConstraint: NSLayoutConstraint?

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setup() {
            translatesAutoresizingMaskIntoConstraints = false
            coverShape.translatesAutoresizingMaskIntoConstraints = false
            coverShape.backgroundColor = .secondarySystemFill
            coverShape.layer.cornerRadius = AppRadius.thumbnail
            coverShape.layer.cornerCurve = .continuous
            addSubview(coverShape)

            for shape in [titleOne, titleTwo, metaShape] {
                shape.translatesAutoresizingMaskIntoConstraints = false
                shape.backgroundColor = .secondarySystemFill
                shape.layer.cornerRadius = AppRadius.badge
                shape.layer.cornerCurve = .continuous
                addSubview(shape)
            }
            metaShape.alpha = 0.65

            let w = widthAnchor.constraint(equalToConstant: 136)
            let h = coverShape.heightAnchor.constraint(equalToConstant: 78)
            widthConstraint = w
            coverHeightConstraint = h

            NSLayoutConstraint.activate([
                w,
                coverShape.topAnchor.constraint(equalTo: topAnchor),
                coverShape.leadingAnchor.constraint(equalTo: leadingAnchor),
                coverShape.trailingAnchor.constraint(equalTo: trailingAnchor),
                h,
                titleOne.topAnchor.constraint(equalTo: coverShape.bottomAnchor, constant: 7),
                titleOne.leadingAnchor.constraint(equalTo: leadingAnchor),
                titleOne.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.88),
                titleOne.heightAnchor.constraint(equalToConstant: 11),
                titleTwo.topAnchor.constraint(equalTo: titleOne.bottomAnchor, constant: 4),
                titleTwo.leadingAnchor.constraint(equalTo: leadingAnchor),
                titleTwo.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.56),
                titleTwo.heightAnchor.constraint(equalToConstant: 11),
                metaShape.topAnchor.constraint(equalTo: titleTwo.bottomAnchor, constant: 7),
                metaShape.leadingAnchor.constraint(equalTo: leadingAnchor),
                metaShape.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.42),
                metaShape.heightAnchor.constraint(equalToConstant: 10),
                metaShape.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        func configure(width: CGFloat, coverHeight: CGFloat) {
            widthConstraint?.constant = max(1, width)
            coverHeightConstraint?.constant = max(1, coverHeight)
        }
    }
}
