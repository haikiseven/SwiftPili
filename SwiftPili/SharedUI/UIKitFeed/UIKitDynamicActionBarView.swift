import SwiftUI
import UIKit

@MainActor
final class UIKitDynamicActionBarView: UIView {
    private let stack = UIStackView()
    private let repostButton = UIButton(type: .custom)
    private let commentButton = UIButton(type: .custom)
    private let likeButton = UIButton(type: .custom)

    private var item: DynamicFeedResult.DynamicItem?
    private weak var interactionStore: MomentInteractionStore?
    private var fallbackLikeState: (liked: Bool, count: Int) = (false, 0)
    private var lastRenderedLike: (liked: Bool, count: Int)?
    private var observationToken = UUID()
    private var onRepost: (() -> Void)?
    private var onComment: (() -> Void)?
    private var onLike: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for button in [repostButton, commentButton, likeButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            stack.addArrangedSubview(button)
        }
        repostButton.addTarget(self, action: #selector(handleRepost), for: .touchUpInside)
        commentButton.addTarget(self, action: #selector(handleComment), for: .touchUpInside)
        likeButton.addTarget(self, action: #selector(handleLike), for: .touchUpInside)

        registerForTraitChanges([
            UITraitPreferredContentSizeCategory.self,
            UITraitUserInterfaceStyle.self,
        ]) { (self: UIKitDynamicActionBarView, _) in
            self.refreshAllButtons()
        }
    }

    func configure(
        item: DynamicFeedResult.DynamicItem,
        interactionStore: MomentInteractionStore?,
        fallbackLikeState: (liked: Bool, count: Int) = (false, 0),
        onRepost: (() -> Void)?,
        onComment: (() -> Void)?,
        onLike: (() -> Void)?
    ) {
        self.item = item
        self.interactionStore = interactionStore
        self.fallbackLikeState = fallbackLikeState
        self.onRepost = onRepost
        self.onComment = onComment
        self.onLike = onLike
        self.observationToken = UUID()
        self.lastRenderedLike = nil

        refreshAllButtons()
        if interactionStore != nil {
            trackLikeState(token: observationToken)
        }
    }

    func prepareForReuse() {
        observationToken = UUID()
        item = nil
        interactionStore = nil
        lastRenderedLike = nil
        onRepost = nil
        onComment = nil
        onLike = nil
    }

    private struct ButtonAppearance {
        let icon: String
        let title: String
        let count: Int
        let isActive: Bool
        let isEnabled: Bool
    }

    private func refreshAllButtons() {
        guard let item else { return }
        let stat = item.modules?.moduleStat
        configureButton(repostButton, appearance: .init(
            icon: "arrow.2.squarepath", title: String(localized: "Repost"),
            count: stat?.forward?.count ?? 0, isActive: false, isEnabled: onRepost != nil
        ))
        configureButton(commentButton, appearance: .init(
            icon: "bubble.right", title: String(localized: "Comment"),
            count: stat?.comment?.count ?? 0, isActive: false, isEnabled: onComment != nil
        ))
        refreshLikeButton()
    }

    private func refreshLikeButton() {
        guard let item else { return }
        let state = interactionStore?.likeState(for: item) ?? fallbackLikeState
        lastRenderedLike = state
        configureButton(likeButton, appearance: .init(
            icon: state.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
            title: String(localized: "Like"),
            count: state.count,
            isActive: state.liked,
            isEnabled: onLike != nil || interactionStore != nil
        ))
    }

    private func trackLikeState(token: UUID) {
        guard let item, let store = interactionStore, observationToken == token else { return }
        withObservationTracking {
            let state = store.likeState(for: item)
            if lastRenderedLike?.liked != state.liked || lastRenderedLike?.count != state.count {
                refreshLikeButton()
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationToken == token else { return }
                self.trackLikeState(token: token)
            }
        }
    }

    private func configureButton(_ button: UIButton, appearance: ButtonAppearance) {
        let traits = traitCollection
        let accent = UIColor(AccentStore.shared.semanticAccent)
        let foreground: UIColor = appearance.isActive
            ? accent
            : UIColor.label.withAlphaComponent(0.78).resolvedColor(with: traits)
        let background: UIColor = appearance.isActive
            ? accent.withAlphaComponent(0.14).resolvedColor(with: traits)
            : UIColor.quaternarySystemFill.resolvedColor(with: traits)
        let font = UIKitFeedFont.systemFont(
            textStyle: .subheadline, weight: .medium, monospacedDigit: true, traitCollection: traits
        )

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = background
        config.baseForegroundColor = foreground
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        config.image = UIImage(systemName: appearance.icon)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font)
        config.imagePadding = 5
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        let text = appearance.count >= 1 ? FormatUtils.viewCount(appearance.count) : appearance.title
        config.attributedTitle = AttributedString(text, attributes: AttributeContainer([.font: font]))
        button.configuration = config
        button.isEnabled = appearance.isEnabled
        button.accessibilityLabel = appearance.title
        button.accessibilityValue = FormatUtils.viewCount(appearance.count)
        if appearance.isActive {
            button.accessibilityTraits.insert(.selected)
        } else {
            button.accessibilityTraits.remove(.selected)
        }
    }

    @objc private func handleRepost() { onRepost?() }
    @objc private func handleComment() { onComment?() }

    @objc private func handleLike() {
        let wasLiked = lastRenderedLike?.liked ?? false
        if !wasLiked {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        if let onLike {
            onLike()
        } else if let item, let store = interactionStore {
            Task { @MainActor in await store.toggleLike(for: item) }
        }
    }
}
