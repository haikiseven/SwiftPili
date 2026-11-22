import SwiftUI
import UIKit

struct FollowingFailureOverlay: View {
    enum Kind: Equatable {
        case privacy
        case cancelled
        case other(String)
    }

    let kind: Kind
    let isFollowingMode: Bool
    let onRetry: () -> Void

    var body: some View {
        switch kind {
        case .privacy:
            ContentUnavailableView {
                Label("Hidden", systemImage: "lock")
            } description: {
                if isFollowingMode {
                    Text("This user's following list is private.")
                } else {
                    Text("This user's followers list is private.")
                }
            } actions: {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
            }
        case .cancelled:
            MessageLoadFailureView(message: nil, retry: onRetry)
        case .other(let message):
            ContentUnavailableView {
                Label("Load Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
            }
        }
    }
}

struct FollowingGroupChipsBar: View {
    let tags: [RelationTag]
    let selectedTag: Int?
    let labelForTag: (RelationTag) -> String
    let onSelectTag: (Int?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.s) {
                groupChip(nil, label: String(localized: "All"), count: nil)
                ForEach(tags) { tag in
                    groupChip(tag.tagid, label: labelForTag(tag), count: tag.count)
                }
            }
            .padding(.horizontal, AppSpacing.l)
            .padding(.vertical, AppSpacing.s)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func groupChip(_ tagid: Int?, label: String, count: Int?) -> some View {
        let active = selectedTag == tagid
        return Button {
            onSelectTag(tagid)
        } label: {
            HStack(spacing: 4) {
                if tagid == -10 {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                }
                Text(label)
                    .font(.footnote)
                    .fontWeight(active ? .semibold : .regular)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                active
                    ? AnyShapeStyle(Color.biliAccent.opacity(0.14))
                    : AnyShapeStyle(Color(.tertiarySystemFill)),
                in: Capsule()
            )
            .foregroundStyle(active ? AnyShapeStyle(.biliAccent) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.appControl)
    }
}

struct FollowingRowData: Identifiable, Equatable {
    let mid: Int
    let uname: String
    let face: String
    let sign: String?
    let isFollowing: Bool
    let isFollowBusy: Bool
    let showsGroupButton: Bool
    let showsSeparator: Bool

    var id: Int { mid }
}

struct FollowingCollectionView: View {
    let rows: [FollowingRowData]
    var placeholderCount: Int = 0
    var placeholderLabel: String = ""
    var footerState: MineFeedFooterState = .none
    var paginationGeneration: UInt64 = 0
    var onRefresh: (@MainActor () async -> Bool)?
    let onNearEndAppear: () -> Void
    let onFooterAction: () -> Void
    let onSelectUser: (Int) -> Void
    let onGroupTap: (Int) -> Void
    let onFollowTap: (Int) -> Void

    var body: some View {
        let config = FollowingCollectionConfig(
            rows: rows,
            placeholderCount: placeholderCount,
            placeholderLabel: placeholderLabel,
            footerState: footerState,
            paginationGeneration: paginationGeneration,
            onNearEndAppear: onNearEndAppear,
            onFooterAction: onFooterAction,
            onSelectUser: onSelectUser,
            onGroupTap: onGroupTap,
            onFollowTap: onFollowTap
        )
        UIKitCollectionHost(
            onRefresh: onRefresh,
            makeController: { FollowingCollectionViewController() },
            updateController: { controller in controller.update(config) }
        )
    }
}

@MainActor
private struct FollowingCollectionConfig {
    let rows: [FollowingRowData]
    let placeholderCount: Int
    let placeholderLabel: String
    let footerState: MineFeedFooterState
    let paginationGeneration: UInt64
    let onNearEndAppear: () -> Void
    let onFooterAction: () -> Void
    let onSelectUser: (Int) -> Void
    let onGroupTap: (Int) -> Void
    let onFollowTap: (Int) -> Void
}

private enum FollowingSectionKey: Hashable, Sendable {
    case users
    case skeletons
}

private enum FollowingCellKey: Hashable, Sendable {
    case user(Int)
    case skeleton(Int)
}

@MainActor
private final class FollowingCollectionViewController: UIKitBaseCollectionViewController,
    UICollectionViewDataSourcePrefetching {
    private struct PaginationKey: Hashable {
        let count: Int
        let lastID: Int?
    }

    private var dataSource: UICollectionViewDiffableDataSource<FollowingSectionKey, FollowingCellKey>?
    private var rows: [FollowingRowData] = []
    private var rowByID: [Int: FollowingRowData] = [:]
    private var rowIndexByID: [Int: Int] = [:]
    private var placeholderCount = 0
    private var placeholderLabel = ""
    private var footerState: MineFeedFooterState = .none
    private var paginationGeneration: UInt64 = 0

    private var onNearEndAppear: () -> Void = {}
    private var onFooterAction: () -> Void = {}
    private var onSelectUser: (Int) -> Void = { _ in }
    private var onGroupTap: (Int) -> Void = { _ in }
    private var onFollowTap: (Int) -> Void = { _ in }
    private var geometryTask: Task<Void, Never>?

    override func makeCollectionLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, layoutEnvironment in
            guard let self else { return nil }
            var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
            listConfig.backgroundColor = .clear
            listConfig.showsSeparators = false

            let section = NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: layoutEnvironment)
            let effectiveWidth = layoutEnvironment.container.effectiveContentSize.width
            let sideInset = max(0, ((effectiveWidth - ReadableWidth.feed) / 2).rounded(.down))
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0,
                leading: sideInset,
                bottom: UIKitFeedLayoutMetrics.bottomInset,
                trailing: sideInset
            )

            let sections = dataSource?.snapshot().sectionIdentifiers ?? []
            let isSkeleton = sectionIndex < sections.count && sections[sectionIndex] == .skeletons
            if !isSkeleton, footerState != .none {
                let footerSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(64)
                )
                section.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: footerSize,
                        elementKind: UICollectionView.elementKindSectionFooter,
                        alignment: .bottom
                    ),
                ]
            }
            return section
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.prefetchDataSource = self
        configureDataSource()
        applySnapshot()
    }

    override func contentWidthDidChange(from oldWidth: CGFloat, to newWidth: CGFloat) {
        guard abs(newWidth - lastReconfiguredWidth) > 1.5 else { return }
        collectionView.collectionViewLayout.invalidateLayout()
        scheduleGeometryReconfigure()
    }

    override func traitsDidChange() {
        scheduleGeometryReconfigure()
    }

    override func tearDown() {
        geometryTask?.cancel()
        geometryTask = nil
        super.tearDown()
    }

    override func shouldSelectItem(at indexPath: IndexPath) -> Bool {
        userID(at: indexPath) != nil
    }

    override func didSelectItem(at indexPath: IndexPath) {
        guard let mid = userID(at: indexPath) else { return }
        onSelectUser(mid)
    }

    override func willDisplayItem(at indexPath: IndexPath) {
        guard let mid = userID(at: indexPath),
              let index = rowIndexByID[mid] else {
            return
        }
        let key = PaginationKey(count: rows.count, lastID: rows.last?.id)
        triggerNearEndPaginationIfNeeded(
            index: index,
            totalCount: rows.count,
            key: key,
            action: onNearEndAppear
        )
    }

    func update(_ config: FollowingCollectionConfig) {
        onNearEndAppear = config.onNearEndAppear
        onFooterAction = config.onFooterAction
        onSelectUser = config.onSelectUser
        onGroupTap = config.onGroupTap
        onFollowTap = config.onFollowTap

        let rowsChanged = config.rows != rows
        let placeholderChanged = config.placeholderCount != placeholderCount
            || config.placeholderLabel != placeholderLabel
        let footerChanged = config.footerState != footerState
        let generationChanged = config.paginationGeneration != paginationGeneration

        guard rowsChanged || placeholderChanged || footerChanged || generationChanged else { return }

        let previousCount = rows.count
        let previousByID = rowByID
        let hadFooter = footerState != .none && !rows.isEmpty
        let hadErrorFooter: Bool = if case .error = footerState { true } else { false }

        rows = config.rows
        rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rowIndexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        placeholderCount = config.placeholderCount
        placeholderLabel = config.placeholderLabel
        footerState = config.footerState
        paginationGeneration = config.paginationGeneration

        if rows.count != previousCount || generationChanged || (hadErrorFooter && footerState == .none) {
            resetPaginationGate()
        }

        guard rowsChanged || placeholderChanged || footerChanged else { return }

        let hasFooter = footerState != .none && !rows.isEmpty
        if isViewLoaded {
            var reconfigure: [FollowingCellKey] = []
            for row in rows where previousByID[row.id] != row {
                reconfigure.append(.user(row.id))
            }
            applySnapshot(reconfigureKeys: reconfigure)
            if hadFooter != hasFooter {
                collectionView.collectionViewLayout.invalidateLayout()
            }
            if footerChanged, hasFooter {
                updateVisibleFooter()
            }
        }
    }

    // MARK: - UICollectionViewDataSourcePrefetching

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetchCoordinator.prefetch(at: indexPaths) { [weak self] indexPath in
            guard let self,
                  let mid = userID(at: indexPath),
                  let row = rowByID[mid] else { return nil }
            return UIKitCoverPipeline.avatarRequest(
                urlString: row.face,
                pointSize: 44,
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

    // MARK: - Private

    private func configureDataSource() {
        let userReg = UICollectionView.CellRegistration<
            UIKitUserRowCell,
            FollowingRowData
        > { [weak self] cell, _, row in
            guard let self else { return }
            let mid = row.mid
            cell.configure(UIKitUserRowCell.Model(
                title: row.uname,
                subtitle: row.sign,
                avatarURL: row.face,
                avatarSize: 44,
                horizontalPadding: AppSpacing.l,
                verticalPadding: 10,
                showsSeparator: row.showsSeparator,
                accessory: .followControls(
                    showsGroupButton: row.showsGroupButton,
                    isFollowing: row.isFollowing,
                    isFollowBusy: row.isFollowBusy,
                    onGroupTap: { [weak self] in self?.onGroupTap(mid) },
                    onFollowTap: { [weak self] in self?.onFollowTap(mid) }
                )
            ))
        }
        let skeletonReg = UICollectionView.CellRegistration<
            UIKitUserRowSkeletonCell,
            Int
        > { [weak self] cell, _, index in
            guard let self else { return }
            cell.configure(
                avatarSize: 44,
                horizontalPadding: AppSpacing.l,
                accessibilityLabel: index == 0 && !placeholderLabel.isEmpty ? placeholderLabel : nil
            )
        }
        let footerReg = UICollectionView.SupplementaryRegistration<MineFeedFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            guard let self else { return }
            view.configure(state: footerState, onAction: { [weak self] in
                self?.onFooterAction()
            })
        }

        let source = UICollectionViewDiffableDataSource<FollowingSectionKey, FollowingCellKey>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, cellKey in
            guard let self else { return nil }
            switch cellKey {
            case .user(let mid):
                guard let row = rowByID[mid] else { return nil }
                return collectionView.dequeueConfiguredReusableCell(using: userReg, for: indexPath, item: row)
            case .skeleton(let index):
                return collectionView.dequeueConfiguredReusableCell(using: skeletonReg, for: indexPath, item: index)
            }
        }
        source.supplementaryViewProvider = { collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionFooter else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footerReg, for: indexPath)
        }
        dataSource = source
    }

    private func applySnapshot(reconfigureKeys: [FollowingCellKey] = [], reconfigureAll: Bool = false) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<FollowingSectionKey, FollowingCellKey>()

        if rows.isEmpty {
            if placeholderCount > 0 {
                snapshot.appendSections([.skeletons])
                snapshot.appendItems((0..<placeholderCount).map { .skeleton($0) }, toSection: .skeletons)
            }
        } else {
            snapshot.appendSections([.users])
            snapshot.appendItems(rows.map { .user($0.id) }, toSection: .users)
        }

        if reconfigureAll {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
        } else if !reconfigureKeys.isEmpty {
            let valid = Set(snapshot.itemIdentifiers)
            let targets = reconfigureKeys.filter { valid.contains($0) }
            if !targets.isEmpty { snapshot.reconfigureItems(targets) }
        }

        lastReconfiguredWidth = currentContentWidth
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func updateVisibleFooter() {
        let indexPath = IndexPath(item: 0, section: 0)
        if let footer = collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionFooter,
            at: indexPath
        ) as? MineFeedFooterView {
            footer.configure(state: footerState, onAction: { [weak self] in
                self?.onFooterAction()
            })
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    private func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            applySnapshot(reconfigureAll: true)
        }
    }

    private func userID(at indexPath: IndexPath) -> Int? {
        guard let key = dataSource?.itemIdentifier(for: indexPath),
              case .user(let mid) = key else { return nil }
        return mid
    }
}
