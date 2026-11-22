import UIKit

@MainActor
final class UIKitDynamicMediaCardView: UIView {
    enum Kind: Equatable {
        case video(duration: String?)
        case live(areaName: String?)
        case labeled(String?)
    }

    struct Model: Equatable {
        let title: String?
        let cover: String?
        let kind: Kind
        var subtitle: String?
        var quoted: Bool = false
        var titleLineLimit: Int? = 2
        var availableWidth: CGFloat?
    }

    var onTap: (() -> Void)? {
        didSet { isUserInteractionEnabled = onTap != nil }
    }

    fileprivate enum DisplayMode { case main, quoted, fallback }

    private let mainUnitView = UIView()
    private let mainCoverBox = UIKitCoverBoxView()
    private let mainCoverDivider = UIView()
    private let mainTopBadge = UIKitMediaBadgeView(horizontalPadding: 6, verticalPadding: 2.5)
    private let mainBottomBadge = UIKitDurationBadge(isCapsule: false, horizontalPadding: 6, verticalPadding: 2.5)
    private let mainTitleLabel = UILabel()
    private let mainMetaLabel = UILabel()
    private var mainWidthConstraint: NSLayoutConstraint?
    private var mainCoverHeightConstraint: NSLayoutConstraint?
    private var mainConstraints: [NSLayoutConstraint] = []

    private let quotedRowView = UIView()
    private let quotedStack = UIStackView()
    private let quotedCoverContainer = UIView()
    private let quotedCoverBox = UIKitCoverBoxView()
    private let quotedTopBadge = UIKitMediaBadgeView(horizontalPadding: 5, verticalPadding: 2)
    private let quotedBottomBadge = UIKitDurationBadge(isCapsule: false, horizontalPadding: 5, verticalPadding: 2)
    private let quotedTitleLabel = UILabel()
    private let quotedMetaLabel = UILabel()
    private var quotedThumbWidthConstraint: NSLayoutConstraint?
    private var quotedThumbHeightConstraint: NSLayoutConstraint?
    private var quotedConstraints: [NSLayoutConstraint] = []

    private let fallbackCard = UIView()
    private let fallbackTitleLabel = UILabel()
    private let fallbackMetaLabel = UILabel()
    private let fallbackPill = UIKitMediaBadgeView(horizontalPadding: 6, verticalPadding: 2)
    private var fallbackConstraints: [NSLayoutConstraint] = []

    private var model: Model?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))

        setupMainUnit()
        setupQuotedRow()
        setupFallbackCard()
        switchMode(.fallback)
        applyMainBorderStyling()

        registerForTraitChanges([
            UITraitPreferredContentSizeCategory.self,
            UITraitDisplayScale.self,
            UITraitUserInterfaceStyle.self,
        ]) { (self: UIKitDynamicMediaCardView, _) in
            self.applyMainBorderStyling()
            if let model = self.model { self.configure(model) }
        }
    }

    func configure(_ model: Model) {
        self.model = model
        let hasCover = model.cover.map { !$0.isEmpty } ?? false
        if hasCover, let cover = model.cover {
            if model.quoted {
                switchMode(.quoted)
                configureQuotedMode(model, cover: cover)
            } else {
                switchMode(.main)
                configureMainMode(model, cover: cover)
            }
        } else {
            switchMode(.fallback)
            configureFallbackMode(model)
        }
    }

    func prepareForReuse() {
        model = nil
        onTap = nil
        mainCoverBox.resetCover()
        quotedCoverBox.resetCover()
        mainTitleLabel.text = nil
        mainMetaLabel.text = nil
        quotedTitleLabel.text = nil
        quotedMetaLabel.text = nil
        fallbackTitleLabel.text = nil
        fallbackMetaLabel.text = nil
        mainTopBadge.isHidden = true
        mainBottomBadge.isHidden = true
        quotedTopBadge.isHidden = true
        quotedBottomBadge.isHidden = true
    }

    @objc private func handleTap() { onTap?() }
}

private extension UIKitDynamicMediaCardView {
    func switchMode(_ mode: DisplayMode) {
        mainUnitView.isHidden = mode != .main
        quotedRowView.isHidden = mode != .quoted
        fallbackCard.isHidden = mode != .fallback
        NSLayoutConstraint.deactivate(mainConstraints + quotedConstraints + fallbackConstraints)
        switch mode {
        case .main:
            quotedCoverBox.resetCover()
            NSLayoutConstraint.activate(mainConstraints)
        case .quoted:
            mainCoverBox.resetCover()
            NSLayoutConstraint.activate(quotedConstraints)
        case .fallback:
            mainCoverBox.resetCover()
            quotedCoverBox.resetCover()
            NSLayoutConstraint.activate(fallbackConstraints)
        }
    }

    func setupMainUnit() {
        mainUnitView.translatesAutoresizingMaskIntoConstraints = false
        mainUnitView.backgroundColor = .clear
        mainUnitView.layer.cornerRadius = AppRadius.card
        mainUnitView.layer.cornerCurve = .continuous
        mainUnitView.layer.borderWidth = UIKitFeedLayoutMetrics.hairlineWidth
        mainUnitView.clipsToBounds = true
        addSubview(mainUnitView)

        let mainStack = UIStackView()
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.alignment = .fill
        mainStack.spacing = 0
        mainUnitView.addSubview(mainStack)

        let coverContainer = UIView()
        coverContainer.translatesAutoresizingMaskIntoConstraints = false
        mainCoverBox.translatesAutoresizingMaskIntoConstraints = false
        mainCoverBox.configureStyle(cornerRadius: .zero, scrim: .none, showsBorder: false)
        coverContainer.addSubview(mainCoverBox)

        mainTopBadge.translatesAutoresizingMaskIntoConstraints = false
        mainBottomBadge.translatesAutoresizingMaskIntoConstraints = false
        coverContainer.addSubview(mainTopBadge)
        coverContainer.addSubview(mainBottomBadge)

        mainCoverDivider.translatesAutoresizingMaskIntoConstraints = false
        mainCoverDivider.isUserInteractionEnabled = false

        let footer = UIView()
        footer.backgroundColor = .clear
        let footerStack = makeTextStack(title: mainTitleLabel, meta: mainMetaLabel, spacing: 3)
        footer.addSubview(footerStack)

        mainStack.addArrangedSubview(coverContainer)
        mainStack.addArrangedSubview(mainCoverDivider)
        mainStack.addArrangedSubview(footer)

        let widthC = mainUnitView.widthAnchor.constraint(equalToConstant: 320)
        widthC.priority = .defaultHigh
        let coverHeightC = coverContainer.heightAnchor.constraint(equalToConstant: 179)
        mainWidthConstraint = widthC
        mainCoverHeightConstraint = coverHeightC

        mainConstraints = [
            mainUnitView.topAnchor.constraint(equalTo: topAnchor),
            mainUnitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainUnitView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            mainUnitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthC,
        ]
        activateMainUnitConstraints(
            mainStack: mainStack, coverContainer: coverContainer, coverHeight: coverHeightC,
            footer: footer, footerStack: footerStack
        )
    }

    func activateMainUnitConstraints(
        mainStack: UIStackView, coverContainer: UIView, coverHeight: NSLayoutConstraint,
        footer: UIView, footerStack: UIStackView
    ) {
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: mainUnitView.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: mainUnitView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: mainUnitView.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: mainUnitView.bottomAnchor),
            coverHeight,
            mainCoverDivider.heightAnchor.constraint(equalToConstant: UIKitFeedLayoutMetrics.hairlineWidth),
            mainCoverBox.topAnchor.constraint(equalTo: coverContainer.topAnchor),
            mainCoverBox.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor),
            mainCoverBox.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor),
            mainCoverBox.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor),
            mainTopBadge.topAnchor.constraint(equalTo: coverContainer.topAnchor, constant: 8),
            mainTopBadge.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor, constant: 8),
            mainBottomBadge.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor, constant: -8),
            mainBottomBadge.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor, constant: -8),
            footerStack.topAnchor.constraint(equalTo: footer.topAnchor, constant: 10),
            footerStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            footerStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            footerStack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -10),
        ])
    }

    func applyMainBorderStyling() {
        let traits = traitCollection
        mainUnitView.layer.borderColor = UIColor.label
            .withAlphaComponent(0.10)
            .resolvedColor(with: traits)
            .cgColor
        mainCoverDivider.backgroundColor = UIColor.separator
            .withAlphaComponent(0.35)
            .resolvedColor(with: traits)
    }

    func setupQuotedRow() {
        quotedRowView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(quotedRowView)

        quotedStack.translatesAutoresizingMaskIntoConstraints = false
        quotedStack.axis = .horizontal
        quotedStack.alignment = .center
        quotedStack.spacing = 10
        quotedRowView.addSubview(quotedStack)

        quotedCoverContainer.translatesAutoresizingMaskIntoConstraints = false
        quotedCoverContainer.layer.cornerRadius = AppRadius.thumbnail
        quotedCoverContainer.layer.cornerCurve = .continuous
        quotedCoverContainer.clipsToBounds = true

        quotedCoverBox.translatesAutoresizingMaskIntoConstraints = false
        quotedCoverBox.configureStyle(cornerRadius: AppRadius.thumbnail, scrim: .none, showsBorder: false)
        quotedCoverContainer.addSubview(quotedCoverBox)

        quotedTopBadge.translatesAutoresizingMaskIntoConstraints = false
        quotedBottomBadge.translatesAutoresizingMaskIntoConstraints = false
        quotedCoverContainer.addSubview(quotedTopBadge)
        quotedCoverContainer.addSubview(quotedBottomBadge)

        let textStack = makeTextStack(title: quotedTitleLabel, meta: quotedMetaLabel, spacing: 4)
        quotedStack.addArrangedSubview(quotedCoverContainer)
        quotedStack.addArrangedSubview(textStack)

        let thumbW = quotedCoverContainer.widthAnchor.constraint(equalToConstant: 132)
        let thumbH = quotedCoverContainer.heightAnchor.constraint(equalToConstant: 74)
        quotedThumbWidthConstraint = thumbW
        quotedThumbHeightConstraint = thumbH

        quotedConstraints = [
            quotedRowView.topAnchor.constraint(equalTo: topAnchor),
            quotedRowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            quotedRowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            quotedRowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            quotedRowView.heightAnchor.constraint(greaterThanOrEqualToConstant: 84),
        ]
        NSLayoutConstraint.activate([
            quotedStack.topAnchor.constraint(greaterThanOrEqualTo: quotedRowView.topAnchor, constant: 4),
            quotedStack.bottomAnchor.constraint(lessThanOrEqualTo: quotedRowView.bottomAnchor, constant: -4),
            quotedStack.centerYAnchor.constraint(equalTo: quotedRowView.centerYAnchor),
            quotedStack.leadingAnchor.constraint(equalTo: quotedRowView.leadingAnchor),
            quotedStack.trailingAnchor.constraint(equalTo: quotedRowView.trailingAnchor),
            thumbW, thumbH,
            quotedCoverBox.topAnchor.constraint(equalTo: quotedCoverContainer.topAnchor),
            quotedCoverBox.leadingAnchor.constraint(equalTo: quotedCoverContainer.leadingAnchor),
            quotedCoverBox.trailingAnchor.constraint(equalTo: quotedCoverContainer.trailingAnchor),
            quotedCoverBox.bottomAnchor.constraint(equalTo: quotedCoverContainer.bottomAnchor),
            quotedTopBadge.topAnchor.constraint(equalTo: quotedCoverContainer.topAnchor, constant: 6),
            quotedTopBadge.leadingAnchor.constraint(equalTo: quotedCoverContainer.leadingAnchor, constant: 6),
            quotedBottomBadge.bottomAnchor.constraint(equalTo: quotedCoverContainer.bottomAnchor, constant: -6),
            quotedBottomBadge.trailingAnchor.constraint(equalTo: quotedCoverContainer.trailingAnchor, constant: -6),
        ])
    }

    func setupFallbackCard() {
        fallbackCard.translatesAutoresizingMaskIntoConstraints = false
        fallbackCard.backgroundColor = .tertiarySystemFill
        fallbackCard.layer.cornerRadius = AppRadius.card
        fallbackCard.layer.cornerCurve = .continuous
        addSubview(fallbackCard)

        let stack = makeTextStack(title: fallbackTitleLabel, meta: fallbackMetaLabel, spacing: 5)
        fallbackMetaLabel.numberOfLines = 0
        stack.addArrangedSubview(fallbackPill)
        fallbackCard.addSubview(stack)

        fallbackConstraints = [
            fallbackCard.topAnchor.constraint(equalTo: topAnchor),
            fallbackCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            fallbackCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            fallbackCard.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: fallbackCard.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: fallbackCard.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: fallbackCard.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: fallbackCard.bottomAnchor, constant: -12),
        ])
    }

    func makeTextStack(title: UILabel, meta: UILabel, spacing: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [title, meta])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true
        meta.textColor = .secondaryLabel
        meta.adjustsFontForContentSizeCategory = true
        return stack
    }

    func configureMainMode(_ model: Model, cover: String) {
        let baseWidth = max(160, model.availableWidth ?? bounds.width)
        let cardWidth: CGFloat = switch model.kind {
        case .video: baseWidth
        case .live, .labeled: min(320, baseWidth)
        }
        let cardHeight = (cardWidth * 76.0 / 136.0).rounded()
        mainWidthConstraint?.constant = cardWidth
        mainCoverHeightConstraint?.constant = cardHeight

        let request = UIKitCoverPipeline.request(
            urlString: cover,
            drawnBox: CGSize(width: cardWidth, height: cardHeight),
            displayMode: .fill,
            scale: traitCollection.displayScale
        )
        mainCoverBox.setCover(request: request)
        configureBadges(kind: model.kind, topBadge: mainTopBadge, bottomBadge: mainBottomBadge)
        configureText(
            titleLabel: mainTitleLabel, metaLabel: mainMetaLabel,
            model: model, subtitle: resolvedMainSubtitle(for: model)
        )
        setNeedsLayout()
    }

    func configureQuotedMode(_ model: Model, cover: String) {
        let isA11y = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        quotedStack.axis = isA11y ? .vertical : .horizontal
        quotedStack.alignment = isA11y ? .leading : .center

        let baseWidth = max(132, model.availableWidth ?? bounds.width)
        let thumbWidth = min(132, baseWidth)
        let thumbHeight = (thumbWidth * 76.0 / 136.0).rounded()
        quotedThumbWidthConstraint?.constant = thumbWidth
        quotedThumbHeightConstraint?.constant = thumbHeight

        let request = UIKitCoverPipeline.request(
            urlString: cover,
            drawnBox: CGSize(width: thumbWidth, height: thumbHeight),
            displayMode: .fill,
            scale: traitCollection.displayScale
        )
        quotedCoverBox.setCover(request: request)
        configureBadges(kind: model.kind, topBadge: quotedTopBadge, bottomBadge: quotedBottomBadge)
        configureText(
            titleLabel: quotedTitleLabel, metaLabel: quotedMetaLabel,
            model: model, subtitle: resolvedQuotedSubtitle(for: model)
        )
        setNeedsLayout()
    }

    func configureFallbackMode(_ model: Model) {
        let traits = traitCollection
        fallbackTitleLabel.text = model.title ?? ""
        fallbackTitleLabel.numberOfLines = model.titleLineLimit ?? 0
        fallbackTitleLabel.font = UIKitFeedFont.systemFont(
            textStyle: .subheadline, weight: .semibold, traitCollection: traits
        )
        switch model.kind {
        case .video:
            fallbackMetaLabel.isHidden = true
            fallbackPill.isHidden = true
        case let .live(areaName):
            fallbackMetaLabel.isHidden = areaName?.isEmpty != false
            fallbackMetaLabel.text = areaName
            fallbackMetaLabel.font = UIKitFeedFont.systemFont(textStyle: .footnote, traitCollection: traits)
            fallbackPill.isHidden = true
        case let .labeled(badge):
            fallbackMetaLabel.isHidden = true
            fallbackPill.configurePill(
                text: badge,
                backgroundColor: UIColor.systemBlue.withAlphaComponent(0.12),
                textColor: .systemBlue,
                traitCollection: traits
            )
        }
    }

    func configureBadges(kind: Kind, topBadge: UIKitMediaBadgeView, bottomBadge: UIKitDurationBadge) {
        let traits = traitCollection
        let badgeFont = UIKitFeedFont.font(
            for: .overlayBadge, weight: .medium, monospacedDigit: true, traitCollection: traits
        )
        switch kind {
        case let .video(duration):
            topBadge.isHidden = true
            bottomBadge.configure(text: duration, font: badgeFont)
        case .live:
            topBadge.configureLiveState(.live, traitCollection: traits)
            bottomBadge.isHidden = true
        case let .labeled(badge):
            topBadge.configurePill(
                text: badge, backgroundColor: UIColor.black.withAlphaComponent(0.68), traitCollection: traits
            )
            bottomBadge.isHidden = true
        }
    }

    func configureText(titleLabel: UILabel, metaLabel: UILabel, model: Model, subtitle: String?) {
        let traits = traitCollection
        let isA11y = traits.preferredContentSizeCategory.isAccessibilityCategory
        let title = model.title ?? ""
        titleLabel.isHidden = title.isEmpty
        titleLabel.text = title
        titleLabel.numberOfLines = model.titleLineLimit ?? 0
        titleLabel.font = UIKitFeedFont.systemFont(
            textStyle: .subheadline, weight: .semibold, traitCollection: traits
        )

        if let subtitle, !subtitle.isEmpty {
            metaLabel.isHidden = false
            metaLabel.text = subtitle
            metaLabel.numberOfLines = isA11y ? 0 : 1
            metaLabel.font = UIKitFeedFont.systemFont(textStyle: .footnote, traitCollection: traits)
        } else {
            metaLabel.isHidden = true
            metaLabel.text = nil
        }
    }

    func resolvedMainSubtitle(for model: Model) -> String? {
        if let subtitle = model.subtitle, !subtitle.isEmpty { return subtitle }
        if case let .live(areaName) = model.kind, let areaName, !areaName.isEmpty { return areaName }
        return nil
    }

    func resolvedQuotedSubtitle(for model: Model) -> String? {
        if let subtitle = model.subtitle, !subtitle.isEmpty { return subtitle }
        switch model.kind {
        case .video: return String(localized: "Video")
        case let .live(areaName): return areaName
        case let .labeled(badge): return badge
        }
    }
}
