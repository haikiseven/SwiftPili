import UIKit

@MainActor
final class UIKitGridVideoCell: UICollectionViewCell {
    struct Model {
        let title: String
        let sources: VideoCoverSources
        var duration: Int = 0
        var durationText: String?
        let ownerName: String
        let viewCount: Int
        var publishedAt: Int?
        let columnWidth: CGFloat
        let coverPresentation: CoverPresentation
    }

    private let coverBox = UIKitCoverBoxView()
    private let overlayBar = UIStackView()
    private let playIcon = UIImageView(image: UIImage(systemName: "play.fill"))
    private let viewsLabel = UILabel()
    private let overlaySpacer = UIView()
    private let durationLabel = UILabel()
    private let textStack = UIStackView()
    private let titleSlotView = UIView()
    private let titleLabel = UILabel()
    private let ownerLabel = UILabel()

    private var coverHeightConstraint: NSLayoutConstraint?
    private var titleSlotMinHeightConstraint: NSLayoutConstraint?

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

        setupCoverAndOverlay()
        setupTextAndLayout()
    }

    private func setupCoverAndOverlay() {
        coverBox.translatesAutoresizingMaskIntoConstraints = false
        coverBox.configureStyle(
            cornerRadius: VideoCardMetrics.cornerRadius,
            scrim: .cardBottom,
            showsBorder: true
        )
        contentView.addSubview(coverBox)

        overlayBar.translatesAutoresizingMaskIntoConstraints = false
        overlayBar.axis = .horizontal
        overlayBar.alignment = .center
        overlayBar.spacing = 4
        overlayBar.isUserInteractionEnabled = false
        coverBox.addSubview(overlayBar)

        let overlayColor = UIColor.white.withAlphaComponent(0.95)
        playIcon.tintColor = overlayColor
        playIcon.contentMode = .scaleAspectFit
        playIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        playIcon.setContentHuggingPriority(.required, for: .horizontal)

        viewsLabel.textColor = overlayColor
        viewsLabel.numberOfLines = 1
        viewsLabel.adjustsFontForContentSizeCategory = true
        viewsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        viewsLabel.setContentHuggingPriority(.required, for: .horizontal)

        overlaySpacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        overlaySpacer.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)

        durationLabel.textColor = overlayColor
        durationLabel.numberOfLines = 1
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        overlayBar.addArrangedSubview(playIcon)
        overlayBar.addArrangedSubview(viewsLabel)
        overlayBar.addArrangedSubview(overlaySpacer)
        overlayBar.addArrangedSubview(durationLabel)
    }

    private func setupTextAndLayout() {
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 4
        contentView.addSubview(textStack)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.setContentHuggingPriority(.required, for: .vertical)

        titleSlotView.addSubview(titleLabel)
        let minSlotHeight = titleSlotView.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        titleSlotMinHeightConstraint = minSlotHeight

        ownerLabel.numberOfLines = 1
        ownerLabel.lineBreakMode = .byTruncatingTail
        ownerLabel.textColor = .secondaryLabel
        ownerLabel.adjustsFontForContentSizeCategory = true
        ownerLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        textStack.addArrangedSubview(titleSlotView)
        textStack.addArrangedSubview(ownerLabel)

        let coverHeight = coverBox.heightAnchor.constraint(equalToConstant: 112)
        coverHeightConstraint = coverHeight

        NSLayoutConstraint.activate([
            coverBox.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            coverHeight,
            overlayBar.leadingAnchor.constraint(equalTo: coverBox.leadingAnchor, constant: 8),
            overlayBar.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: -8),
            overlayBar.bottomAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: titleSlotView.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleSlotView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: titleSlotView.trailingAnchor),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: titleSlotView.bottomAnchor),
            minSlotHeight,
            textStack.topAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: 6),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    func configure(_ model: Model) {
        let coverSize = model.coverPresentation.size(width: max(1, model.columnWidth))
        coverHeightConstraint?.constant = max(1, coverSize.height)

        let request = UIKitCoverPipeline.request(
            sources: model.sources,
            drawnBox: coverSize,
            presentation: model.coverPresentation,
            scale: traitCollection.displayScale
        )
        coverBox.setCover(request: request)

        let traits = traitCollection
        let badgeFont = UIKitFeedFont.font(
            for: .overlayBadge,
            weight: .medium,
            monospacedDigit: true,
            traitCollection: traits
        )
        let iconFont = UIKitFeedFont.systemFont(textStyle: .caption2, traitCollection: traits)
        playIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: iconFont)

        viewsLabel.text = FormatUtils.viewCount(model.viewCount)
        viewsLabel.font = badgeFont

        let resolvedDuration: String? = if let text = model.durationText, !text.isEmpty {
            text
        } else if model.duration > 0 {
            FormatUtils.duration(model.duration)
        } else {
            nil
        }
        durationLabel.isHidden = resolvedDuration == nil
        if let resolvedDuration {
            durationLabel.text = resolvedDuration
            durationLabel.font = badgeFont
        }

        let titleFont = UIKitFeedFont.font(for: .cardTitle, weight: .medium, traitCollection: traits)
        titleLabel.text = model.title
        titleLabel.font = titleFont
        titleSlotMinHeightConstraint?.constant = ceil(titleFont.lineHeight * 2)

        ownerLabel.font = UIKitFeedFont.font(for: .cardMeta, traitCollection: traits)
        let subtitle: String? = if !model.ownerName.isEmpty {
            model.ownerName
        } else if let publishedAt = model.publishedAt, publishedAt > 0 {
            FormatUtils.timeAgo(from: publishedAt)
        } else {
            nil
        }
        ownerLabel.isHidden = subtitle == nil
        ownerLabel.text = subtitle

        var parts = [model.title]
        if let subtitle { parts.append(subtitle) }
        parts.append(FormatUtils.viewCount(model.viewCount))
        if let resolvedDuration { parts.append(resolvedDuration) }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverBox.resetCover()
        titleLabel.text = nil
        ownerLabel.text = nil
        viewsLabel.text = nil
        durationLabel.text = nil
        accessibilityLabel = nil
    }
}
