import SwiftUI
import UIKit

@MainActor
final class SearchBangumiCell: UICollectionViewCell {
    struct Model {
        let title: String
        let coverURL: String
        let seasonTypeName: String?
        let score: Double?
        let userCount: Int?
        let areas: String?
        let styles: String?
        let indexShow: String?
        let desc: String
    }

    private let cardView = UIView()
    private let coverBox = UIKitCoverBoxView()
    private let badgeView = UIKitMediaBadgeView(horizontalPadding: 5, verticalPadding: 2)
    private let textStack = UIStackView()
    private let titleLabel = UILabel()
    private let scoreRow = UIStackView()
    private let starIcon = UIImageView(image: UIImage(systemName: "star.fill"))
    private let scoreLabel = UILabel()
    private let userCountLabel = UILabel()
    private let metaLabel = UILabel()
    private let descLabel = UILabel()

    private static let posterWidth: CGFloat = 84
    private static let posterHeight: CGFloat = 112

    private var sideBySideConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: Self, _) in
            cell.updateLayoutForContentSize()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = AppRadius.card
        cardView.layer.cornerCurve = .continuous
        contentView.addSubview(cardView)

        coverBox.translatesAutoresizingMaskIntoConstraints = false
        coverBox.configureStyle(cornerRadius: AppRadius.thumbnail, scrim: .none, showsBorder: false)
        cardView.addSubview(coverBox)

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.isHidden = true
        coverBox.addSubview(badgeView)

        setupTextStack()
        activateConstraints()
    }

    private func setupTextStack() {
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = AppSpacing.xs
        cardView.addSubview(textStack)

        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        scoreRow.axis = .horizontal
        scoreRow.alignment = .center
        scoreRow.spacing = 6

        let scoreGroup = UIStackView()
        scoreGroup.axis = .horizontal
        scoreGroup.alignment = .center
        scoreGroup.spacing = 3

        starIcon.tintColor = .systemOrange
        starIcon.contentMode = .scaleAspectFit
        starIcon.setContentHuggingPriority(.required, for: .horizontal)
        starIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        scoreLabel.textColor = .systemOrange
        scoreLabel.numberOfLines = 1
        scoreLabel.adjustsFontForContentSizeCategory = true
        scoreLabel.setContentHuggingPriority(.required, for: .horizontal)
        scoreLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        scoreGroup.addArrangedSubview(starIcon)
        scoreGroup.addArrangedSubview(scoreLabel)

        userCountLabel.textColor = .secondaryLabel
        userCountLabel.numberOfLines = 1
        userCountLabel.lineBreakMode = .byTruncatingTail
        userCountLabel.adjustsFontForContentSizeCategory = true

        scoreRow.addArrangedSubview(scoreGroup)
        scoreRow.addArrangedSubview(userCountLabel)
        scoreRow.addArrangedSubview(UIView())

        metaLabel.numberOfLines = 2
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.textColor = .secondaryLabel
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        descLabel.numberOfLines = 2
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.textColor = .tertiaryLabel
        descLabel.adjustsFontForContentSizeCategory = true

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(scoreRow)
        textStack.addArrangedSubview(metaLabel)
        textStack.addArrangedSubview(descLabel)
    }

    private func activateConstraints() {
        let pad = AppSpacing.m
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            coverBox.topAnchor.constraint(equalTo: cardView.topAnchor, constant: pad),
            coverBox.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: pad),
            coverBox.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -pad),
            coverBox.widthAnchor.constraint(equalToConstant: Self.posterWidth),
            coverBox.heightAnchor.constraint(equalToConstant: Self.posterHeight),

            badgeView.topAnchor.constraint(equalTo: coverBox.topAnchor, constant: 4),
            badgeView.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: -4),

            textStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -pad),
        ])
        sideBySideConstraints = [
            textStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: pad),
            textStack.leadingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: pad),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -pad),
        ]
        stackedConstraints = [
            textStack.topAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: pad),
            textStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: pad),
            textStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -pad),
        ]
        updateLayoutForContentSize()
    }

    private func updateLayoutForContentSize() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        if stacked {
            NSLayoutConstraint.deactivate(sideBySideConstraints)
            NSLayoutConstraint.activate(stackedConstraints)
        } else {
            NSLayoutConstraint.deactivate(stackedConstraints)
            NSLayoutConstraint.activate(sideBySideConstraints)
        }
    }

    func configure(_ model: Model) {
        let traits = traitCollection
        let request = Self.coverRequest(coverURL: model.coverURL, scale: traits.displayScale)
        coverBox.setCover(request: request)

        badgeView.configurePill(
            text: model.seasonTypeName,
            backgroundColor: UIColor(AccentStore.shared.badgeFill),
            traitCollection: traits
        )

        titleLabel.text = model.title
        titleLabel.font = UIKitFeedFont.font(for: .rowTitle, weight: .semibold, traitCollection: traits)

        configureScore(score: model.score, userCount: model.userCount, traits: traits)

        let metaParts = [model.areas, model.styles, model.indexShow]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let metaText = metaParts.joined(separator: "  ")
        metaLabel.isHidden = metaText.isEmpty
        metaLabel.text = metaText
        metaLabel.font = UIKitFeedFont.font(for: .rowMeta, traitCollection: traits)

        let descText = model.desc.trimmingCharacters(in: .whitespacesAndNewlines)
        descLabel.isHidden = descText.isEmpty
        descLabel.text = descText
        descLabel.font = UIKitFeedFont.font(for: .libraryRowMeta, traitCollection: traits)

        var a11y = [model.title]
        if let typeName = model.seasonTypeName, !typeName.isEmpty { a11y.append(typeName) }
        if let score = model.score, score > 0 { a11y.append(String(format: "%.1f", score)) }
        if !metaText.isEmpty { a11y.append(metaText) }
        accessibilityLabel = a11y.joined(separator: ", ")
    }

    private func configureScore(score: Double?, userCount: Int?, traits: UITraitCollection) {
        guard let score, score > 0 else {
            scoreRow.isHidden = true
            return
        }
        scoreRow.isHidden = false
        let scoreFont = UIKitFeedFont.font(
            for: .rowMeta, weight: .semibold, monospacedDigit: true, traitCollection: traits
        )
        starIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: scoreFont, scale: .small)
        scoreLabel.text = String(format: "%.1f", score)
        scoreLabel.font = scoreFont

        if let userCount, userCount > 0 {
            userCountLabel.isHidden = false
            userCountLabel.text = String(
                format: String(localized: "%@ ratings"),
                FormatUtils.viewCount(userCount)
            )
            userCountLabel.font = UIKitFeedFont.font(for: .libraryRowMeta, traitCollection: traits)
        } else {
            userCountLabel.isHidden = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverBox.resetCover()
        badgeView.isHidden = true
        scoreRow.isHidden = true
        metaLabel.isHidden = true
        descLabel.isHidden = true
        titleLabel.text = nil
        metaLabel.text = nil
        descLabel.text = nil
        accessibilityLabel = nil
    }

    static func coverRequest(coverURL: String, scale: CGFloat) -> UIKitCoverPipeline.CoverRequest {
        UIKitCoverPipeline.request(
            urlString: coverURL,
            drawnBox: CGSize(width: posterWidth, height: posterHeight),
            displayMode: .fill,
            requestsServerCrop: true,
            scale: scale
        )
    }
}

@MainActor
final class SearchArticleCell: UICollectionViewCell {
    struct Model {
        let title: String
        let coverURL: String?
        let author: String
        let categoryName: String?
        let viewCount: Int
        let likeCount: Int
        let desc: String
    }

    private let cardView = UIView()
    private let rowStack = UIStackView()
    private let coverBox = UIKitCoverBoxView()
    private let textStack = UIStackView()
    private let titleLabel = UILabel()
    private let descLabel = UILabel()
    private let metaStack = UIStackView()
    private let categoryBadge = UIKitMediaBadgeView(horizontalPadding: 6, verticalPadding: 2)
    private let authorLabel = UILabel()
    private let viewsGroup = UIStackView()
    private let viewIcon = UIImageView(image: UIImage(systemName: "eye"))
    private let viewCountLabel = UILabel()
    private let likesGroup = UIStackView()
    private let likeIcon = UIImageView(image: UIImage(systemName: "hand.thumbsup"))
    private let likeCountLabel = UILabel()

    private static let thumbWidth: CGFloat = 108
    private static let thumbHeight: CGFloat = 68

    private var textFillsStackConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: Self, _) in
            cell.updateLayoutForContentSize()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = AppRadius.card
        cardView.layer.cornerCurve = .continuous
        contentView.addSubview(cardView)

        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.axis = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = AppSpacing.m
        cardView.addSubview(rowStack)

        coverBox.translatesAutoresizingMaskIntoConstraints = false
        coverBox.configureStyle(cornerRadius: AppRadius.thumbnail, scrim: .none, showsBorder: false)

        setupTextStack()

        let pad = AppSpacing.m
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            rowStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: pad),
            rowStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: pad),
            rowStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -pad),
            rowStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -pad),

            coverBox.widthAnchor.constraint(equalToConstant: Self.thumbWidth),
            coverBox.heightAnchor.constraint(equalToConstant: Self.thumbHeight),
        ])
        textFillsStackConstraint = textStack.widthAnchor.constraint(equalTo: rowStack.widthAnchor)
        updateLayoutForContentSize()
    }

    private func updateLayoutForContentSize() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        rowStack.axis = stacked ? .vertical : .horizontal
        rowStack.alignment = stacked ? .leading : .top
        textFillsStackConstraint?.isActive = stacked
    }

    private func setupTextStack() {
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 5

        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        descLabel.numberOfLines = 1
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.textColor = .secondaryLabel
        descLabel.adjustsFontForContentSizeCategory = true

        metaStack.axis = .horizontal
        metaStack.alignment = .center
        metaStack.spacing = AppSpacing.s

        categoryBadge.setContentHuggingPriority(.required, for: .horizontal)
        categoryBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        authorLabel.numberOfLines = 1
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.textColor = .secondaryLabel
        authorLabel.adjustsFontForContentSizeCategory = true
        authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureStatGroup(viewsGroup, icon: viewIcon, label: viewCountLabel)
        configureStatGroup(likesGroup, icon: likeIcon, label: likeCountLabel)

        metaStack.addArrangedSubview(categoryBadge)
        metaStack.addArrangedSubview(authorLabel)
        metaStack.addArrangedSubview(viewsGroup)
        metaStack.addArrangedSubview(likesGroup)
        metaStack.addArrangedSubview(UIView())

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(descLabel)
        textStack.addArrangedSubview(metaStack)

        rowStack.addArrangedSubview(coverBox)
        rowStack.addArrangedSubview(textStack)
    }

    private func configureStatGroup(_ group: UIStackView, icon: UIImageView, label: UILabel) {
        group.axis = .horizontal
        group.alignment = .center
        group.spacing = 3
        group.setContentHuggingPriority(.required, for: .horizontal)
        group.setContentCompressionResistancePriority(.required, for: .horizontal)

        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.numberOfLines = 1
        label.textColor = .tertiaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        group.addArrangedSubview(icon)
        group.addArrangedSubview(label)
    }

    func configure(_ model: Model) {
        let traits = traitCollection
        if let coverURL = model.coverURL, !coverURL.isEmpty {
            coverBox.isHidden = false
            coverBox.setCover(request: Self.coverRequest(coverURL: coverURL, scale: traits.displayScale))
        } else {
            coverBox.isHidden = true
            coverBox.resetCover()
        }

        titleLabel.text = model.title
        titleLabel.font = UIKitFeedFont.font(for: .rowTitle, weight: .medium, traitCollection: traits)

        let descText = model.desc.trimmingCharacters(in: .whitespacesAndNewlines)
        descLabel.isHidden = descText.isEmpty
        descLabel.text = descText
        descLabel.font = UIKitFeedFont.font(for: .libraryRowMeta, traitCollection: traits)

        categoryBadge.configurePill(
            text: model.categoryName,
            backgroundColor: .tertiarySystemFill,
            textColor: .secondaryLabel,
            traitCollection: traits
        )

        authorLabel.isHidden = model.author.isEmpty
        authorLabel.text = model.author
        let metaFont = UIKitFeedFont.font(for: .libraryRowMeta, traitCollection: traits)
        authorLabel.font = metaFont

        let iconConfig = UIImage.SymbolConfiguration(font: metaFont, scale: .small)
        viewIcon.preferredSymbolConfiguration = iconConfig
        likeIcon.preferredSymbolConfiguration = iconConfig
        viewCountLabel.text = FormatUtils.viewCount(model.viewCount)
        viewCountLabel.font = metaFont

        likesGroup.isHidden = model.likeCount <= 0
        likeCountLabel.text = FormatUtils.viewCount(model.likeCount)
        likeCountLabel.font = metaFont

        var a11y = [model.title]
        if !model.author.isEmpty { a11y.append(model.author) }
        if let cat = model.categoryName, !cat.isEmpty { a11y.append(cat) }
        a11y.append(FormatUtils.viewCount(model.viewCount))
        accessibilityLabel = a11y.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverBox.resetCover()
        coverBox.isHidden = true
        categoryBadge.isHidden = true
        descLabel.isHidden = true
        likesGroup.isHidden = true
        titleLabel.text = nil
        authorLabel.text = nil
        accessibilityLabel = nil
    }

    static func coverRequest(coverURL: String, scale: CGFloat) -> UIKitCoverPipeline.CoverRequest {
        UIKitCoverPipeline.request(
            urlString: coverURL,
            drawnBox: CGSize(width: thumbWidth, height: thumbHeight),
            displayMode: .fill,
            requestsServerCrop: true,
            scale: scale
        )
    }
}
