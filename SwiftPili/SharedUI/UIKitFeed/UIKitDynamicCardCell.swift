import UIKit

/// Shared pure UIKit dynamic/moment card cell for `DynamicsView` and
/// `UserSpaceFeedCollectionView`.
@MainActor
final class UIKitDynamicCardCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    struct Actions {
        var onOpenPost: (() -> Void)?
        var onOpenQuotedPost: ((String) -> Void)?
        var onOpenProfile: ((Int) -> Void)?
        var onOpenVideo: ((VideoRouteTarget) -> Void)?
        var onOpenArticle: ((Int) -> Void)?
        var onOpenLiveRoom: ((Int) -> Void)?
        var onOpenURL: ((URL) -> Void)?
        var onImageTap: ((ImagePreviewItem) -> Void)?
        var onRepost: (() -> Void)?
        var onComment: (() -> Void)?
        var onLike: (() -> Void)?
    }

    struct Model {
        let item: DynamicFeedResult.DynamicItem
        var interactionStore: MomentInteractionStore?
        var fallbackLikeState: (liked: Bool, count: Int) = (false, 0)
        var availableWidth: CGFloat?
        var expanded: Bool = false
        var showsCardBackground: Bool = true
        var actions: Actions = .init()
    }

    private final class QuotedSlotView: UIView, UIGestureRecognizerDelegate {
        let contentView = UIKitDynamicSourceContentView()
        var onTapPost: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: topAnchor),
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.delegate = self
            addGestureRecognizer(tap)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard onTapPost != nil, let touchView = touch.view else { return false }
            if contentView.containsInteractivePoll(at: touchView) { return false }
            var current: UIView? = touchView
            while let view = current, view !== self {
                if view is UIControl { return false }
                if let rich = view as? UIKitDynamicRichTextView,
                   rich.onOpenPost != nil || rich.isLinkTouch(touch) { return false }
                if let media = view as? UIKitDynamicMediaCardView, media.onTap != nil { return false }
                if view is UIKitDynamicDrawGridView { return false }
                current = view.superview
            }
            return true
        }

        @objc private func handleTap() { onTapPost?() }
    }

    private let platter = UIView()
    private let rootStack = UIStackView()
    private let authorRow = UIKitDynamicAuthorRowView()
    private let mainSourceView = UIKitDynamicSourceContentView()
    private let quoteContainer = UIView()
    private let quoteAccentBar = UIView()
    private let quoteStack = UIStackView()
    private var quotedSlots: [QuotedSlotView] = []
    private let actionBar = UIKitDynamicActionBarView()

    private var onOpenPost: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        platter.translatesAutoresizingMaskIntoConstraints = false
        platter.layer.cornerRadius = AppRadius.panel
        platter.layer.cornerCurve = .continuous
        contentView.addSubview(platter)

        let platterTap = UITapGestureRecognizer(target: self, action: #selector(handlePlatterTap))
        platterTap.delegate = self
        platter.addGestureRecognizer(platterTap)

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 10
        platter.addSubview(rootStack)

        quoteContainer.backgroundColor = .quaternarySystemFill
        quoteContainer.layer.cornerRadius = AppRadius.control
        quoteContainer.layer.cornerCurve = .continuous
        quoteContainer.clipsToBounds = true
        quoteAccentBar.translatesAutoresizingMaskIntoConstraints = false
        quoteAccentBar.isUserInteractionEnabled = false
        quoteContainer.addSubview(quoteAccentBar)
        quoteStack.translatesAutoresizingMaskIntoConstraints = false
        quoteStack.axis = .vertical
        quoteStack.alignment = .fill
        quoteStack.spacing = 10
        quoteContainer.addSubview(quoteStack)

        [authorRow, mainSourceView, quoteContainer, actionBar].forEach {
            rootStack.addArrangedSubview($0)
        }
        rootStack.setCustomSpacing(8, after: authorRow)

        NSLayoutConstraint.activate([
            platter.topAnchor.constraint(equalTo: contentView.topAnchor),
            platter.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            platter.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            platter.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rootStack.topAnchor.constraint(equalTo: platter.topAnchor, constant: 14),
            rootStack.leadingAnchor.constraint(equalTo: platter.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: platter.trailingAnchor, constant: -16),
            rootStack.bottomAnchor.constraint(equalTo: platter.bottomAnchor, constant: -6),
            quoteAccentBar.topAnchor.constraint(equalTo: quoteContainer.topAnchor),
            quoteAccentBar.leadingAnchor.constraint(equalTo: quoteContainer.leadingAnchor),
            quoteAccentBar.bottomAnchor.constraint(equalTo: quoteContainer.bottomAnchor),
            quoteAccentBar.widthAnchor.constraint(equalToConstant: 2.5),
            quoteStack.topAnchor.constraint(equalTo: quoteContainer.topAnchor, constant: 12),
            quoteStack.leadingAnchor.constraint(equalTo: quoteContainer.leadingAnchor, constant: 14),
            quoteStack.trailingAnchor.constraint(equalTo: quoteContainer.trailingAnchor, constant: -12),
            quoteStack.bottomAnchor.constraint(equalTo: quoteContainer.bottomAnchor, constant: -12),
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: UIKitDynamicCardCell, _) in
            self.applyPlatterStyle()
        }
        applyPlatterStyle()
    }

    func configure(_ model: Model) {
        let item = model.item
        let hasPostID = item.idStr.map { !$0.isEmpty } ?? false
        let resolvedOpenPost: (() -> Void)? = (!model.expanded && hasPostID) ? model.actions.onOpenPost : nil
        onOpenPost = resolvedOpenPost

        platter.backgroundColor = model.showsCardBackground ? .secondarySystemGroupedBackground : .clear
        applyPlatterStyle()

        let seedWidth = model.availableWidth
            ?? (bounds.width > 1 ? bounds.width : FeedWidth.fullContainerSeed(cappedTo: ReadableWidth.feed))
        let innerWidth = max(160, seedWidth - 32)

        if let author = item.modules?.moduleAuthor {
            authorRow.isHidden = false
            authorRow.onOpenProfile = model.actions.onOpenProfile
            authorRow.configure(author: author, contentType: Self.contentType(for: item))
        } else {
            authorRow.isHidden = true
            authorRow.prepareForReuse()
        }

        mainSourceView.configure(
            owner: item,
            quoted: false,
            expanded: model.expanded,
            availableWidth: innerWidth,
            actions: makeSourceActions(from: model.actions, postAction: resolvedOpenPost)
        )

        configureQuoteChain(item: item, model: model, innerWidth: innerWidth)

        let showsActions = model.interactionStore != nil || model.actions.onLike != nil
            || model.actions.onComment != nil || model.actions.onRepost != nil
        actionBar.isHidden = !showsActions
        if showsActions {
            actionBar.configure(
                item: item,
                interactionStore: model.interactionStore,
                fallbackLikeState: model.fallbackLikeState,
                onRepost: model.actions.onRepost,
                onComment: model.actions.onComment,
                onLike: model.actions.onLike
            )
        } else {
            actionBar.prepareForReuse()
        }

        if let resolvedOpenPost {
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "View Post")) { _ in
                    resolvedOpenPost()
                    return true
                },
            ]
        } else {
            accessibilityCustomActions = nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onOpenPost = nil
        accessibilityCustomActions = nil
        authorRow.prepareForReuse()
        mainSourceView.prepareForReuse()
        for slot in quotedSlots {
            slot.contentView.prepareForReuse()
            slot.onTapPost = nil
            slot.isHidden = true
        }
        quoteContainer.isHidden = true
        actionBar.prepareForReuse()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard onOpenPost != nil, let touchView = touch.view else { return false }
        if mainSourceView.containsInteractivePoll(at: touchView) { return false }
        var current: UIView? = touchView
        while let view = current, view !== platter {
            if view is UIControl { return false }
            if let rich = view as? UIKitDynamicRichTextView,
               rich.onOpenPost != nil || rich.isLinkTouch(touch) { return false }
            if let media = view as? UIKitDynamicMediaCardView, media.onTap != nil { return false }
            if view is UIKitDynamicDrawGridView { return false }
            if let slot = view as? QuotedSlotView {
                if slot.contentView.containsInteractivePoll(at: touchView) { return false }
                if slot.onTapPost != nil { return false }
            }
            current = view.superview
        }
        return true
    }

    @objc private func handlePlatterTap() { onOpenPost?() }
}

private extension UIKitDynamicCardCell {
    func applyPlatterStyle() {
        let traits = traitCollection
        platter.layer.borderWidth = 0
        platter.layer.borderColor = nil
        quoteContainer.layer.borderWidth = 0
        quoteContainer.layer.borderColor = nil
        quoteAccentBar.backgroundColor = UIColor(AccentStore.shared.semanticAccent)
            .withAlphaComponent(0.35)
            .resolvedColor(with: traits)
    }

    func makeSourceActions(
        from actions: Actions,
        postAction: (() -> Void)?
    ) -> UIKitDynamicSourceContentView.Actions {
        .init(
            onOpenPost: postAction,
            onOpenProfile: actions.onOpenProfile,
            onOpenVideo: actions.onOpenVideo,
            onOpenArticle: actions.onOpenArticle,
            onOpenLiveRoom: actions.onOpenLiveRoom,
            onOpenURL: actions.onOpenURL,
            onImageTap: actions.onImageTap
        )
    }

    func configureQuoteChain(item: DynamicFeedResult.DynamicItem, model: Model, innerWidth: CGFloat) {
        let sources = Self.quotedSources(for: item)
        quoteContainer.isHidden = sources.isEmpty
        guard !sources.isEmpty else {
            quotedSlots.forEach {
                $0.contentView.prepareForReuse()
                $0.onTapPost = nil
                $0.isHidden = true
            }
            return
        }

        while quotedSlots.count < sources.count {
            let slot = QuotedSlotView()
            quoteStack.addArrangedSubview(slot)
            quotedSlots.append(slot)
        }

        let quotedWidth = max(160, innerWidth - 26)
        for (index, slot) in quotedSlots.enumerated() {
            guard index < sources.count else {
                slot.contentView.prepareForReuse()
                slot.onTapPost = nil
                slot.isHidden = true
                continue
            }
            let source = sources[index]
            let quotedAction: (() -> Void)? = if let qid = source.idStr, !qid.isEmpty, qid != item.idStr,
                                                  let handler = model.actions.onOpenQuotedPost {
                { handler(qid) }
            } else {
                nil
            }
            slot.isHidden = false
            slot.onTapPost = quotedAction
            slot.contentView.configure(
                owner: source,
                quoted: true,
                expanded: model.expanded,
                availableWidth: quotedWidth,
                actions: makeSourceActions(from: model.actions, postAction: quotedAction)
            )
        }
    }

    static func quotedSources(for item: DynamicFeedResult.DynamicItem) -> [DynamicFeedResult.DynamicItem] {
        var sources: [DynamicFeedResult.DynamicItem] = []
        var next = item.orig?.item
        while let source = next {
            sources.append(source)
            next = source.orig?.item
        }
        return sources
    }

    static func contentType(for item: DynamicFeedResult.DynamicItem) -> String? {
        if item.orig != nil { return String(localized: "Repost") }
        guard let major = item.modules?.moduleDynamic?.major else { return nil }
        if major.archive != nil || major.ugcSeason != nil { return String(localized: "Video") }
        if major.article != nil || (item.articleCvid ?? 0) > 0 { return String(localized: "Article") }
        if major.pgc != nil { return String(localized: "Anime") }
        if major.liveRcmd != nil { return String(localized: "Live") }
        if major.draw?.items?.isEmpty == false || major.opus?.pics?.isEmpty == false {
            return String(localized: "Photos")
        }
        return nil
    }
}
