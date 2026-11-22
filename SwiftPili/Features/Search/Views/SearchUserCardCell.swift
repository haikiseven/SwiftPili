import SwiftUI
import UIKit

/// Rich UP Master search result card displaying avatar, verification badge,
/// live indicator, followers/videos counts, bio, and an optional compact
/// 3-column representative video strip.
@MainActor
final class SearchUserCardCell: UICollectionViewCell {
    struct VideoItem {
        let title: String
        let sources: VideoCoverSources
        let durationSeconds: Int
        let playCount: Int
    }

    struct Model {
        let uname: String
        let avatarURL: String
        let verificationTier: OfficialVerificationTier?
        let officialVerifyDesc: String?
        let fans: Int
        let videos: Int
        let usign: String
        let isLive: Bool
        let representativeVideos: [VideoItem]
        var showsSeparator: Bool = false
    }

    private let cardView = UIView()
    private let rootStack = UIStackView()
    private let headerView = UIView()
    private let headerStack = UIStackView()
    private let avatarView = UIImageView()
    private let textStack = UIStackView()
    private let nameRow = UIStackView()
    private let nameLabel = UILabel()
    private let verifiedIcon = UIImageView(image: UIImage(systemName: "checkmark.seal.fill"))
    private let liveBadge = UIKitMediaBadgeView(horizontalPadding: 5, verticalPadding: 2)
    private let statsLabel = UILabel()
    private let officialDescLabel = UILabel()
    private let bioLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let videosStack = UIStackView()
    private let separatorView = UIView()
    private var videoTiles: [SearchRepresentativeVideoTile] = []

    private var rootTopConstraint: NSLayoutConstraint?
    private var rootLeadingConstraint: NSLayoutConstraint?
    private var rootTrailingConstraint: NSLayoutConstraint?
    private var rootBottomConstraint: NSLayoutConstraint?
    private var separatorHeightConstraint: NSLayoutConstraint?

    private var activeAvatarRequest: UIKitCoverPipeline.CoverRequest?
    private var onSelectVideoAtIndex: ((Int) -> Void)?

    private static let avatarSize: CGFloat = 48

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

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .clear
        cardView.layer.cornerCurve = .continuous
        contentView.addSubview(cardView)

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = AppSpacing.m
        cardView.addSubview(rootStack)

        setupHeader()
        setupVideosStrip()

        rootStack.addArrangedSubview(headerView)
        rootStack.addArrangedSubview(videosStack)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = .separator
        separatorView.isHidden = true
        contentView.addSubview(separatorView)

        let top = rootStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10)
        let leading = rootStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor)
        let trailing = rootStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor)
        let bottom = rootStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10)
        let sepHeight = separatorView.heightAnchor.constraint(equalToConstant: 0.5)
        rootTopConstraint = top
        rootLeadingConstraint = leading
        rootTrailingConstraint = trailing
        rootBottomConstraint = bottom
        separatorHeightConstraint = sepHeight

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            top,
            leading,
            trailing,
            bottom,
            separatorView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: Self.avatarSize + AppSpacing.m
            ),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sepHeight,
        ])
    }

    private func setupHeader() {
        headerView.isAccessibilityElement = true
        headerView.accessibilityTraits = .button

        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = AppSpacing.m
        headerView.addSubview(headerStack)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.layer.cornerRadius = Self.avatarSize / 2

        setupHeaderLabels()

        chevronView.tintColor = .tertiaryLabel
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)

        headerStack.addArrangedSubview(avatarView)
        headerStack.addArrangedSubview(textStack)
        headerStack.addArrangedSubview(chevronView)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
        ])
    }

    private func setupHeaderLabels() {
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 3

        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = 6

        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textColor = .label
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        verifiedIcon.contentMode = .scaleAspectFit
        verifiedIcon.setContentHuggingPriority(.required, for: .horizontal)
        verifiedIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        verifiedIcon.isHidden = true

        liveBadge.setContentHuggingPriority(.required, for: .horizontal)
        liveBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        liveBadge.isHidden = true

        nameRow.addArrangedSubview(nameLabel)
        nameRow.addArrangedSubview(verifiedIcon)
        nameRow.addArrangedSubview(liveBadge)
        nameRow.addArrangedSubview(UIView())

        for label in [statsLabel, officialDescLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .secondaryLabel
            label.adjustsFontForContentSizeCategory = true
        }
        bioLabel.lineBreakMode = .byTruncatingTail
        bioLabel.textColor = .tertiaryLabel
        bioLabel.adjustsFontForContentSizeCategory = true

        textStack.addArrangedSubview(nameRow)
        textStack.addArrangedSubview(officialDescLabel)
        textStack.addArrangedSubview(statsLabel)
        textStack.addArrangedSubview(bioLabel)
    }

    private func setupVideosStrip() {
        videosStack.axis = .horizontal
        videosStack.alignment = .top
        videosStack.distribution = .fillEqually
        videosStack.spacing = AppSpacing.s
        videosStack.isHidden = true

        for index in 0..<3 {
            let tile = SearchRepresentativeVideoTile()
            tile.tag = index
            tile.addTarget(self, action: #selector(handleVideoTileTap(_:)), for: .touchUpInside)
            videoTiles.append(tile)
            videosStack.addArrangedSubview(tile)
        }
    }

    func configure(_ model: Model, onSelectVideo: @escaping (Int) -> Void) {
        onSelectVideoAtIndex = onSelectVideo
        let traits = traitCollection

        let avatarReq = UIKitCoverPipeline.avatarRequest(
            urlString: model.avatarURL,
            pointSize: Self.avatarSize,
            scale: traits.displayScale
        )
        UIKitCoverPipeline.apply(
            to: avatarView,
            request: avatarReq,
            activeRequest: &activeAvatarRequest,
            placeholderImage: UIImage(systemName: "person.crop.circle.fill")
        )
        avatarView.tintColor = .tertiaryLabel

        nameLabel.text = model.uname
        nameLabel.font = UIKitFeedFont.font(for: .messageTitle, weight: .semibold, traitCollection: traits)

        configureVerificationAndLive(model: model, traits: traits)

        let trimmedOfficial = model.officialVerifyDesc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        officialDescLabel.isHidden = trimmedOfficial.isEmpty
        officialDescLabel.text = trimmedOfficial
        officialDescLabel.font = UIKitFeedFont.font(for: .cardMeta, traitCollection: traits)

        let followersLabel = String(localized: "Followers")
        let postsLabel = String(localized: "Submissions")
        let statsText = "\(followersLabel) \(FormatUtils.viewCount(model.fans))  \(postsLabel) \(model.videos)"
        statsLabel.text = statsText
        statsLabel.font = UIKitFeedFont.font(
            for: .libraryRowMeta, monospacedDigit: true, traitCollection: traits
        )

        let trimmedBio = model.usign.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewVideos = Array(model.representativeVideos.prefix(3))
        bioLabel.numberOfLines = (trimmedOfficial.isEmpty && previewVideos.isEmpty) ? 2 : 1
        bioLabel.isHidden = trimmedBio.isEmpty
        bioLabel.text = trimmedBio
        bioLabel.font = UIKitFeedFont.font(for: .libraryRowMeta, traitCollection: traits)

        chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: UIKitFeedFont.systemFont(textStyle: .caption, traitCollection: traits)
        )

        applyContainerStyle(
            hasVideos: !previewVideos.isEmpty,
            showsSeparator: model.showsSeparator,
            scale: traits.displayScale
        )
        configureVideoTiles(previewVideos)

        var a11y = [model.uname]
        if !trimmedOfficial.isEmpty { a11y.append(trimmedOfficial) }
        a11y.append(statsText)
        if model.isLive { a11y.append(String(localized: "LIVE")) }
        if !trimmedBio.isEmpty { a11y.append(trimmedBio) }
        headerView.accessibilityLabel = a11y.joined(separator: ", ")
    }

    private func applyContainerStyle(hasVideos: Bool, showsSeparator: Bool, scale: CGFloat) {
        let verticalInset: CGFloat = hasVideos ? AppSpacing.m : 10
        let horizontalInset: CGFloat = hasVideos ? AppSpacing.m : 0
        cardView.backgroundColor = hasVideos ? .secondarySystemGroupedBackground : .clear
        cardView.layer.cornerRadius = hasVideos ? AppRadius.card : 0
        rootTopConstraint?.constant = verticalInset
        rootBottomConstraint?.constant = -verticalInset
        rootLeadingConstraint?.constant = horizontalInset
        rootTrailingConstraint?.constant = -horizontalInset
        separatorView.isHidden = hasVideos || !showsSeparator
        separatorHeightConstraint?.constant = 1.0 / max(1.0, scale)
    }

    private func configureVerificationAndLive(model: Model, traits: UITraitCollection) {
        let symbolFont = UIKitFeedFont.systemFont(textStyle: .subheadline, traitCollection: traits)
        verifiedIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: symbolFont)
        switch model.verificationTier {
        case .personal:
            verifiedIcon.isHidden = false
            verifiedIcon.tintColor = .systemOrange
        case .organization:
            verifiedIcon.isHidden = false
            verifiedIcon.tintColor = .systemBlue
        case nil:
            verifiedIcon.isHidden = true
        }

        if model.isLive {
            liveBadge.configurePill(
                text: String(localized: "LIVE"),
                backgroundColor: .systemRed,
                traitCollection: traits
            )
        } else {
            liveBadge.isHidden = true
        }
    }

    private func configureVideoTiles(_ videos: [VideoItem]) {
        videosStack.isHidden = videos.isEmpty
        for (index, tile) in videoTiles.enumerated() {
            if index < videos.count {
                tile.isHidden = false
                tile.alpha = 1
                tile.isUserInteractionEnabled = true
                tile.isAccessibilityElement = true
                tile.configure(videos[index])
            } else {
                tile.isHidden = false
                tile.alpha = 0
                tile.isUserInteractionEnabled = false
                tile.isAccessibilityElement = false
                tile.reset()
            }
        }
    }

    @objc private func handleVideoTileTap(_ sender: SearchRepresentativeVideoTile) {
        onSelectVideoAtIndex?(sender.tag)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        UIKitCoverPipeline.cancel(on: avatarView, activeRequest: &activeAvatarRequest)
        onSelectVideoAtIndex = nil
        verifiedIcon.isHidden = true
        liveBadge.isHidden = true
        officialDescLabel.isHidden = true
        bioLabel.isHidden = true
        videosStack.isHidden = true
        separatorView.isHidden = true
        for tile in videoTiles { tile.reset() }
        headerView.accessibilityLabel = nil
    }
}

/// Compact 16:9 representative video tile rendered inside `SearchUserCardCell`.
@MainActor
private final class SearchRepresentativeVideoTile: UIControl {
    private let coverBox = UIKitCoverBoxView()
    private let overlayBar = UIStackView()
    private let playIcon = UIImageView(image: UIImage(systemName: "play.fill"))
    private let viewsLabel = UILabel()
    private let durationLabel = UILabel()
    private let titleLabel = UILabel()

    override var isHighlighted: Bool {
        didSet {
            let target: CGFloat = isHighlighted ? 0.72 : 1.0
            if UIAccessibility.isReduceMotionEnabled {
                alpha = target
            } else {
                UIView.animate(withDuration: 0.12) { self.alpha = target }
            }
        }
    }

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
        coverBox.isUserInteractionEnabled = false
        coverBox.configureStyle(cornerRadius: AppRadius.thumbnail, scrim: .cardBottom, showsBorder: true)
        addSubview(coverBox)

        overlayBar.translatesAutoresizingMaskIntoConstraints = false
        overlayBar.axis = .horizontal
        overlayBar.alignment = .center
        overlayBar.spacing = 3
        overlayBar.isUserInteractionEnabled = false
        coverBox.addSubview(overlayBar)

        let overlayColor = UIColor.white.withAlphaComponent(0.95)
        playIcon.tintColor = overlayColor
        playIcon.contentMode = .scaleAspectFit
        playIcon.setContentHuggingPriority(.required, for: .horizontal)
        playIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        viewsLabel.textColor = overlayColor
        viewsLabel.numberOfLines = 1
        viewsLabel.adjustsFontForContentSizeCategory = true

        durationLabel.textColor = overlayColor
        durationLabel.numberOfLines = 1
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        overlayBar.addArrangedSubview(playIcon)
        overlayBar.addArrangedSubview(viewsLabel)
        overlayBar.addArrangedSubview(UIView())
        overlayBar.addArrangedSubview(durationLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isUserInteractionEnabled = false
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            coverBox.topAnchor.constraint(equalTo: topAnchor),
            coverBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            coverBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            coverBox.heightAnchor.constraint(equalTo: coverBox.widthAnchor, multiplier: 9.0 / 16.0),

            overlayBar.leadingAnchor.constraint(equalTo: coverBox.leadingAnchor, constant: 5),
            overlayBar.trailingAnchor.constraint(equalTo: coverBox.trailingAnchor, constant: -5),
            overlayBar.bottomAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: -4),

            titleLabel.topAnchor.constraint(equalTo: coverBox.bottomAnchor, constant: AppSpacing.xs),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(_ item: SearchUserCardCell.VideoItem) {
        let traits = traitCollection
        let request = UIKitCoverPipeline.request(
            sources: item.sources,
            drawnBox: CGSize(width: 140, height: 79),
            presentation: CoverPresentationStore.shared.presentation,
            scale: traits.displayScale
        )
        coverBox.setCover(request: request)

        let badgeFont = UIKitFeedFont.font(
            for: .overlayBadge, weight: .medium, monospacedDigit: true, traitCollection: traits
        )
        playIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: UIKitFeedFont.systemFont(textStyle: .caption2, traitCollection: traits),
            scale: .small
        )
        viewsLabel.text = FormatUtils.viewCount(item.playCount)
        viewsLabel.font = badgeFont

        if item.durationSeconds > 0 {
            durationLabel.isHidden = false
            durationLabel.text = FormatUtils.duration(item.durationSeconds)
            durationLabel.font = badgeFont
        } else {
            durationLabel.isHidden = true
        }

        titleLabel.text = item.title
        titleLabel.font = UIKitFeedFont.font(for: .shelfCardTitle, weight: .medium, traitCollection: traits)

        var a11y = [item.title, FormatUtils.viewCount(item.playCount)]
        if item.durationSeconds > 0 { a11y.append(FormatUtils.duration(item.durationSeconds)) }
        accessibilityLabel = a11y.joined(separator: ", ")
    }

    func reset() {
        coverBox.resetCover()
        titleLabel.text = nil
        viewsLabel.text = nil
        durationLabel.text = nil
        accessibilityLabel = nil
    }
}
