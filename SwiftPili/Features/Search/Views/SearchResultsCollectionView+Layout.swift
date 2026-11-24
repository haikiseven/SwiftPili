import SwiftUI
import UIKit

extension SearchResultsCollectionViewController {
    struct CellRegistrations {
        let video: UICollectionView.CellRegistration<UIKitRowVideoCell, SearchResultItemData.VideoPayload>
        let bangumi: UICollectionView.CellRegistration<SearchBangumiCell, SearchResultItemData.BangumiPayload>
        let user: UICollectionView.CellRegistration<SearchUserCardCell, SearchResultItemData.UserPayload>
        let live: UICollectionView.CellRegistration<UIKitLiveGridCell, SearchResultItemData.LivePayload>
        let article: UICollectionView.CellRegistration<SearchArticleCell, SearchResultItemData.ArticlePayload>
        let skRow: UICollectionView.CellRegistration<UIKitRowSkeletonCell, Int>
        let skLive: UICollectionView.CellRegistration<UIKitGridSkeletonCell, Int>
        let skUser: UICollectionView.CellRegistration<UIKitUserRowSkeletonCell, Int>
        let spinner: UICollectionView.CellRegistration<SearchPaginationSpinnerCell, Void>
    }

    func configureDataSource() {
        let regs = makeCellRegistrations()
        let dataSource = UICollectionViewDiffableDataSource<SearchSectionKey, SearchCellKey>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, cellKey in
            self?.dequeueCell(in: collectionView, at: indexPath, cellKey: cellKey, regs: regs)
        }
        configureSupplementaryViews(on: dataSource)
        self.dataSource = dataSource
    }

    private func makeCellRegistrations() -> CellRegistrations {
        let video = makeVideoRegistration()
        let bangumi = makeBangumiRegistration()
        let user = makeUserRegistration()
        let live = makeLiveRegistration()
        let article = makeArticleRegistration()
        let loadingLabel = String(localized: "Loading search results")
        let skRow = UICollectionView.CellRegistration<UIKitRowSkeletonCell, Int> { [weak self] cell, _, index in
            guard let self else { return }
            cell.configure(
                style: .feed, columnWidth: videoColumnWidth, coverPresentation: coverPresentation,
                accessibilityLabel: index == 0 ? loadingLabel : nil
            )
        }
        let skLive = UICollectionView.CellRegistration<UIKitGridSkeletonCell, Int> { [weak self] cell, _, index in
            guard let self else { return }
            cell.configure(
                columnWidth: liveColumnWidth, coverPresentation: coverPresentation,
                accessibilityLabel: index == 0 ? loadingLabel : nil
            )
        }
        let skUser = UICollectionView.CellRegistration<UIKitUserRowSkeletonCell, Int> { cell, _, index in
            cell.configure(avatarSize: 48, horizontalPadding: 0, accessibilityLabel: index == 0 ? loadingLabel : nil)
        }
        let spinner = UICollectionView.CellRegistration<SearchPaginationSpinnerCell, Void> { cell, _, _ in
            cell.configure()
        }
        return CellRegistrations(
            video: video, bangumi: bangumi, user: user, live: live, article: article,
            skRow: skRow, skLive: skLive, skUser: skUser, spinner: spinner
        )
    }

    private func makeVideoRegistration()
        -> UICollectionView.CellRegistration<UIKitRowVideoCell, SearchResultItemData.VideoPayload> {
        UICollectionView.CellRegistration { [weak self] cell, _, payload in
            guard let self else { return }
            cell.configure(UIKitRowVideoCell.Model(
                style: .feed, title: payload.title, sources: payload.sources,
                duration: payload.durationSeconds,
                subtitle: .metaLine(ownerName: payload.author, viewCount: payload.playCount),
                columnWidth: videoColumnWidth, coverPresentation: coverPresentation
            ))
        }
    }

    private func makeBangumiRegistration()
        -> UICollectionView.CellRegistration<SearchBangumiCell, SearchResultItemData.BangumiPayload> {
        UICollectionView.CellRegistration { cell, _, payload in
            cell.configure(SearchBangumiCell.Model(
                title: payload.title, coverURL: payload.coverURL, seasonTypeName: payload.seasonTypeName,
                score: payload.score, userCount: payload.userCount, areas: payload.areas,
                styles: payload.styles, indexShow: payload.indexShow, desc: payload.desc
            ))
        }
    }

    private func makeUserRegistration()
        -> UICollectionView.CellRegistration<SearchUserCardCell, SearchResultItemData.UserPayload> {
        UICollectionView.CellRegistration { [weak self] cell, indexPath, payload in
            let activeGeneration = self?.generation ?? 0
            let videos = payload.representativeVideos.map {
                SearchUserCardCell.VideoItem(
                    title: $0.title, sources: $0.sources,
                    durationSeconds: $0.durationSeconds, playCount: $0.playCount
                )
            }
            let tier = SearchUserOfficialVerify(
                type: payload.officialVerifyType,
                desc: payload.officialVerifyDesc
            ).verificationTier
            let showsSeparator = self?.showsUserSeparator(at: indexPath) ?? false
            cell.configure(SearchUserCardCell.Model(
                uname: payload.uname, avatarURL: payload.avatarURL,
                verificationTier: tier,
                officialVerifyDesc: payload.officialVerifyDesc,
                fans: payload.fans, videos: payload.videos, usign: payload.usign,
                isLive: payload.isLive, representativeVideos: videos,
                showsSeparator: showsSeparator
            )) { [weak self] videoIndex in
                guard let self, let actions = self.actions, actions.isCurrentResult(activeGeneration),
                      videoIndex < payload.representativeVideos.count,
                      let target = payload.representativeVideos[videoIndex].routeTarget else { return }
                actions.onSelectVideo(target)
            }
        }
    }

    private func makeLiveRegistration()
        -> UICollectionView.CellRegistration<UIKitLiveGridCell, SearchResultItemData.LivePayload> {
        UICollectionView.CellRegistration { [weak self] cell, _, payload in
            guard let self else { return }
            let onlineText = payload.online > 0 ? FormatUtils.viewCount(payload.online) : ""
            cell.configure(UIKitLiveGridCell.Model(
                title: payload.title, uname: payload.uname, areaName: payload.areaName,
                coverURL: payload.coverURL, displayOnline: onlineText, liveStatus: payload.liveStatus,
                columnWidth: liveColumnWidth, coverPresentation: coverPresentation
            ))
        }
    }

    private func makeArticleRegistration()
        -> UICollectionView.CellRegistration<SearchArticleCell, SearchResultItemData.ArticlePayload> {
        UICollectionView.CellRegistration { cell, _, payload in
            cell.configure(SearchArticleCell.Model(
                title: payload.title, coverURL: payload.coverURL, author: payload.author,
                categoryName: payload.categoryName, viewCount: payload.viewCount,
                likeCount: payload.likeCount, desc: payload.desc
            ))
        }
    }

    private func dequeueCell(
        in collectionView: UICollectionView,
        at indexPath: IndexPath,
        cellKey: SearchCellKey,
        regs: CellRegistrations
    ) -> UICollectionViewCell? {
        switch cellKey {
        case .bucketItem(_, _, let id), .resultItem(_, _, let id):
            return dequeueEntityCell(in: collectionView, at: indexPath, id: id, regs: regs)
        case .skeletonRow(let index):
            return collectionView.dequeueConfiguredReusableCell(using: regs.skRow, for: indexPath, item: index)
        case .skeletonLive(let index):
            return collectionView.dequeueConfiguredReusableCell(using: regs.skLive, for: indexPath, item: index)
        case .skeletonUser(let index):
            return collectionView.dequeueConfiguredReusableCell(using: regs.skUser, for: indexPath, item: index)
        case .loadingFooter:
            return collectionView.dequeueConfiguredReusableCell(using: regs.spinner, for: indexPath, item: ())
        }
    }

    private func dequeueEntityCell(
        in collectionView: UICollectionView,
        at indexPath: IndexPath,
        id: String,
        regs: CellRegistrations
    ) -> UICollectionViewCell? {
        guard let item = itemByID[id] else { return nil }
        switch item.kind {
        case .video(let payload):
            return collectionView.dequeueConfiguredReusableCell(using: regs.video, for: indexPath, item: payload)
        case .bangumi(let payload):
            return collectionView.dequeueConfiguredReusableCell(using: regs.bangumi, for: indexPath, item: payload)
        case .user(let payload):
            return collectionView.dequeueConfiguredReusableCell(using: regs.user, for: indexPath, item: payload)
        case .liveRoom(let payload):
            return collectionView.dequeueConfiguredReusableCell(using: regs.live, for: indexPath, item: payload)
        case .article(let payload):
            return collectionView.dequeueConfiguredReusableCell(using: regs.article, for: indexPath, item: payload)
        }
    }

    private func configureSupplementaryViews(
        on dataSource: UICollectionViewDiffableDataSource<SearchSectionKey, SearchCellKey>
    ) {
        let headerReg = UICollectionView.SupplementaryRegistration<UIKitFeedSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self, let section = self.sectionKey(at: indexPath.section),
                  case .bucket(let bucketType) = section else { return }
            view.configure(
                title: self.bucketTitle(for: bucketType),
                showsDivider: false,
                textStyle: .subheadline,
                weight: .semibold,
                color: .label
            )
        }
        let footerReg = UICollectionView.SupplementaryRegistration<SearchBucketDisclosureFooterView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self, let section = self.sectionKey(at: indexPath.section),
                  case .bucket(let bucketType) = section else { return }
            let activeGeneration = self.generation
            let title = String(format: String(localized: "View more %@"), self.bucketTitle(for: bucketType))
            view.configure(title: title) { [weak self] in
                guard let self, let actions = self.actions, actions.isCurrentResult(activeGeneration) else { return }
                actions.onSwitchToType(bucketType)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footerReg, for: indexPath)
        }
    }

    private func sectionKey(at index: Int) -> SearchSectionKey? {
        index < currentSections.count ? currentSections[index] : nil
    }

    private func bucketTitle(for type: SearchType) -> String {
        switch type {
        case .bangumi: String(localized: "Anime")
        case .user: String(localized: "Users")
        case .liveRoom: String(localized: "Live")
        case .article: String(localized: "Articles")
        case .all, .video: ""
        }
    }

    func layoutSection(
        for key: SearchSectionKey,
        contentWidth: CGFloat,
        traitCollection: UITraitCollection,
        isFirst: Bool,
        isLast: Bool
    ) -> NSCollectionLayoutSection {
        let hInset = UIKitFeedLayoutMetrics.horizontalInset
        let top = isFirst ? AppSpacing.m : AppSpacing.s
        let bottom = isLast ? AppSpacing.l : AppSpacing.s

        switch key {
        case .bucket(let bucketType):
            let section = entityLayoutSection(
                for: bucketType, contentWidth: contentWidth, traitCollection: traitCollection, top: top, bottom: bottom
            )
            var supplementaries = [
                NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(36)
                    ),
                    elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top
                ),
            ]
            if bucketByType[bucketType]?.hasMore == true {
                supplementaries.append(NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(44)
                    ),
                    elementKind: UICollectionView.elementKindSectionFooter,
                    alignment: .bottom
                ))
            }
            section.boundarySupplementaryItems = supplementaries
            return section
        case .results, .skeletons:
            let targetType: SearchType = searchType == .all ? .video : searchType
            return entityLayoutSection(
                for: targetType, contentWidth: contentWidth, traitCollection: traitCollection, top: top, bottom: bottom
            )
        case .loadingFooter:
            return makeLayoutSection(
                columns: 1,
                estimatedHeight: 56,
                insets: NSDirectionalEdgeInsets(
                    top: AppSpacing.m, leading: hInset, bottom: AppSpacing.xl, trailing: hInset
                ),
                interGroupSpacing: 0
            )
        }
    }

    private func entityLayoutSection(
        for entityType: SearchType,
        contentWidth: CGFloat,
        traitCollection: UITraitCollection,
        top: CGFloat,
        bottom: CGFloat
    ) -> NSCollectionLayoutSection {
        let hInset = UIKitFeedLayoutMetrics.horizontalInset
        switch entityType {
        case .user:
            let readableWidth = ReadableWidth.capped(contentWidth, to: ReadableWidth.feed)
            let spacing: CGFloat = sectionHasRepresentativeVideos(for: entityType) ? AppSpacing.s : 0
            return makeLayoutSection(
                columns: 1,
                estimatedHeight: spacing > 0 ? 156 : 84,
                insets: NSDirectionalEdgeInsets(
                    top: top, leading: hInset, bottom: bottom,
                    trailing: hInset + max(0, contentWidth - readableWidth)
                ),
                interGroupSpacing: spacing
            )
        case .liveRoom:
            let count = max(1, FeedColumnPolicy.columnCount(.liveGrid, availableWidth: contentWidth))
            let colWidth = FeedColumnPolicy.columnWidth(
                availableWidth: contentWidth, count: count, spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
            )
            return makeLayoutSection(
                columns: count,
                estimatedHeight: max(80, coverPresentation.height(forWidth: colWidth) + 46),
                insets: NSDirectionalEdgeInsets(top: top, leading: hInset, bottom: bottom, trailing: hInset),
                interGroupSpacing: UIKitFeedLayoutMetrics.gridRowSpacing
            )
        case .bangumi, .article:
            let count = max(1, FeedColumnPolicy.columnCount(.videoRow, availableWidth: contentWidth))
            return makeLayoutSection(
                columns: count,
                estimatedHeight: entityType == .bangumi ? 136 : 96,
                insets: NSDirectionalEdgeInsets(top: top, leading: hInset, bottom: bottom, trailing: hInset),
                interGroupSpacing: UIKitFeedLayoutMetrics.listRowSpacing
            )
        case .all, .video:
            let count = max(1, FeedColumnPolicy.columnCount(.videoRow, availableWidth: contentWidth))
            let colWidth = FeedColumnPolicy.columnWidth(
                availableWidth: contentWidth, count: count, spacing: UIKitFeedLayoutMetrics.gridColumnSpacing
            )
            let isRegular = traitCollection.horizontalSizeClass == .regular
            let coverWidth = RowCardMetrics.coverWidth(columnWidth: colWidth, isRegularWidth: isRegular)
            return makeLayoutSection(
                columns: count,
                estimatedHeight: max(60, coverPresentation.height(forWidth: coverWidth)),
                insets: NSDirectionalEdgeInsets(top: top, leading: hInset, bottom: bottom, trailing: hInset),
                interGroupSpacing: UIKitFeedLayoutMetrics.listRowSpacing
            )
        }
    }

    private func makeLayoutSection(
        columns: Int,
        estimatedHeight: CGFloat,
        insets: NSDirectionalEdgeInsets,
        interGroupSpacing: CGFloat
    ) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .estimated(estimatedHeight)
        )
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(estimatedHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = columns > 1
            ? NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
            : NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        if columns > 1 { group.interItemSpacing = .fixed(UIKitFeedLayoutMetrics.gridColumnSpacing) }
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = interGroupSpacing
        section.contentInsets = insets
        return section
    }

    func applySnapshot(
        reconfigureKeys: [SearchCellKey] = [],
        reconfigureAll: Bool = false,
        reconfigureSkeletons: Bool = false
    ) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<SearchSectionKey, SearchCellKey>()

        if buckets.isEmpty && items.isEmpty {
            if isSearching {
                snapshot.appendSections([.skeletons])
                let keys = skeletonKeys()
                snapshot.appendItems(keys, toSection: .skeletons)
                if reconfigureSkeletons || reconfigureAll { snapshot.reconfigureItems(keys) }
            }
            lastReconfiguredWidth = currentContentWidth
            currentSections = snapshot.sectionIdentifiers
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }

        var allKeys: [SearchCellKey] = []
        for bucket in buckets where !bucket.items.isEmpty {
            let sectionKey = SearchSectionKey.bucket(bucket.targetType)
            snapshot.appendSections([sectionKey])
            let keys = bucket.items.map {
                SearchCellKey.bucketItem(generation: generation, bucket: bucket.targetType, id: $0.id)
            }
            snapshot.appendItems(keys, toSection: sectionKey)
            allKeys.append(contentsOf: keys)
        }

        if !items.isEmpty {
            snapshot.appendSections([.results])
            let resultKeys = items.map {
                SearchCellKey.resultItem(generation: generation, tab: searchType, id: $0.id)
            }
            snapshot.appendItems(resultKeys, toSection: .results)
            allKeys.append(contentsOf: resultKeys)
        }

        if isSearching {
            snapshot.appendSections([.loadingFooter])
            snapshot.appendItems([.loadingFooter], toSection: .loadingFooter)
        }

        if reconfigureAll {
            snapshot.reconfigureItems(allKeys)
        } else if !reconfigureKeys.isEmpty {
            let valid = Set(allKeys)
            let targets = reconfigureKeys.filter { valid.contains($0) }
            if !targets.isEmpty { snapshot.reconfigureItems(targets) }
        }
        lastReconfiguredWidth = currentContentWidth
        currentSections = snapshot.sectionIdentifiers
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func skeletonKeys() -> [SearchCellKey] {
        switch searchType {
        case .user: (0..<8).map { .skeletonUser($0) }
        case .liveRoom: (0..<max(liveColumnCount * 3, 6)).map { .skeletonLive($0) }
        case .all, .video, .bangumi, .article: (0..<max(videoColumnCount * 4, 6)).map { .skeletonRow($0) }
        }
    }

    func scheduleGeometryReconfigure() {
        geometryTask?.cancel()
        geometryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            applySnapshot(reconfigureAll: true, reconfigureSkeletons: true)
        }
    }

    func item(at indexPath: IndexPath) -> SearchResultItemData? {
        guard let cellKey = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        switch cellKey {
        case .bucketItem(_, _, let id), .resultItem(_, _, let id): return itemByID[id]
        case .skeletonRow, .skeletonLive, .skeletonUser, .loadingFooter: return nil
        }
    }

    func coverRequest(for indexPath: IndexPath) -> UIKitCoverPipeline.CoverRequest? {
        guard let item = item(at: indexPath) else { return nil }
        let scale = traitCollection.displayScale
        switch item.kind {
        case .video(let payload):
            let isRegular = traitCollection.horizontalSizeClass == .regular
            let coverWidth = RowCardMetrics.coverWidth(columnWidth: videoColumnWidth, isRegularWidth: isRegular)
            return UIKitCoverPipeline.request(
                sources: payload.sources,
                drawnBox: coverPresentation.size(width: max(1, coverWidth)),
                presentation: coverPresentation,
                scale: scale
            )
        case .bangumi(let payload):
            return SearchBangumiCell.coverRequest(coverURL: payload.coverURL, scale: scale)
        case .user(let payload):
            return UIKitCoverPipeline.avatarRequest(urlString: payload.avatarURL, pointSize: 48, scale: scale)
        case .liveRoom(let payload):
            return UIKitCoverPipeline.request(
                sources: .singleUnclassified(payload.coverURL),
                drawnBox: coverPresentation.size(width: max(1, liveColumnWidth)),
                presentation: coverPresentation,
                scale: scale
            )
        case .article(let payload):
            guard let url = payload.coverURL, !url.isEmpty else { return nil }
            return SearchArticleCell.coverRequest(coverURL: url, scale: scale)
        }
    }
}
