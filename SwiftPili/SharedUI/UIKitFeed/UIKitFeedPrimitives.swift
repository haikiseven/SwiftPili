import SwiftUI
import UIKit

/// Shared layout geometry constants matching SwiftUI feed and card metrics.
enum UIKitFeedLayoutMetrics {
    static let horizontalInset: CGFloat = AppSpacing.l
    static let topInset: CGFloat = AppSpacing.s
    static let bottomInset: CGFloat = AppSpacing.l
    static let gridColumnSpacing: CGFloat = 12
    static let gridRowSpacing: CGFloat = 14
    static let listRowSpacing: CGFloat = 12
    static let hairlineAlpha: CGFloat = 0.10
    static let hairlineWidth: CGFloat = 0.5
}

/// Resolves Dynamic Type-scaled `UIFont` values from `AppTypeScale`.
enum UIKitFeedFont {
    static func font(
        for role: AppTextRole,
        weight: UIFont.Weight? = nil,
        monospacedDigit: Bool = false,
        traitCollection: UITraitCollection
    ) -> UIFont {
        let isRegular = traitCollection.horizontalSizeClass == .regular
        let style = AppTypeScale.style(role, isRegularWidth: isRegular)
        return scaledFont(
            textStyle: style.uiTextStyle,
            nominalSize: style.nominalPointSize,
            weight: weight ?? style.uiFontWeight,
            monospacedDigit: monospacedDigit,
            traitCollection: traitCollection
        )
    }

    static func systemFont(
        textStyle: AppTextStyle,
        weight: UIFont.Weight? = nil,
        monospacedDigit: Bool = false,
        traitCollection: UITraitCollection
    ) -> UIFont {
        scaledFont(
            textStyle: textStyle.uiTextStyle,
            nominalSize: textStyle.nominalPointSize,
            weight: weight ?? textStyle.uiFontWeight,
            monospacedDigit: monospacedDigit,
            traitCollection: traitCollection
        )
    }

    private static func scaledFont(
        textStyle: UIFont.TextStyle,
        nominalSize: CGFloat,
        weight: UIFont.Weight,
        monospacedDigit: Bool,
        traitCollection: UITraitCollection
    ) -> UIFont {
        let base: UIFont = monospacedDigit
            ? .monospacedDigitSystemFont(ofSize: nominalSize, weight: weight)
            : .systemFont(ofSize: nominalSize, weight: weight)
        return UIFontMetrics(forTextStyle: textStyle)
            .scaledFont(for: base, compatibleWith: traitCollection)
    }
}

/// Rounded cover artwork container with optional bottom gradient scrim and
/// Light/Dark-reactive hairline border.
@MainActor
final class UIKitCoverBoxView: UIView {
    enum ScrimStyle {
        case none
        case cardBottom
        case heroOverlay
    }

    let imageView = UIImageView()
    private let scrimLayer = CAGradientLayer()
    private var scrimStyle: ScrimStyle = .none
    private var showsHairlineBorder = true
    private var activeRequest: UIKitCoverPipeline.CoverRequest?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        layer.cornerCurve = .continuous
        clipsToBounds = true
        backgroundColor = .secondarySystemFill

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.backgroundColor = .secondarySystemFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        scrimLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        scrimLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        layer.addSublayer(scrimLayer)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: UIKitCoverBoxView, _) in
            self.applyHairlineBorder()
        }
        applyHairlineBorder()
    }

    func configureStyle(
        cornerRadius: CGFloat,
        scrim: ScrimStyle,
        showsBorder: Bool
    ) {
        layer.cornerRadius = cornerRadius
        scrimStyle = scrim
        showsHairlineBorder = showsBorder
        applyHairlineBorder()

        switch scrim {
        case .none:
            scrimLayer.isHidden = true
        case .cardBottom:
            scrimLayer.isHidden = false
            scrimLayer.colors = [
                UIColor.clear.cgColor,
                UIColor.black.withAlphaComponent(0.55).cgColor,
            ]
            scrimLayer.locations = [0.0, 1.0]
        case .heroOverlay:
            scrimLayer.isHidden = false
            scrimLayer.colors = [
                UIColor.clear.cgColor,
                UIColor.black.withAlphaComponent(0.80).cgColor,
            ]
            scrimLayer.locations = [0.45, 1.0]
        }
        setNeedsLayout()
    }

    func setCover(request: UIKitCoverPipeline.CoverRequest, placeholderImage: UIImage? = nil) {
        UIKitCoverPipeline.apply(
            to: imageView,
            request: request,
            activeRequest: &activeRequest,
            placeholderImage: placeholderImage
        )
    }

    func resetCover() {
        UIKitCoverPipeline.cancel(on: imageView, activeRequest: &activeRequest)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch scrimStyle {
        case .none:
            scrimLayer.frame = .zero
        case .cardBottom:
            let scrimHeight: CGFloat = min(34, bounds.height)
            scrimLayer.frame = CGRect(
                x: 0,
                y: bounds.height - scrimHeight,
                width: bounds.width,
                height: scrimHeight
            )
        case .heroOverlay:
            scrimLayer.frame = bounds
        }
        CATransaction.commit()
    }

    private func applyHairlineBorder() {
        if showsHairlineBorder {
            layer.borderWidth = UIKitFeedLayoutMetrics.hairlineWidth
            layer.borderColor = UIColor.label
                .withAlphaComponent(UIKitFeedLayoutMetrics.hairlineAlpha)
                .resolvedColor(with: traitCollection)
                .cgColor
        } else {
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }
}

/// Shared `"owner [play.rectangle] views [timeAgo]"` metadata row for Hero and Row cards.
@MainActor
final class UIKitMetaLineView: UIView {
    private let stack = UIStackView()
    private let ownerLabel = UILabel()
    private let playIcon = UIImageView()
    private let viewsLabel = UILabel()
    private let viewsGroup = UIStackView()
    private let timeLabel = UILabel()

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
        stack.spacing = 8
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        ownerLabel.numberOfLines = 1
        ownerLabel.lineBreakMode = .byTruncatingTail
        ownerLabel.adjustsFontForContentSizeCategory = true
        ownerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        playIcon.image = UIImage(systemName: "play.rectangle")
        playIcon.contentMode = .scaleAspectFit
        playIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        playIcon.setContentHuggingPriority(.required, for: .horizontal)

        for label in [viewsLabel, timeLabel] {
            label.numberOfLines = 1
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        viewsGroup.axis = .horizontal
        viewsGroup.alignment = .center
        viewsGroup.spacing = 3
        viewsGroup.addArrangedSubview(playIcon)
        viewsGroup.addArrangedSubview(viewsLabel)
        viewsGroup.setContentCompressionResistancePriority(.required, for: .horizontal)
        viewsGroup.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(ownerLabel)
        stack.addArrangedSubview(viewsGroup)
        stack.addArrangedSubview(timeLabel)
    }

    func configure(
        ownerName: String,
        viewCount: Int,
        publishedAt: Int? = nil,
        font: UIFont,
        color: UIColor
    ) {
        let hasOwner = !ownerName.isEmpty
        ownerLabel.isHidden = !hasOwner
        ownerLabel.text = ownerName
        ownerLabel.font = font
        ownerLabel.textColor = color

        playIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: font,
            scale: .small
        )
        playIcon.tintColor = color

        viewsLabel.text = FormatUtils.viewCount(viewCount)
        viewsLabel.font = font
        viewsLabel.textColor = color

        if !hasOwner, let publishedAt, publishedAt > 0 {
            timeLabel.isHidden = false
            timeLabel.text = FormatUtils.timeAgo(from: publishedAt)
            timeLabel.font = font
            timeLabel.textColor = color
        } else {
            timeLabel.isHidden = true
        }
    }
}

/// Dark translucent pill / rounded badge used for video duration overlays.
@MainActor
final class UIKitDurationBadge: UIView {
    private let label = UILabel()
    private let isCapsule: Bool

    init(isCapsule: Bool = false, horizontalPadding: CGFloat = 5, verticalPadding: CGFloat = 2) {
        self.isCapsule = isCapsule
        super.init(frame: .zero)
        setup(horizontalPadding: horizontalPadding, verticalPadding: verticalPadding)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(horizontalPadding: CGFloat, verticalPadding: CGFloat) {
        backgroundColor = UIColor.black.withAlphaComponent(0.68)
        layer.cornerCurve = .continuous
        if !isCapsule {
            layer.cornerRadius = AppRadius.badge
        }
        isUserInteractionEnabled = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.numberOfLines = 1
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
        ])
    }

    func configure(duration: Int, font: UIFont) {
        guard duration > 0 else {
            isHidden = true
            return
        }
        configure(text: FormatUtils.duration(duration), font: font)
    }

    func configure(text: String?, font: UIFont) {
        guard let text, !text.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        label.text = text
        label.font = font
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isCapsule {
            layer.cornerRadius = bounds.height / 2
        }
    }
}
