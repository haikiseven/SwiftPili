import SwiftUI
import UIKit

struct FavoriteFolderRowData: Identifiable, Equatable {
    let folder: FavoriteFolderResult.FavoriteFolder
    let previews: [FavoriteContentResult.FavoriteMedia]
    let isPreviewLoaded: Bool
    let needsPreview: Bool

    var id: Int { folder.id }

    init(
        folder: FavoriteFolderResult.FavoriteFolder,
        previews: [FavoriteContentResult.FavoriteMedia],
        isPreviewLoaded: Bool,
        needsPreview: Bool? = nil
    ) {
        self.folder = folder
        self.previews = previews
        self.isPreviewLoaded = isPreviewLoaded
        self.needsPreview = needsPreview ?? !isPreviewLoaded
    }

    func hasVisualDifference(from other: Self) -> Bool {
        folder.id != other.folder.id
            || folder.title != other.folder.title
            || folder.mediaCount != other.folder.mediaCount
            || isPreviewLoaded != other.isPreviewLoaded
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
    private var dataSource: UICollectionViewDiffableDataSource<FavoritesSectionKey, FavoritesCellKey>?
    private var rows: [FavoriteFolderRowData] = []
    private var rowByID: [Int: FavoriteFolderRowData] = [:]
    private var placeholderCount = 0
    private var placeholderLabel = ""
    private var isMutating = false
    private var previewGeneration: UInt64 = 0
    private var coverPresentation = CoverPresentationStore.shared.presentation

    private var onNeedPreview: (Int) -> Void = { _ in }
    private var onOpenFolder: (Int, String) -> Void = { _, _ in }
    private var onSelectVideo: (VideoRouteTarget) -> Void = { _ in }
    private var onRequestDelete: (FavoriteFolderResult.FavoriteFolder) -> Void = { _ in }
    private var geometryTask: Task<Void, Never>?
    private var previewCheckTask: Task<Void, Never>?

    override var allowsSelectionHighlight: Bool { false }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, layoutEnvironment in
            var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
            listConfig.backgroundColor = .clear
            listConfig.showsSeparators = true
            listConfig.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipeActions(at: indexPath)
            }
            let section = NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: layoutEnvironment)
            let isSkeleton = self?.dataSource?.snapshot().sectionIdentifiers[sectionIndex] == .skeletons
            if isSkeleton {
                section.interGroupSpacing = AppSpacing.m
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: AppSpacing.m,
                    leading: AppSpacing.l,
                    bottom: AppSpacing.m,
                    trailing: AppSpacing.l
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
              let row = rowByID[folderID],
              row.needsPreview || !row.isPreviewLoaded else {
            return
        }
        onNeedPreview(folderID)
    }

    func update(_ config: FavoritesCollectionConfig) {
        onNeedPreview = config.onNeedPreview
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

        let previousByID = rowByID
        rows = config.rows
        rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        placeholderCount = config.placeholderCount
        placeholderLabel = config.placeholderLabel
        previewGeneration = config.previewGeneration
        coverPresentation = config.coverPresentation

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
        }
    }

    private func trailingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isMutating,
              let key = dataSource?.itemIdentifier(for: indexPath),
              case .folder(let folderID) = key,
              let row = rowByID[folderID] else {
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
                    }
                )
            }
        )
        let skeletonReg = UICollectionView.CellRegistration<FavoriteFolderSkeletonCell, Int>(
            handler: { [weak self] cell, _, index in
                guard let self else { return }
                cell.configure(
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
                  row.needsPreview || !row.isPreviewLoaded else {
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
    private let subtitleShape = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isUserInteractionEnabled = false
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = UIColor(AppFill.card)
        background.cornerRadius = AppRadius.panel
        backgroundConfiguration = background

        iconShape.translatesAutoresizingMaskIntoConstraints = false
        iconShape.backgroundColor = .secondarySystemFill
        iconShape.layer.cornerRadius = AppRadius.control
        iconShape.layer.cornerCurve = .continuous
        contentView.addSubview(iconShape)

        titleShape.translatesAutoresizingMaskIntoConstraints = false
        titleShape.backgroundColor = .secondarySystemFill
        titleShape.layer.cornerRadius = AppRadius.badge
        titleShape.layer.cornerCurve = .continuous
        contentView.addSubview(titleShape)

        subtitleShape.translatesAutoresizingMaskIntoConstraints = false
        subtitleShape.backgroundColor = .secondarySystemFill
        subtitleShape.alpha = 0.65
        subtitleShape.layer.cornerRadius = AppRadius.badge
        subtitleShape.layer.cornerCurve = .continuous
        contentView.addSubview(subtitleShape)

        NSLayoutConstraint.activate([
            iconShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            iconShape.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            iconShape.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            iconShape.widthAnchor.constraint(equalToConstant: 44),
            iconShape.heightAnchor.constraint(equalToConstant: 44),
            titleShape.leadingAnchor.constraint(equalTo: iconShape.trailingAnchor, constant: 12),
            titleShape.topAnchor.constraint(equalTo: iconShape.topAnchor, constant: 6),
            titleShape.widthAnchor.constraint(equalToConstant: 148),
            titleShape.heightAnchor.constraint(equalToConstant: 14),
            subtitleShape.leadingAnchor.constraint(equalTo: titleShape.leadingAnchor),
            subtitleShape.topAnchor.constraint(equalTo: titleShape.bottomAnchor, constant: 6),
            subtitleShape.widthAnchor.constraint(equalToConstant: 88),
            subtitleShape.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    func configure(accessibilityLabel: String?) {
        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
    }
}
