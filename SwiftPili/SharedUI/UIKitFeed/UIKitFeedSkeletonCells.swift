import UIKit

/// Reusable section header with optional top hairline separator (e.g. Home's
/// `"Previously loaded recommendations"`) or headline title (e.g. PGC rails).
@MainActor
final class UIKitFeedSectionHeaderView: UICollectionReusableView {
    private let divider = UIView()
    private let label = UILabel()
    private var labelTopToDivider: NSLayoutConstraint?
    private var labelTopToSuperview: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .separator
        addSubview(divider)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        label.adjustsFontForContentSizeCategory = true
        addSubview(label)

        let topToDivider = label.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8)
        let topToSuperview = label.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        labelTopToDivider = topToDivider
        labelTopToSuperview = topToSuperview

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: UIKitFeedLayoutMetrics.hairlineWidth),
            topToDivider,
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    func configure(
        title: String,
        showsDivider: Bool = true,
        textStyle: AppTextStyle = .footnote,
        weight: UIFont.Weight? = nil,
        color: UIColor = .secondaryLabel
    ) {
        divider.isHidden = !showsDivider
        labelTopToDivider?.isActive = showsDivider
        labelTopToSuperview?.isActive = !showsDivider
        label.text = title
        label.textColor = color
        label.font = UIKitFeedFont.systemFont(
            textStyle: textStyle,
            weight: weight,
            traitCollection: traitCollection
        )
    }
}

/// Static geometric Hero skeleton rendered during empty initial load.
@MainActor
final class UIKitHeroSkeletonCell: UICollectionViewCell {
    private let box = UIView()
    private var heightConstraint: NSLayoutConstraint?

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
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        box.translatesAutoresizingMaskIntoConstraints = false
        box.backgroundColor = .secondarySystemFill
        box.layer.cornerRadius = AppRadius.panel
        box.layer.cornerCurve = .continuous
        contentView.addSubview(box)

        let height = box.heightAnchor.constraint(equalToConstant: 180)
        heightConstraint = height

        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: contentView.topAnchor),
            box.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            height,
        ])
    }

    func configure(containerWidth: CGFloat, wideCoverFraction: CGFloat = 0.62, isWide: Bool) {
        let width = isWide
            ? max(1, (containerWidth * wideCoverFraction).rounded(.down))
            : max(1, containerWidth.rounded())
        let height = max(1, (width * 9 / 16).rounded())
        heightConstraint?.constant = height
    }
}

/// Static geometric grid skeleton rendered during empty initial load (Video, Live, or 3:4 Poster).
@MainActor
final class UIKitGridSkeletonCell: UICollectionViewCell {
    private let coverShape = UIView()
    private let titleShape = UIView()
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
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isUserInteractionEnabled = false

        coverShape.translatesAutoresizingMaskIntoConstraints = false
        coverShape.backgroundColor = .secondarySystemFill
        coverShape.layer.cornerRadius = VideoCardMetrics.cornerRadius
        coverShape.layer.cornerCurve = .continuous
        contentView.addSubview(coverShape)

        titleShape.translatesAutoresizingMaskIntoConstraints = false
        titleShape.backgroundColor = .secondarySystemFill
        titleShape.layer.cornerRadius = AppRadius.badge
        titleShape.layer.cornerCurve = .continuous
        contentView.addSubview(titleShape)

        metaShape.translatesAutoresizingMaskIntoConstraints = false
        metaShape.backgroundColor = .secondarySystemFill
        metaShape.alpha = 0.65
        metaShape.layer.cornerRadius = AppRadius.badge
        metaShape.layer.cornerCurve = .continuous
        contentView.addSubview(metaShape)

        let coverHeight = coverShape.heightAnchor.constraint(equalToConstant: 112)
        coverHeightConstraint = coverHeight

        NSLayoutConstraint.activate([
            coverShape.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverShape.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverHeight,
            titleShape.topAnchor.constraint(equalTo: coverShape.bottomAnchor, constant: 8),
            titleShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleShape.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleShape.heightAnchor.constraint(equalToConstant: 14),
            metaShape.topAnchor.constraint(equalTo: titleShape.bottomAnchor, constant: 8),
            metaShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            metaShape.widthAnchor.constraint(equalToConstant: 96),
            metaShape.heightAnchor.constraint(equalToConstant: 12),
            metaShape.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    func configure(
        columnWidth: CGFloat,
        coverPresentation: CoverPresentation,
        cornerRadius: CGFloat = VideoCardMetrics.cornerRadius,
        accessibilityLabel: String?
    ) {
        let size = coverPresentation.size(width: max(1, columnWidth))
        coverShape.layer.cornerRadius = cornerRadius
        coverHeightConstraint?.constant = max(1, size.height)
        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
    }

    func configurePoster(
        columnWidth: CGFloat,
        accessibilityLabel: String?
    ) {
        let width = max(1, columnWidth)
        let height = max(1, (width * 4 / 3).rounded())
        coverShape.layer.cornerRadius = AppRadius.thumbnail
        coverHeightConstraint?.constant = height
        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Static geometric row skeleton rendered during empty initial load (`feed` or `library` row widths).
@MainActor
final class UIKitRowSkeletonCell: UICollectionViewCell {
    private let coverShape = UIView()
    private let titleShapeOne = UIView()
    private let titleShapeTwo = UIView()
    private let metaShape = UIView()
    private var coverWidthConstraint: NSLayoutConstraint?
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
        isUserInteractionEnabled = false

        coverShape.translatesAutoresizingMaskIntoConstraints = false
        coverShape.backgroundColor = .secondarySystemFill
        coverShape.layer.cornerRadius = VideoCardMetrics.cornerRadius
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

        let coverWidth = coverShape.widthAnchor.constraint(equalToConstant: RowCardMetrics.compactCoverWidth)
        let coverHeight = coverShape.heightAnchor.constraint(equalToConstant: 90)
        coverWidthConstraint = coverWidth
        coverHeightConstraint = coverHeight

        NSLayoutConstraint.activate([
            coverShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverShape.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverShape.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            coverWidth,
            coverHeight,
            titleShapeOne.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            titleShapeOne.leadingAnchor.constraint(
                equalTo: coverShape.trailingAnchor,
                constant: RowGeometry.coverToTextSpacing
            ),
            titleShapeOne.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleShapeOne.heightAnchor.constraint(equalToConstant: 15),
            titleShapeTwo.topAnchor.constraint(equalTo: titleShapeOne.bottomAnchor, constant: 8),
            titleShapeTwo.leadingAnchor.constraint(equalTo: titleShapeOne.leadingAnchor),
            titleShapeTwo.widthAnchor.constraint(equalToConstant: 140),
            titleShapeTwo.heightAnchor.constraint(equalToConstant: 15),
            metaShape.leadingAnchor.constraint(equalTo: titleShapeOne.leadingAnchor),
            metaShape.widthAnchor.constraint(equalToConstant: 96),
            metaShape.heightAnchor.constraint(equalToConstant: 12),
            metaShape.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    func configure(
        style: UIKitRowVideoCell.RowStyle = .feed,
        columnWidth: CGFloat,
        coverPresentation: CoverPresentation,
        accessibilityLabel: String?
    ) {
        let isRegularWidth = traitCollection.horizontalSizeClass == .regular
        let coverWidth = style == .feed
            ? RowCardMetrics.coverWidth(columnWidth: columnWidth, isRegularWidth: isRegularWidth)
            : LibraryRowMetrics.coverWidth(columnWidth: columnWidth, isRegularWidth: isRegularWidth)
        let size = coverPresentation.size(width: max(1, coverWidth))
        coverShape.layer.cornerRadius = style == .feed ? VideoCardMetrics.cornerRadius : AppRadius.thumbnail
        coverWidthConstraint?.constant = max(1, size.width)
        coverHeightConstraint?.constant = max(1, size.height)
        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Static geometric user row skeleton rendered during empty initial load.
@MainActor
final class UIKitUserRowSkeletonCell: UICollectionViewCell {
    private let avatarShape = UIView()
    private let titleShape = UIView()
    private let subtitleShape = UIView()
    private var avatarWidthConstraint: NSLayoutConstraint?
    private var avatarHeightConstraint: NSLayoutConstraint?
    private var leadingConstraint: NSLayoutConstraint?

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
        isUserInteractionEnabled = false

        avatarShape.translatesAutoresizingMaskIntoConstraints = false
        avatarShape.backgroundColor = .secondarySystemFill
        avatarShape.layer.cornerRadius = 24
        contentView.addSubview(avatarShape)

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

        let avatarW = avatarShape.widthAnchor.constraint(equalToConstant: 48)
        let avatarH = avatarShape.heightAnchor.constraint(equalToConstant: 48)
        let leading = avatarShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        avatarWidthConstraint = avatarW
        avatarHeightConstraint = avatarH
        leadingConstraint = leading

        NSLayoutConstraint.activate([
            leading,
            avatarShape.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            avatarShape.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            avatarW,
            avatarH,
            titleShape.leadingAnchor.constraint(equalTo: avatarShape.trailingAnchor, constant: 12),
            titleShape.topAnchor.constraint(equalTo: avatarShape.topAnchor, constant: 6),
            titleShape.widthAnchor.constraint(equalToConstant: 160),
            titleShape.heightAnchor.constraint(equalToConstant: 14),
            subtitleShape.leadingAnchor.constraint(equalTo: titleShape.leadingAnchor),
            subtitleShape.topAnchor.constraint(equalTo: titleShape.bottomAnchor, constant: 6),
            subtitleShape.widthAnchor.constraint(equalToConstant: 96),
            subtitleShape.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    func configure(
        avatarSize: CGFloat = 48,
        horizontalPadding: CGFloat = 0,
        accessibilityLabel: String?
    ) {
        avatarWidthConstraint?.constant = avatarSize
        avatarHeightConstraint?.constant = avatarSize
        avatarShape.layer.cornerRadius = avatarSize / 2
        leadingConstraint?.constant = horizontalPadding
        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
    }
}
