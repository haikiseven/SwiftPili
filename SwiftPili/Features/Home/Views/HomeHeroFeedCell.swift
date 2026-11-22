import SwiftUI
import UIKit

/// Lead Hero cell for Home Recommend, Popular, and Ranking feeds.
/// Renders as an overlaid 16:9 card below 3 grid columns and as an Apple TV-style
/// wide featured shelf at 3+ grid columns.
@MainActor
final class HomeHeroFeedCell: UICollectionViewCell {
    private let coverBox = UIKitCoverBoxView()
    private let textStack = UIStackView()
    private let eyebrowRow = UIStackView()
    private let crownIcon = UIImageView(image: UIImage(systemName: "crown.fill"))
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let narrowMetaRow = UIStackView()
    private let metaLineView = UIKitMetaLineView()
    private let narrowDurationLabel = UILabel()
    private let wideDurationBadge = UIKitDurationBadge(
        isCapsule: true,
        horizontalPadding: 7,
        verticalPadding: 3
    )
    private let playCueView = HomeHeroPlayCueView()
    private let wideFadeMask = CAGradientLayer()

    private var narrowConstraints: [NSLayoutConstraint] = []
    private var wideConstraints: [NSLayoutConstraint] = []
    private var narrowCoverHeightConstraint: NSLayoutConstraint?
    private var wideCoverWidthConstraint: NSLayoutConstraint?
    private var wideCoverHeightConstraint: NSLayoutConstraint?
    private var wideTextWidthConstraint: NSLayoutConstraint?
    private var isWideMode: Bool?

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
        contentView.addSubview(coverBox)

        wideDurationBadge.translatesAutoresizingMaskIntoConstraints = false
        coverBox.addSubview(wideDurationBadge)
        NSLayoutConstraint.activate([
            wideDurationBadge.topAnchor.constraint(equalTo: coverBox.topAnchor, constant: 10),
            wideDurationBadge.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: -10),
        ])

        wideFadeMask.startPoint = CGPoint(x: 0.0, y: 0.5)
        wideFadeMask.endPoint = CGPoint(x: 1.0, y: 0.5)
        wideFadeMask.locations = [0.0, 0.35, 1.0]
        wideFadeMask.colors = [
            UIColor.clear.cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor,
        ]

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .leading
        contentView.addSubview(textStack)

        eyebrowRow.axis = .horizontal
        eyebrowRow.alignment = .center
        eyebrowRow.spacing = 4
        crownIcon.contentMode = .scaleAspectFit
        crownIcon.isHidden = true
        eyebrowLabel.numberOfLines = 1
        eyebrowLabel.adjustsFontForContentSizeCategory = true
        eyebrowRow.addArrangedSubview(crownIcon)
        eyebrowRow.addArrangedSubview(eyebrowLabel)

        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail

        narrowMetaRow.axis = .horizontal
        narrowMetaRow.alignment = .center
        narrowMetaRow.spacing = 8
        narrowMetaRow.addArrangedSubview(metaLineView)

        narrowDurationLabel.numberOfLines = 1
        narrowDurationLabel.adjustsFontForContentSizeCategory = true
        narrowDurationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        narrowDurationLabel.setContentHuggingPriority(.required, for: .horizontal)
        narrowMetaRow.addArrangedSubview(narrowDurationLabel)

        textStack.addArrangedSubview(eyebrowRow)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(narrowMetaRow)
        textStack.addArrangedSubview(playCueView)

        buildConstraints()
    }

    private func buildConstraints() {
        let narrowHeight = coverBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        narrowCoverHeightConstraint = narrowHeight

        narrowConstraints = [
            coverBox.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverBox.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            narrowHeight,
            textStack.leadingAnchor.constraint(equalTo: coverBox.leadingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: -14),
            textStack.bottomAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: -12),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: coverBox.topAnchor, constant: 12),
            narrowMetaRow.widthAnchor.constraint(equalTo: textStack.widthAnchor),
        ]

        let wideCoverWidth = coverBox.widthAnchor.constraint(equalToConstant: 360)
        let wideCoverHeight = coverBox.heightAnchor.constraint(equalToConstant: 202)
        let wideTextWidth = textStack.widthAnchor.constraint(equalToConstant: 240)
        wideCoverWidthConstraint = wideCoverWidth
        wideCoverHeightConstraint = wideCoverHeight
        wideTextWidthConstraint = wideTextWidth

        wideConstraints = [
            coverBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverBox.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            coverBox.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor),
            coverBox.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            wideCoverWidth,
            wideCoverHeight,
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            wideTextWidth,
        ]
    }

    func configure(
        item: HomeFeedItemData,
        badgeText: String,
        isWide: Bool,
        containerWidth: CGFloat,
        coverPresentation: CoverPresentation
    ) {
        applyModeIfNeeded(isWide: isWide)

        let heroPresentation = CoverPresentation(
            aspect: .sixteenByNine,
            display: coverPresentation.display
        )
        let coverBoxSize: CGSize
        if isWide {
            let coverWidth = max(1, (containerWidth * HomeHeroLayoutMetrics.heroWideCoverFraction).rounded(.down))
            let coverHeight = max(1, (coverWidth * 9 / 16).rounded(.down))
            let textWidth = max(1, (containerWidth * HomeHeroLayoutMetrics.heroWideTextFraction).rounded(.down))
            wideCoverWidthConstraint?.constant = coverWidth
            wideCoverHeightConstraint?.constant = coverHeight
            wideTextWidthConstraint?.constant = textWidth
            coverBoxSize = CGSize(width: coverWidth, height: coverHeight)
        } else {
            let width = max(1, containerWidth.rounded())
            let height = max(1, heroPresentation.height(forWidth: width))
            narrowCoverHeightConstraint?.constant = height
            coverBoxSize = CGSize(width: width, height: height)
        }

        let request = UIKitCoverPipeline.request(
            sources: item.sources,
            drawnBox: coverBoxSize,
            presentation: heroPresentation,
            scale: traitCollection.displayScale
        )
        coverBox.setCover(request: request)

        configureText(item: item, badgeText: badgeText, isWide: isWide)
        updateAccessibility(item: item, badgeText: badgeText)
        setNeedsLayout()
    }

    private func applyModeIfNeeded(isWide: Bool) {
        guard isWideMode != isWide else { return }
        isWideMode = isWide

        if isWide {
            NSLayoutConstraint.deactivate(narrowConstraints)
            NSLayoutConstraint.activate(wideConstraints)
            coverBox.configureStyle(cornerRadius: AppRadius.panel, scrim: .none, showsBorder: false)
            coverBox.layer.mask = wideFadeMask
            textStack.spacing = 10
            titleLabel.numberOfLines = 3
            narrowDurationLabel.isHidden = true
            playCueView.isHidden = false
            wideDurationBadge.isHidden = false
        } else {
            NSLayoutConstraint.deactivate(wideConstraints)
            NSLayoutConstraint.activate(narrowConstraints)
            coverBox.configureStyle(cornerRadius: AppRadius.panel, scrim: .heroOverlay, showsBorder: true)
            coverBox.layer.mask = nil
            textStack.spacing = 5
            titleLabel.numberOfLines = 2
            playCueView.isHidden = true
            wideDurationBadge.isHidden = true
        }
    }

    private func configureText(item: HomeFeedItemData, badgeText: String, isWide: Bool) {
        let traits = traitCollection
        configureEyebrow(rank: item.rank, badgeText: badgeText, isWide: isWide, traits: traits)

        titleLabel.text = item.title
        if isWide {
            titleLabel.font = UIKitFeedFont.font(
                for: .editorialTitle,
                weight: .bold,
                traitCollection: traits
            )
            titleLabel.textColor = .label
        } else {
            titleLabel.font = UIKitFeedFont.systemFont(
                textStyle: .headline,
                weight: .bold,
                traitCollection: traits
            )
            titleLabel.textColor = .white
        }

        let metaFont = UIKitFeedFont.font(for: .cardMeta, traitCollection: traits)
        let metaColor: UIColor = isWide ? .secondaryLabel : UIColor.white.withAlphaComponent(0.86)
        metaLineView.configure(
            ownerName: item.ownerName,
            viewCount: item.viewCount,
            font: metaFont,
            color: metaColor
        )

        configureDuration(duration: item.duration, isWide: isWide, traits: traits)
        if isWide {
            playCueView.configure(traitCollection: traits)
        }
    }

    private func configureEyebrow(
        rank: Int?,
        badgeText: String,
        isWide: Bool,
        traits: UITraitCollection
    ) {
        let eyebrowFont = UIKitFeedFont.font(
            for: .overlayBadge,
            weight: .bold,
            monospacedDigit: rank != nil,
            traitCollection: traits
        )
        eyebrowLabel.font = eyebrowFont

        if let rank {
            let gold = UIColor(red: 1.00, green: 0.84, blue: 0.25, alpha: 1.0)
            crownIcon.isHidden = false
            crownIcon.tintColor = gold
            crownIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: eyebrowFont)
            eyebrowLabel.text = "TOP \(rank)"
            eyebrowLabel.textColor = gold
        } else {
            crownIcon.isHidden = true
            eyebrowLabel.text = badgeText
            eyebrowLabel.textColor = isWide
                ? UIColor(AccentStore.shared.semanticAccent)
                : UIColor.white.withAlphaComponent(0.90)
        }
    }

    private func configureDuration(duration: Int, isWide: Bool, traits: UITraitCollection) {
        let badgeFont = UIKitFeedFont.font(
            for: .overlayBadge,
            weight: .semibold,
            monospacedDigit: true,
            traitCollection: traits
        )
        if isWide {
            wideDurationBadge.configure(duration: duration, font: badgeFont)
        } else {
            let hasDuration = duration > 0
            narrowDurationLabel.isHidden = !hasDuration
            if hasDuration {
                narrowDurationLabel.text = FormatUtils.duration(duration)
                narrowDurationLabel.font = badgeFont
                narrowDurationLabel.textColor = UIColor.white.withAlphaComponent(0.92)
            }
        }
    }

    private func updateAccessibility(item: HomeFeedItemData, badgeText: String) {
        let prefix = item.rank.map { "TOP \($0)" } ?? badgeText
        var parts = [prefix, item.title]
        if !item.ownerName.isEmpty { parts.append(item.ownerName) }
        parts.append(FormatUtils.viewCount(item.viewCount))
        if item.duration > 0 { parts.append(FormatUtils.duration(item.duration)) }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isWideMode == true {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wideFadeMask.frame = coverBox.bounds
            CATransaction.commit()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverBox.resetCover()
        crownIcon.isHidden = true
        titleLabel.text = nil
        eyebrowLabel.text = nil
        narrowDurationLabel.text = nil
        accessibilityLabel = nil
    }
}

/// Decorative "Play" capsule shown in the wide featured Hero row.
@MainActor
private final class HomeHeroPlayCueView: UIView {
    private let stack = UIStackView()
    private let iconView = UIImageView(image: UIImage(systemName: "play.fill"))
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        label.textColor = .white
        label.text = String(localized: "Play")
        label.adjustsFontForContentSizeCategory = true

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(label)
    }

    func configure(traitCollection: UITraitCollection) {
        backgroundColor = UIColor(AccentStore.shared.badgeFill)
        let iconFont = UIKitFeedFont.systemFont(
            textStyle: .subheadline,
            weight: .bold,
            traitCollection: traitCollection
        )
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: iconFont)
        label.font = UIKitFeedFont.font(
            for: .controlLabel,
            weight: .semibold,
            traitCollection: traitCollection
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
