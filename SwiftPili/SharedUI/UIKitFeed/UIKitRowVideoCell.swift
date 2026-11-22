import UIKit

@MainActor
final class UIKitRowVideoCell: UICollectionViewCell {
    private let coverBox = UIKitCoverBoxView()
    private let rankBadge = UIKitRankBadgeView()
    private let progressBar = UIKitWatchProgressBar()
    private let durationBadge = UIKitDurationBadge(
        isCapsule: false,
        horizontalPadding: 5,
        verticalPadding: 2
    )
    private let titleLabel = UILabel()
    private let textStack = UIStackView()
    private let metaLineView = UIKitMetaLineView()
    private let subtitleLabel = UILabel()
    private let footerLabel = UILabel()
    private let footerStatsView = UIKitRowFooterStatsView()
    private let menuButton = UIButton(type: .system)

    private var coverWidthConstraint: NSLayoutConstraint?
    private var coverHeightConstraint: NSLayoutConstraint?
    private var rowMinHeightConstraint: NSLayoutConstraint?
    private var titleTrailingConstraint: NSLayoutConstraint?
    private var activeStyle: RowStyle?

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

        setupCover()
        setupTextAndMenu()
        activateConstraints()
    }

    private func setupCover() {
        coverBox.translatesAutoresizingMaskIntoConstraints = false
        coverBox.configureStyle(
            cornerRadius: VideoCardMetrics.cornerRadius,
            scrim: .cardBottom,
            showsBorder: true
        )
        contentView.addSubview(coverBox)

        rankBadge.translatesAutoresizingMaskIntoConstraints = false
        rankBadge.isHidden = true
        coverBox.addSubview(rankBadge)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true
        coverBox.addSubview(progressBar)

        durationBadge.translatesAutoresizingMaskIntoConstraints = false
        coverBox.addSubview(durationBadge)
    }

    private func setupTextAndMenu() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.addSubview(titleLabel)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.tintColor = .secondaryLabel
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.isHidden = true
        var buttonConfig = UIButton.Configuration.plain()
        buttonConfig.image = UIImage(systemName: "ellipsis")
        buttonConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            font: UIKitFeedFont.systemFont(
                textStyle: .footnote,
                weight: .semibold,
                traitCollection: traitCollection
            )
        )
        buttonConfig.contentInsets = .zero
        menuButton.configuration = buttonConfig
        contentView.addSubview(menuButton)

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 4
        textStack.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.addSubview(textStack)

        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true

        footerLabel.numberOfLines = 1
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.textColor = .tertiaryLabel
        footerLabel.adjustsFontForContentSizeCategory = true

        textStack.addArrangedSubview(metaLineView)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.addArrangedSubview(footerLabel)
        textStack.addArrangedSubview(footerStatsView)
    }

    private func activateConstraints() {
        let coverWidth = coverBox.widthAnchor.constraint(equalToConstant: RowCardMetrics.compactCoverWidth)
        let coverHeight = coverBox.heightAnchor.constraint(equalToConstant: 90)
        let rowMinHeight = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90)
        let titleTrailing = titleLabel.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -8
        )
        coverWidthConstraint = coverWidth
        coverHeightConstraint = coverHeight
        rowMinHeightConstraint = rowMinHeight
        titleTrailingConstraint = titleTrailing

        NSLayoutConstraint.activate([
            rowMinHeight,
            coverBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            coverBox.topAnchor.constraint(equalTo: contentView.topAnchor),
            coverWidth,
            coverHeight,
            rankBadge.topAnchor.constraint(equalTo: coverBox.topAnchor, constant: 6),
            rankBadge.leadingAnchor.constraint(equalTo: coverBox.leadingAnchor, constant: 6),
            progressBar.leadingAnchor.constraint(equalTo: coverBox.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: coverBox.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
            durationBadge.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: -6),
            durationBadge.bottomAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(
                equalTo: coverBox.trailingAnchor,
                constant: RowGeometry.coverToTextSpacing
            ),
            titleTrailing,
            menuButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            menuButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 44),
            menuButton.heightAnchor.constraint(equalToConstant: 44),
            textStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor, constant: 4),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    func configure(_ model: Model) {
        applyStyleIfNeeded(model.style)
        let traits = traitCollection
        let isRegular = traits.horizontalSizeClass == .regular
        let coverWidth = model.style == .feed
            ? RowCardMetrics.coverWidth(columnWidth: model.columnWidth, isRegularWidth: isRegular)
            : LibraryRowMetrics.coverWidth(columnWidth: model.columnWidth, isRegularWidth: isRegular)
        let coverSize = model.coverPresentation.size(width: max(1, coverWidth))
        coverWidthConstraint?.constant = max(1, coverSize.width)
        coverHeightConstraint?.constant = max(1, coverSize.height)
        rowMinHeightConstraint?.constant = max(1, coverSize.height)

        let request = UIKitCoverPipeline.request(
            sources: model.sources,
            drawnBox: coverSize,
            presentation: model.coverPresentation,
            scale: traits.displayScale
        )
        coverBox.setCover(request: request)

        configureOverlays(model, traits: traits)
        titleLabel.text = model.title
        titleLabel.font = UIKitFeedFont.font(
            for: model.style == .feed ? .rowTitle : .libraryRowTitle,
            weight: .medium,
            traitCollection: traits
        )
        configureSubtitleAndFooter(model, traits: traits)
        configureTrailingMenu(model)
        updateAccessibility(model)
    }

    private func applyStyleIfNeeded(_ style: RowStyle) {
        guard activeStyle != style else { return }
        activeStyle = style
        let radius = style == .feed ? VideoCardMetrics.cornerRadius : AppRadius.thumbnail
        coverBox.configureStyle(cornerRadius: radius, scrim: .cardBottom, showsBorder: true)
    }

    private func configureOverlays(_ model: Model, traits: UITraitCollection) {
        if let rank = model.rank {
            rankBadge.isHidden = false
            rankBadge.configure(rank: rank, traitCollection: traits)
        } else {
            rankBadge.isHidden = true
        }
        progressBar.configure(progress: model.watchProgress)

        let badgeFont = UIKitFeedFont.font(
            for: .overlayBadge,
            weight: .medium,
            monospacedDigit: true,
            traitCollection: traits
        )
        if let durationText = model.durationText, !durationText.isEmpty {
            durationBadge.configure(text: durationText, font: badgeFont)
        } else {
            durationBadge.configure(duration: model.duration, font: badgeFont)
        }
    }

    private func configureSubtitleAndFooter(_ model: Model, traits: UITraitCollection) {
        let metaFont = UIKitFeedFont.font(
            for: model.style == .feed ? .rowMeta : .libraryRowMeta,
            traitCollection: traits
        )
        switch model.subtitle {
        case .metaLine(let ownerName, let viewCount, let publishedAt):
            metaLineView.isHidden = false
            subtitleLabel.isHidden = true
            metaLineView.configure(
                ownerName: ownerName,
                viewCount: viewCount,
                publishedAt: publishedAt,
                font: metaFont,
                color: .secondaryLabel
            )
        case .text(let text):
            metaLineView.isHidden = true
            let hasText = text.map { !$0.isEmpty } ?? false
            subtitleLabel.isHidden = !hasText
            subtitleLabel.text = text
            subtitleLabel.font = metaFont
        }

        let footerFont = UIKitFeedFont.font(for: .libraryRowFooter, traitCollection: traits)
        switch model.footer {
        case .none:
            footerLabel.isHidden = true
            footerStatsView.isHidden = true
        case .text(let value):
            footerLabel.isHidden = value.isEmpty
            footerStatsView.isHidden = true
            footerLabel.text = value
            footerLabel.font = footerFont
        case .stats(let play, let danmaku):
            footerLabel.isHidden = true
            footerStatsView.configure(play: play, danmaku: danmaku, font: footerFont)
        }
    }

    private func configureTrailingMenu(_ model: Model) {
        if let menu = model.trailingMenu {
            menuButton.isHidden = false
            menuButton.menu = menu
            menuButton.isEnabled = model.isTrailingMenuEnabled
            menuButton.accessibilityLabel = model.trailingMenuAccessibilityLabel ?? String(localized: "More")
            titleTrailingConstraint?.constant = -44
            isAccessibilityElement = false
        } else {
            menuButton.isHidden = true
            menuButton.menu = nil
            titleTrailingConstraint?.constant = -8
            isAccessibilityElement = true
        }
    }

    private func updateAccessibility(_ model: Model) {
        guard model.trailingMenu == nil else {
            accessibilityLabel = nil
            return
        }
        var parts: [String] = []
        if let rank = model.rank { parts.append("#\(rank)") }
        parts.append(model.title)
        switch model.subtitle {
        case .metaLine(let ownerName, let viewCount, _):
            if !ownerName.isEmpty { parts.append(ownerName) }
            parts.append(FormatUtils.viewCount(viewCount))
        case .text(let text):
            if let text, !text.isEmpty { parts.append(text) }
        }
        if let durationText = model.durationText, !durationText.isEmpty {
            parts.append(durationText)
        } else if model.duration > 0 {
            parts.append(FormatUtils.duration(model.duration))
        }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverBox.resetCover()
        rankBadge.isHidden = true
        progressBar.configure(progress: nil)
        menuButton.menu = nil
        menuButton.isHidden = true
        titleLabel.text = nil
        subtitleLabel.text = nil
        footerLabel.text = nil
        accessibilityLabel = nil
        isAccessibilityElement = true
    }
}

extension UIKitRowVideoCell {
    enum RowStyle: Equatable, Sendable {
        case feed
        case library
    }

    enum SubtitleMode: Equatable, Sendable {
        case metaLine(ownerName: String, viewCount: Int, publishedAt: Int? = nil)
        case text(String?)
    }

    enum FooterMode: Equatable, Sendable {
        case none
        case text(String)
        case stats(play: Int?, danmaku: Int?)
    }

    struct Model {
        var style: RowStyle = .feed
        let title: String
        let sources: VideoCoverSources
        var duration: Int = 0
        var durationText: String?
        let subtitle: SubtitleMode
        var footer: FooterMode = .none
        var rank: Int?
        var watchProgress: Double?
        var trailingMenu: UIMenu?
        var trailingMenuAccessibilityLabel: String?
        var isTrailingMenuEnabled: Bool = true
        let columnWidth: CGFloat
        let coverPresentation: CoverPresentation
    }
}

@MainActor
private final class UIKitRowFooterStatsView: UIView {
    private let stack = UIStackView()
    private let playGroup = UIStackView()
    private let playIcon = UIImageView(image: UIImage(systemName: "play.rectangle"))
    private let playLabel = UILabel()
    private let danmakuGroup = UIStackView()
    private let danmakuIcon = UIImageView(image: UIImage(systemName: "text.bubble"))
    private let danmakuLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for (group, icon, label) in [
            (playGroup, playIcon, playLabel),
            (danmakuGroup, danmakuIcon, danmakuLabel),
        ] {
            group.axis = .horizontal
            group.alignment = .center
            group.spacing = 3
            icon.tintColor = .tertiaryLabel
            icon.contentMode = .scaleAspectFit
            label.textColor = .tertiaryLabel
            label.numberOfLines = 1
            label.adjustsFontForContentSizeCategory = true
            group.addArrangedSubview(icon)
            group.addArrangedSubview(label)
            stack.addArrangedSubview(group)
        }
    }

    func configure(play: Int?, danmaku: Int?, font: UIFont) {
        isHidden = play == nil && danmaku == nil
        guard !isHidden else { return }
        let symConfig = UIImage.SymbolConfiguration(font: font, scale: .small)

        playGroup.isHidden = play == nil
        if let play {
            playIcon.preferredSymbolConfiguration = symConfig
            playLabel.font = font
            playLabel.text = FormatUtils.viewCount(play)
        }

        danmakuGroup.isHidden = danmaku == nil
        if let danmaku {
            danmakuIcon.preferredSymbolConfiguration = symConfig
            danmakuLabel.font = font
            danmakuLabel.text = FormatUtils.viewCount(danmaku)
        }
    }
}
