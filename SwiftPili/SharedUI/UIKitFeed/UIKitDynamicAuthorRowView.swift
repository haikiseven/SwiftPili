import UIKit

/// Pure UIKit author header row matching `DynamicAuthorRow`.
@MainActor
final class UIKitDynamicAuthorRowView: UIView {
    var onOpenProfile: ((Int) -> Void)?

    private let outerStack = UIStackView()
    private let identityButton = UIControl()
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let metaStack = UIStackView()
    private let timeLabel = UILabel()
    private let typeLabel = UILabel()

    private var activeAvatarRequest: UIKitCoverPipeline.CoverRequest?
    private var authorMID: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear

        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.axis = .horizontal
        outerStack.alignment = .center
        outerStack.spacing = 8
        addSubview(outerStack)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.layer.cornerRadius = 19
        avatarView.layer.borderWidth = UIKitFeedLayoutMetrics.hairlineWidth
        avatarView.isUserInteractionEnabled = false

        metaStack.translatesAutoresizingMaskIntoConstraints = false
        metaStack.axis = .horizontal
        metaStack.alignment = .firstBaseline
        metaStack.spacing = 8
        metaStack.isUserInteractionEnabled = false
        metaStack.addArrangedSubview(timeLabel)
        metaStack.addArrangedSubview(typeLabel)

        let textStack = UIStackView(arrangedSubviews: [nameLabel, metaStack])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.isUserInteractionEnabled = false

        for label in [nameLabel, timeLabel, typeLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontForContentSizeCategory = true
        }
        nameLabel.textColor = .label
        timeLabel.textColor = .secondaryLabel
        typeLabel.textColor = .tertiaryLabel
        typeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let identityRow = UIStackView(arrangedSubviews: [avatarView, textStack])
        identityRow.translatesAutoresizingMaskIntoConstraints = false
        identityRow.axis = .horizontal
        identityRow.alignment = .center
        identityRow.spacing = 10
        identityRow.isUserInteractionEnabled = false

        identityButton.addSubview(identityRow)
        identityButton.addTarget(self, action: #selector(handleProfileTap), for: .touchUpInside)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)

        outerStack.addArrangedSubview(identityButton)
        outerStack.addArrangedSubview(spacer)

        activateConstraints(identityRow: identityRow)

        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitPreferredContentSizeCategory.self,
        ]) { (self: UIKitDynamicAuthorRowView, _) in
            self.applyTraitStyling()
        }
        applyTraitStyling()
    }

    private func activateConstraints(identityRow: UIStackView) {
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: topAnchor),
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 38),
            avatarView.heightAnchor.constraint(equalToConstant: 38),
            identityButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            identityButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            identityRow.topAnchor.constraint(greaterThanOrEqualTo: identityButton.topAnchor),
            identityRow.bottomAnchor.constraint(lessThanOrEqualTo: identityButton.bottomAnchor),
            identityRow.centerYAnchor.constraint(equalTo: identityButton.centerYAnchor),
            identityRow.leadingAnchor.constraint(equalTo: identityButton.leadingAnchor),
            identityRow.trailingAnchor.constraint(equalTo: identityButton.trailingAnchor),
        ])
    }

    func configure(
        author: DynamicFeedResult.DynamicItem.DynamicModules.ModuleAuthor,
        contentType: String?
    ) {
        let traits = traitCollection
        authorMID = (author.mid ?? 0) > 0 ? author.mid : nil
        identityButton.isEnabled = authorMID != nil
        if let name = author.name, authorMID != nil {
            identityButton.accessibilityLabel = String(format: String(localized: "View profile: %@"), name)
        } else {
            identityButton.accessibilityLabel = nil
        }

        avatarView.isHidden = author.face == nil
        if let face = author.face {
            let request = UIKitCoverPipeline.avatarRequest(
                urlString: face, pointSize: 38, scale: traits.displayScale
            )
            UIKitCoverPipeline.apply(
                to: avatarView,
                request: request,
                activeRequest: &activeAvatarRequest,
                placeholderImage: UIImage(systemName: "person.crop.circle.fill")
            )
            avatarView.tintColor = .tertiaryLabel
        } else {
            UIKitCoverPipeline.cancel(on: avatarView, activeRequest: &activeAvatarRequest)
        }

        nameLabel.text = author.name ?? ""
        let timeText = author.pubTs.map { FormatUtils.timeAgo(from: $0) }
        let hasTime = timeText?.isEmpty == false
        let hasType = contentType?.isEmpty == false
        timeLabel.text = hasTime ? timeText : nil
        timeLabel.isHidden = !hasTime
        typeLabel.text = hasType ? contentType : nil
        typeLabel.isHidden = !hasType
        metaStack.isHidden = !hasTime && !hasType
        applyTraitStyling()
    }

    func prepareForReuse() {
        authorMID = nil
        onOpenProfile = nil
        UIKitCoverPipeline.cancel(on: avatarView, activeRequest: &activeAvatarRequest)
        nameLabel.text = nil
        timeLabel.text = nil
        typeLabel.text = nil
        timeLabel.isHidden = false
        typeLabel.isHidden = false
        metaStack.isHidden = false
    }

    private func applyTraitStyling() {
        let traits = traitCollection
        avatarView.layer.borderColor = UIColor.quaternaryLabel.resolvedColor(with: traits).cgColor
        nameLabel.font = UIKitFeedFont.systemFont(textStyle: .callout, weight: .semibold, traitCollection: traits)
        let metaFont = UIKitFeedFont.systemFont(textStyle: .caption, traitCollection: traits)
        timeLabel.font = metaFont
        typeLabel.font = metaFont
        let isA11y = traits.preferredContentSizeCategory.isAccessibilityCategory
        nameLabel.numberOfLines = isA11y ? 2 : 1
        timeLabel.numberOfLines = isA11y ? 2 : 1
        typeLabel.numberOfLines = isA11y ? 2 : 1
    }

    @objc private func handleProfileTap() {
        if let authorMID { onOpenProfile?(authorMID) }
    }
}
