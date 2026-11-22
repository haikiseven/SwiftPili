import SwiftUI
import UIKit

enum MineFeedFooterState: Equatable {
    case none
    case loading
    case error(message: String, retryTitle: String)
    case more(title: String)
}

enum MineRowID: Hashable, Sendable {
    case int(Int)
    case string(String)
}

struct MineLibraryRowItem: Identifiable, Equatable {
    let id: MineRowID
    let title: String
    let sources: VideoCoverSources
    let duration: Int
    let subtitle: String?
    let footer: UIKitRowVideoCell.FooterMode
    let watchProgress: Double?
    let isSelectable: Bool
    let hasTrailingMenu: Bool
    let trailingMenuAccessibilityLabel: String?
    let isTrailingMenuEnabled: Bool
    let menuRevision: Int

    init(
        id: MineRowID,
        title: String,
        sources: VideoCoverSources,
        duration: Int,
        subtitle: String?,
        footer: UIKitRowVideoCell.FooterMode = .none,
        watchProgress: Double? = nil,
        isSelectable: Bool = true,
        hasTrailingMenu: Bool = false,
        trailingMenuAccessibilityLabel: String? = nil,
        isTrailingMenuEnabled: Bool = true,
        menuRevision: Int = 0
    ) {
        self.id = id
        self.title = title
        self.sources = sources
        self.duration = duration
        self.subtitle = subtitle
        self.footer = footer
        self.watchProgress = watchProgress
        self.isSelectable = isSelectable
        self.hasTrailingMenu = hasTrailingMenu
        self.trailingMenuAccessibilityLabel = trailingMenuAccessibilityLabel
        self.isTrailingMenuEnabled = isTrailingMenuEnabled
        self.menuRevision = menuRevision
    }
}

@MainActor
struct MineLibraryRowFeedConfig {
    let items: [MineLibraryRowItem]
    let headerTitle: String?
    let placeholderCount: Int
    let placeholderLabel: String
    let footerState: MineFeedFooterState
    let coverPresentation: CoverPresentation
    let onNearEndAppear: (() -> Void)?
    let onFooterAction: (() -> Void)?
    let onSelectItem: (MineRowID) -> Void
    let makeTrailingMenu: ((MineRowID, UIView?) -> UIMenu?)?
    let makeContextMenu: ((MineRowID) -> UIMenu?)?
}

struct MineLibraryRowFeedView: View {
    let items: [MineLibraryRowItem]
    var headerTitle: String?
    var placeholderCount: Int = 0
    var placeholderLabel: String = ""
    var footerState: MineFeedFooterState = .none
    var onRefresh: (@MainActor () async -> Bool)?
    var onNearEndAppear: (() -> Void)?
    var onFooterAction: (() -> Void)?
    let onSelectItem: (MineRowID) -> Void
    var makeTrailingMenu: ((MineRowID, UIView?) -> UIMenu?)?
    var makeContextMenu: ((MineRowID) -> UIMenu?)?

    var body: some View {
        let coverPresentation = CoverPresentationStore.shared.presentation
        let config = MineLibraryRowFeedConfig(
            items: items,
            headerTitle: headerTitle,
            placeholderCount: placeholderCount,
            placeholderLabel: placeholderLabel,
            footerState: footerState,
            coverPresentation: coverPresentation,
            onNearEndAppear: onNearEndAppear,
            onFooterAction: onFooterAction,
            onSelectItem: onSelectItem,
            makeTrailingMenu: makeTrailingMenu,
            makeContextMenu: makeContextMenu
        )
        UIKitCollectionHost(
            onRefresh: onRefresh,
            makeController: { MineLibraryRowFeedController() },
            updateController: { controller in controller.update(config) }
        )
    }
}

@MainActor
final class MineFeedFooterView: UICollectionReusableView {
    private let stack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])

        spinner.hidesWhenStopped = true

        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.textColor = .secondaryLabel
        messageLabel.adjustsFontForContentSizeCategory = true

        actionButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(actionButton)
    }

    func configure(state: MineFeedFooterState, onAction: (() -> Void)?) {
        self.onAction = onAction
        switch state {
        case .none:
            spinner.stopAnimating()
            messageLabel.isHidden = true
            actionButton.isHidden = true
        case .loading:
            spinner.startAnimating()
            messageLabel.isHidden = true
            actionButton.isHidden = true
        case .error(let message, let retryTitle):
            spinner.stopAnimating()
            messageLabel.isHidden = message.isEmpty
            messageLabel.text = message
            messageLabel.font = UIKitFeedFont.systemFont(textStyle: .caption, traitCollection: traitCollection)
            actionButton.isHidden = false
            var config = UIButton.Configuration.borderedProminent()
            config.title = retryTitle
            actionButton.configuration = config
        case .more(let title):
            spinner.stopAnimating()
            messageLabel.isHidden = true
            actionButton.isHidden = false
            var config = UIButton.Configuration.plain()
            config.title = title
            actionButton.configuration = config
        }
    }

    @objc private func handleTap() {
        onAction?()
    }
}
