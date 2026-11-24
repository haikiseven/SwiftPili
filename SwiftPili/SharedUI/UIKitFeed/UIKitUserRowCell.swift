import UIKit

@MainActor
final class UIKitUserRowCell: UICollectionViewCell {
    enum Accessory {
        case none
        case chevron
        case followControls(
            showsGroupButton: Bool,
            isFollowing: Bool,
            isFollowBusy: Bool,
            onGroupTap: () -> Void,
            onFollowTap: () -> Void
        )
    }

    struct Model {
        let title: String
        var subtitle: String?
        let avatarURL: String?
        var avatarSize: CGFloat = 48
        var horizontalPadding: CGFloat = 0
        var verticalPadding: CGFloat = 10
        var showsSeparator: Bool = false
        var accessory: Accessory = .chevron
    }

    private let containerStack = UIStackView()
    private let avatarView = UIImageView()
    private let textStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let groupButton = UIButton(type: .system)
    private let followButton = UIButton(type: .custom)
    private let separatorView = UIView()

    private var avatarWidthConstraint: NSLayoutConstraint?
    private var avatarHeightConstraint: NSLayoutConstraint?
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?
    private var separatorLeadingConstraint: NSLayoutConstraint?
    private static let avatarPlaceholder = UIImage(systemName: "person.crop.circle.fill")

    private var activeAvatarRequest: UIKitCoverPipeline.CoverRequest?
    private var onGroupTap: (() -> Void)?
    private var onFollowTap: (() -> Void)?

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

        setupStackAndLabels()
        setupAccessories()
        activateConstraints()
    }

    private func setupStackAndLabels() {
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.axis = .horizontal
        containerStack.alignment = .center
        containerStack.spacing = 12
        contentView.addSubview(containerStack)

        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.layer.cornerRadius = 24
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 3

        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true

        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
    }

    private func setupAccessories() {
        chevronView.tintColor = .tertiaryLabel
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.isHidden = true

        groupButton.tintColor = .secondaryLabel
        var groupConfig = UIButton.Configuration.plain()
        groupConfig.image = UIImage(systemName: "folder.badge.person.crop")
        groupConfig.contentInsets = .zero
        groupButton.configuration = groupConfig
        groupButton.accessibilityLabel = String(localized: "Manage Groups")
        groupButton.translatesAutoresizingMaskIntoConstraints = false
        groupButton.addTarget(self, action: #selector(handleGroupTap), for: .touchUpInside)
        groupButton.isHidden = true

        followButton.translatesAutoresizingMaskIntoConstraints = false
        followButton.layer.cornerCurve = .continuous
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        followButton.setContentHuggingPriority(.required, for: .horizontal)
        followButton.addTarget(self, action: #selector(handleFollowTap), for: .touchUpInside)
        followButton.isHidden = true

        containerStack.addArrangedSubview(avatarView)
        containerStack.addArrangedSubview(textStack)
        containerStack.addArrangedSubview(groupButton)
        containerStack.addArrangedSubview(followButton)
        containerStack.addArrangedSubview(chevronView)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = .separator
        separatorView.isHidden = true
        contentView.addSubview(separatorView)
    }

    private func activateConstraints() {
        let avatarW = avatarView.widthAnchor.constraint(equalToConstant: 48)
        let avatarH = avatarView.heightAnchor.constraint(equalToConstant: 48)
        let top = containerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10)
        let bottom = containerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        let leading = containerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let trailing = containerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        let sepLeading = separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 68)
        avatarWidthConstraint = avatarW
        avatarHeightConstraint = avatarH
        topConstraint = top
        bottomConstraint = bottom
        leadingConstraint = leading
        trailingConstraint = trailing
        separatorLeadingConstraint = sepLeading

        NSLayoutConstraint.activate([
            avatarW,
            avatarH,
            groupButton.widthAnchor.constraint(equalToConstant: 44),
            groupButton.heightAnchor.constraint(equalToConstant: 44),
            top,
            bottom,
            leading,
            trailing,
            separatorView.heightAnchor.constraint(equalToConstant: UIKitFeedLayoutMetrics.hairlineWidth),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sepLeading,
        ])
    }

    func configure(_ model: Model) {
        let traits = traitCollection
        avatarWidthConstraint?.constant = model.avatarSize
        avatarHeightConstraint?.constant = model.avatarSize
        avatarView.layer.cornerRadius = model.avatarSize / 2
        topConstraint?.constant = model.verticalPadding
        bottomConstraint?.constant = -model.verticalPadding
        leadingConstraint?.constant = model.horizontalPadding
        trailingConstraint?.constant = -model.horizontalPadding
        separatorView.isHidden = !model.showsSeparator
        separatorLeadingConstraint?.constant = model.horizontalPadding + model.avatarSize + 12

        let request = UIKitCoverPipeline.avatarRequest(
            urlString: model.avatarURL,
            pointSize: model.avatarSize,
            scale: traits.displayScale
        )
        UIKitCoverPipeline.apply(
            to: avatarView,
            request: request,
            activeRequest: &activeAvatarRequest,
            placeholderImage: Self.avatarPlaceholder
        )
        avatarView.tintColor = .tertiaryLabel

        titleLabel.text = model.title
        titleLabel.font = UIKitFeedFont.font(for: .messageTitle, weight: .medium, traitCollection: traits)

        let hasSubtitle = model.subtitle.map { !$0.isEmpty } ?? false
        subtitleLabel.isHidden = !hasSubtitle
        subtitleLabel.text = model.subtitle
        subtitleLabel.font = UIKitFeedFont.font(for: .messageMeta, traitCollection: traits)

        configureAccessory(model.accessory, traits: traits)
        accessibilityLabel = hasSubtitle ? "\(model.title), \(model.subtitle ?? "")" : model.title
    }

    private func configureAccessory(_ accessory: Accessory, traits: UITraitCollection) {
        switch accessory {
        case .none:
            chevronView.isHidden = true
            groupButton.isHidden = true
            followButton.isHidden = true
            onGroupTap = nil
            onFollowTap = nil
            isAccessibilityElement = true
        case .chevron:
            chevronView.isHidden = false
            chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                font: UIKitFeedFont.systemFont(textStyle: .caption, traitCollection: traits)
            )
            groupButton.isHidden = true
            followButton.isHidden = true
            onGroupTap = nil
            onFollowTap = nil
            isAccessibilityElement = true
        case .followControls(let showsGroup, let isFollowing, let isBusy, let groupAction, let followAction):
            chevronView.isHidden = true
            groupButton.isHidden = !showsGroup
            var updatedGroupConfig = groupButton.configuration
            updatedGroupConfig?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                font: UIKitFeedFont.systemFont(textStyle: .subheadline, traitCollection: traits)
            )
            groupButton.configuration = updatedGroupConfig
            followButton.isHidden = false
            followButton.isEnabled = !isBusy
            followButton.alpha = isBusy ? 0.5 : 1.0
            onGroupTap = groupAction
            onFollowTap = followAction
            isAccessibilityElement = false

            var config = UIButton.Configuration.filled()
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            config.baseBackgroundColor = isFollowing
                ? UIColor.tertiarySystemFill
                : UIColor(AccentStore.shared.semanticAccent)
            config.baseForegroundColor = isFollowing ? .secondaryLabel : .white
            let titleText = isFollowing ? String(localized: "Following") : String(localized: "Follow")
            let font = UIKitFeedFont.systemFont(textStyle: .caption, weight: .medium, traitCollection: traits)
            config.attributedTitle = AttributedString(titleText, attributes: AttributeContainer([.font: font]))
            followButton.configuration = config
        }
    }

    @objc private func handleGroupTap() {
        onGroupTap?()
    }

    @objc private func handleFollowTap() {
        onFollowTap?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        UIKitCoverPipeline.cancel(on: avatarView, activeRequest: &activeAvatarRequest)
        onGroupTap = nil
        onFollowTap = nil
        titleLabel.text = nil
        subtitleLabel.text = nil
        accessibilityLabel = nil
        isAccessibilityElement = true
    }
}
