import UIKit

@MainActor
final class FavoriteShelfPreviewCell: UICollectionViewCell {
    private let coverBox = UIKitCoverBoxView()
    private let durationBadge = UIKitDurationBadge(horizontalPadding: 5, verticalPadding: 2)
    private let titleSlotView = UIView()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private var coverHeightConstraint: NSLayoutConstraint?
    private var titleSlotHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isAccessibilityElement = true
        accessibilityTraits = .button

        coverBox.translatesAutoresizingMaskIntoConstraints = false
        coverBox.configureStyle(cornerRadius: AppRadius.thumbnail, scrim: .cardBottom, showsBorder: true)
        contentView.addSubview(coverBox)

        durationBadge.translatesAutoresizingMaskIntoConstraints = false
        coverBox.addSubview(durationBadge)

        titleSlotView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleSlotView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleSlotView.addSubview(titleLabel)

        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.numberOfLines = 1
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.textColor = .secondaryLabel
        authorLabel.adjustsFontForContentSizeCategory = true
        contentView.addSubview(authorLabel)

        let coverH = coverBox.heightAnchor.constraint(equalToConstant: 80)
        let titleH = titleSlotView.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        coverHeightConstraint = coverH
        titleSlotHeightConstraint = titleH

        NSLayoutConstraint.activate([
            coverBox.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverH,
            durationBadge.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: -4),
            durationBadge.bottomAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: -4),
            titleSlotView.topAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: 5),
            titleSlotView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleSlotView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleH,
            titleLabel.topAnchor.constraint(equalTo: titleSlotView.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleSlotView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: titleSlotView.trailingAnchor),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: titleSlotView.bottomAnchor),
            authorLabel.topAnchor.constraint(equalTo: titleSlotView.bottomAnchor, constant: 4),
            authorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            authorLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    func configure(
        item: FavoriteContentResult.FavoriteMedia,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        coverPresentation: CoverPresentation
    ) {
        let traits = traitCollection
        coverHeightConstraint?.constant = max(1, cardHeight)
        let request = UIKitCoverPipeline.request(
            sources: VideoCoverSources(widescreen: item.cover ?? ""),
            drawnBox: CGSize(width: cardWidth, height: cardHeight),
            presentation: coverPresentation,
            scale: traits.displayScale
        )
        coverBox.setCover(request: request)
        let badgeFont = UIKitFeedFont.font(
            for: .overlayBadge,
            weight: .medium,
            monospacedDigit: true,
            traitCollection: traits
        )
        durationBadge.configure(duration: item.duration ?? 0, font: badgeFont)

        let titleFont = UIKitFeedFont.font(for: .shelfCardTitle, weight: .medium, traitCollection: traits)
        titleLabel.text = item.title
        titleLabel.font = titleFont
        titleSlotHeightConstraint?.constant = ceil(titleFont.lineHeight * 2)

        let upper = item.upper?.name ?? ""
        authorLabel.isHidden = upper.isEmpty
        authorLabel.text = upper
        authorLabel.font = UIKitFeedFont.font(for: .cardMeta, traitCollection: traits)

        contentView.alpha = item.isPlayableVideo ? 1.0 : 0.6
        accessibilityLabel = upper.isEmpty ? item.title : "\(item.title), \(upper)"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverBox.resetCover()
        titleLabel.text = nil
        authorLabel.text = nil
        accessibilityLabel = nil
    }
}

@MainActor
final class FavoriteShelfSkeletonCardCell: UICollectionViewCell {
    private let coverShape = UIView()
    private let titleShapeOne = UIView()
    private let titleShapeTwo = UIView()
    private let metaShape = UIView()
    private var coverHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        coverShape.translatesAutoresizingMaskIntoConstraints = false
        coverShape.backgroundColor = .secondarySystemFill
        coverShape.layer.cornerRadius = AppRadius.thumbnail
        coverShape.layer.cornerCurve = .continuous
        contentView.addSubview(coverShape)

        for shape in [titleShapeOne, titleShapeTwo, metaShape] {
            shape.translatesAutoresizingMaskIntoConstraints = false
            shape.backgroundColor = .secondarySystemFill
            shape.layer.cornerRadius = AppRadius.badge
            shape.layer.cornerCurve = .continuous
            contentView.addSubview(shape)
        }
        metaShape.alpha = 0.65

        let coverH = coverShape.heightAnchor.constraint(equalToConstant: 80)
        coverHeightConstraint = coverH
        NSLayoutConstraint.activate([
            coverShape.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverShape.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverH,
            titleShapeOne.topAnchor.constraint(equalTo: coverShape.bottomAnchor, constant: 7),
            titleShapeOne.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleShapeOne.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.88),
            titleShapeOne.heightAnchor.constraint(equalToConstant: 11),
            titleShapeTwo.topAnchor.constraint(equalTo: titleShapeOne.bottomAnchor, constant: 4),
            titleShapeTwo.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleShapeTwo.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.56),
            titleShapeTwo.heightAnchor.constraint(equalToConstant: 11),
            metaShape.topAnchor.constraint(equalTo: titleShapeTwo.bottomAnchor, constant: 8),
            metaShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            metaShape.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.42),
            metaShape.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    func configure(cardWidth: CGFloat, cardHeight: CGFloat) {
        coverHeightConstraint?.constant = max(1, cardHeight)
    }
}

@MainActor
final class FavoriteShelfSeeMoreCell: UICollectionViewCell {
    private let box = UIView()
    private let icon = UIImageView(image: UIImage(systemName: "arrow.right.circle.fill"))
    private let label = UILabel()
    private var boxHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "See More")

        box.translatesAutoresizingMaskIntoConstraints = false
        box.backgroundColor = .tertiarySystemFill
        box.layer.cornerRadius = AppRadius.thumbnail
        box.layer.cornerCurve = .continuous
        contentView.addSubview(box)

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        box.addSubview(stack)

        icon.tintColor = .secondaryLabel
        label.text = String(localized: "See More")
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true

        let boxH = box.heightAnchor.constraint(equalToConstant: 80)
        boxHeightConstraint = boxH

        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: contentView.topAnchor),
            box.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            boxH,
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
    }

    func configure(size: CGSize) {
        boxHeightConstraint?.constant = max(1, size.height)
        let traits = traitCollection
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: UIKitFeedFont.systemFont(textStyle: .title3, traitCollection: traits)
        )
        label.font = UIKitFeedFont.systemFont(textStyle: .caption2, traitCollection: traits)
    }
}
