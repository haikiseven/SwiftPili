import SwiftUI
import UIKit

/// Pure UIKit live stream grid cell matching `LiveCardView`.
@MainActor
final class UIKitLiveGridCell: UICollectionViewCell {
    struct Model {
        let title: String
        let uname: String
        let areaName: String?
        let coverURL: String
        let displayOnline: String
        let liveStatus: Int?
        let columnWidth: CGFloat
        let coverPresentation: CoverPresentation
    }

    private let coverBox = UIKitCoverBoxView()
    private let statusBadge = UIKitMediaBadgeView()
    private let onlineBadge = UIKitMediaBadgeView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()

    private var coverHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button

        coverBox.translatesAutoresizingMaskIntoConstraints = false
        coverBox.configureStyle(
            cornerRadius: VideoCardMetrics.cornerRadius,
            scrim: .cardBottom,
            showsBorder: true
        )
        contentView.addSubview(coverBox)

        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.isHidden = true
        coverBox.addSubview(statusBadge)

        onlineBadge.translatesAutoresizingMaskIntoConstraints = false
        onlineBadge.isHidden = true
        coverBox.addSubview(onlineBadge)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        contentView.addSubview(titleLabel)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.textColor = .secondaryLabel
        metaLabel.adjustsFontForContentSizeCategory = true
        contentView.addSubview(metaLabel)

        let coverHeight = coverBox.heightAnchor.constraint(equalToConstant: 112)
        coverHeightConstraint = coverHeight

        NSLayoutConstraint.activate([
            coverBox.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverHeight,
            statusBadge.topAnchor.constraint(equalTo: coverBox.topAnchor, constant: 6),
            statusBadge.leadingAnchor.constraint(equalTo: coverBox.leadingAnchor, constant: 6),
            onlineBadge.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: -6),
            onlineBadge.bottomAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            metaLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            metaLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    func configure(_ model: Model) {
        let coverSize = model.coverPresentation.size(width: max(1, model.columnWidth))
        coverHeightConstraint?.constant = max(1, coverSize.height)

        let request = UIKitCoverPipeline.request(
            sources: .singleUnclassified(model.coverURL),
            drawnBox: coverSize,
            presentation: model.coverPresentation,
            scale: traitCollection.displayScale
        )
        coverBox.setCover(request: request)
        coverBox.alpha = LiveRoomStatusPolicy.shouldDimListCard(liveStatus: model.liveStatus) ? 0.55 : 1.0

        let traits = traitCollection
        if let liveStatus = model.liveStatus {
            let state = LiveRoomStatusPolicy.state(liveStatus: liveStatus)
            statusBadge.configureLiveState(state, traitCollection: traits)
        } else {
            statusBadge.isHidden = true
        }
        onlineBadge.configureOnlineCount(model.displayOnline, traitCollection: traits)

        titleLabel.text = model.title
        titleLabel.font = UIKitFeedFont.font(
            for: .narrowCardTitle,
            weight: .medium,
            traitCollection: traits
        )

        let metaText: String = if let areaName = model.areaName, !areaName.isEmpty {
            "\(model.uname)  \(areaName)"
        } else {
            model.uname
        }
        metaLabel.text = metaText
        metaLabel.font = UIKitFeedFont.font(for: .narrowCardMeta, traitCollection: traits)

        var parts = [model.title, metaText]
        if !model.displayOnline.isEmpty { parts.append(model.displayOnline) }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverBox.resetCover()
        coverBox.alpha = 1.0
        statusBadge.isHidden = true
        onlineBadge.isHidden = true
        titleLabel.text = nil
        metaLabel.text = nil
        accessibilityLabel = nil
    }
}

/// Pure UIKit 3:4 portrait poster cell for PGC grids, Bangumi shelves, and UserSpace.
@MainActor
final class UIKitPosterCardCell: UICollectionViewCell {
    struct Model {
        let title: String
        var meta: String?
        let coverURL: String
        var badge: String?
        let cardWidth: CGFloat
        var displayMode: CoverDisplayMode = .fill
        var requestsServerCrop: Bool = true
        var titleRole: AppTextRole = .cardTitle
    }

    private let coverBox = UIKitCoverBoxView()
    private let badgeView = UIKitMediaBadgeView(horizontalPadding: 4, verticalPadding: 2)
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()

    private var coverHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button

        coverBox.translatesAutoresizingMaskIntoConstraints = false
        coverBox.configureStyle(cornerRadius: AppRadius.thumbnail, scrim: .none, showsBorder: false)
        contentView.addSubview(coverBox)

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.isHidden = true
        coverBox.addSubview(badgeView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.addSubview(titleLabel)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.textColor = .secondaryLabel
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.addSubview(metaLabel)

        let coverHeight = coverBox.heightAnchor.constraint(equalToConstant: 140)
        coverHeightConstraint = coverHeight

        NSLayoutConstraint.activate([
            coverBox.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverHeight,
            badgeView.topAnchor.constraint(equalTo: coverBox.topAnchor, constant: 4),
            badgeView.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            metaLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    func configure(_ model: Model) {
        let safeWidth = max(1, model.cardWidth)
        let coverHeight = (safeWidth * 4 / 3).rounded()
        coverHeightConstraint?.constant = max(1, coverHeight)

        let request = UIKitCoverPipeline.request(
            urlString: model.coverURL,
            drawnBox: CGSize(width: safeWidth, height: coverHeight),
            displayMode: model.displayMode,
            requestsServerCrop: model.requestsServerCrop,
            scale: traitCollection.displayScale
        )
        coverBox.setCover(request: request)

        let traits = traitCollection
        badgeView.configurePill(
            text: model.badge,
            backgroundColor: UIColor(AccentStore.shared.badgeFill),
            traitCollection: traits
        )

        titleLabel.text = model.title
        titleLabel.font = UIKitFeedFont.font(
            for: model.titleRole,
            weight: model.titleRole == .cardTitle ? .medium : nil,
            traitCollection: traits
        )

        let hasMeta = model.meta.map { !$0.isEmpty } ?? false
        metaLabel.isHidden = !hasMeta
        metaLabel.text = model.meta
        metaLabel.font = UIKitFeedFont.font(for: .cardMeta, traitCollection: traits)

        var parts = [model.title]
        if let meta = model.meta, !meta.isEmpty { parts.append(meta) }
        if let badge = model.badge, !badge.isEmpty { parts.append(badge) }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverBox.resetCover()
        badgeView.isHidden = true
        titleLabel.text = nil
        metaLabel.text = nil
        accessibilityLabel = nil
    }
}
