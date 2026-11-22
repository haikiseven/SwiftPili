import SwiftUI
import UIKit

/// Gold / Silver / Bronze / numbered capsule rank badge matching `RankingMedalBadge`.
@MainActor
final class UIKitRankBadgeView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let stack = UIStackView()
    private let crownIcon = UIImageView(image: UIImage(systemName: "crown.fill"))
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
        layer.borderWidth = UIKitFeedLayoutMetrics.hairlineWidth
        layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor

        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradientLayer, at: 0)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])

        crownIcon.contentMode = .scaleAspectFit
        crownIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        crownIcon.setContentHuggingPriority(.required, for: .horizontal)

        label.numberOfLines = 1
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(crownIcon)
        stack.addArrangedSubview(label)
    }

    func configure(rank: Int, traitCollection: UITraitCollection) {
        let colors: [UIColor] = switch rank {
        case 1:
            [
                UIColor(red: 1.00, green: 0.84, blue: 0.25, alpha: 1),
                UIColor(red: 0.86, green: 0.55, blue: 0.08, alpha: 1),
            ]
        case 2:
            [
                UIColor(red: 0.88, green: 0.91, blue: 0.96, alpha: 1),
                UIColor(red: 0.55, green: 0.61, blue: 0.72, alpha: 1),
            ]
        case 3:
            [
                UIColor(red: 0.93, green: 0.66, blue: 0.44, alpha: 1),
                UIColor(red: 0.68, green: 0.39, blue: 0.20, alpha: 1),
            ]
        default:
            [
                UIColor.black.withAlphaComponent(0.68),
                UIColor.black.withAlphaComponent(0.68),
            ]
        }
        gradientLayer.colors = colors.map(\.cgColor)

        let textColor: UIColor = rank <= 2 ? UIColor.black.withAlphaComponent(0.88) : .white
        crownIcon.isHidden = rank != 1
        crownIcon.tintColor = textColor
        crownIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: UIKitFeedFont.systemFont(textStyle: .caption2, traitCollection: traitCollection)
        )

        label.text = rank <= 3 ? "TOP \(rank)" : "#\(rank)"
        label.textColor = textColor
        label.font = UIKitFeedFont.font(
            for: .overlayBadge,
            weight: .bold,
            monospacedDigit: true,
            traitCollection: traitCollection
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        layer.cornerRadius = bounds.height / 2
        gradientLayer.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }
}

/// Overlay pill badge for live room status (LIVE/ROUND/OFFLINE), eye online count,
/// or poster tags.
@MainActor
final class UIKitMediaBadgeView: UIView {
    private let stack = UIStackView()
    private let dotView = UIView()
    private let iconView = UIImageView()
    private let label = UILabel()

    init(horizontalPadding: CGFloat = 5, verticalPadding: CGFloat = 2) {
        super.init(frame: .zero)
        setup(horizontalPadding: horizontalPadding, verticalPadding: verticalPadding)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(horizontalPadding: CGFloat, verticalPadding: CGFloat) {
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous
        layer.cornerRadius = AppRadius.badge

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
        ])

        dotView.backgroundColor = .white
        dotView.layer.cornerRadius = 2.5
        dotView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 5),
            dotView.heightAnchor.constraint(equalToConstant: 5),
        ])

        iconView.image = UIImage(systemName: "eye")
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        label.numberOfLines = 1
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(dotView)
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(label)
    }

    func configureOnlineCount(_ text: String, traitCollection: UITraitCollection) {
        guard !text.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        dotView.isHidden = true
        iconView.isHidden = false
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            font: UIKitFeedFont.systemFont(textStyle: .caption2, traitCollection: traitCollection)
        )
        label.text = text
        label.textColor = .white
        label.font = UIKitFeedFont.font(
            for: .overlayBadge,
            weight: .medium,
            monospacedDigit: true,
            traitCollection: traitCollection
        )
        backgroundColor = UIColor.black.withAlphaComponent(0.72)
    }

    func configureLiveState(_ state: LiveRoomPlaybackState, traitCollection: UITraitCollection) {
        isHidden = false
        dotView.isHidden = state != .live
        iconView.isHidden = true
        label.text = state.listBadgeText
        label.textColor = .white
        label.font = UIKitFeedFont.font(
            for: .overlayBadge,
            weight: .bold,
            traitCollection: traitCollection
        )
        backgroundColor = state == .live ? .systemRed : UIColor.black.withAlphaComponent(0.72)
    }

    func configurePill(
        text: String?,
        backgroundColor: UIColor,
        textColor: UIColor = .white,
        traitCollection: UITraitCollection
    ) {
        guard let text, !text.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        dotView.isHidden = true
        iconView.isHidden = true
        label.text = text
        label.textColor = textColor
        label.font = UIKitFeedFont.font(for: .overlayBadge, traitCollection: traitCollection)
        self.backgroundColor = backgroundColor
    }
}

/// 3pt bottom-edge watched progress bar matching `CoverWatchProgressBar`.
@MainActor
final class UIKitWatchProgressBar: UIView {
    private let fillLayer = CALayer()
    private var progress: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = UIColor.white.withAlphaComponent(0.30)
        layer.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(progress: Double?) {
        guard let progress, progress.isFinite else {
            isHidden = true
            self.progress = 0
            return
        }
        isHidden = false
        self.progress = min(max(progress, 0), 1)
        fillLayer.backgroundColor = UIColor(AccentStore.shared.semanticAccent).cgColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width * progress,
            height: bounds.height
        )
        CATransaction.commit()
    }
}
