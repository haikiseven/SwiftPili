import SwiftUI
import UIKit

@MainActor
final class UIKitDynamicSourceContentView: UIView {
    struct Actions {
        var onOpenPost: (() -> Void)?
        var onOpenProfile: ((Int) -> Void)?
        var onOpenVideo: ((VideoRouteTarget) -> Void)?
        var onOpenArticle: ((Int) -> Void)?
        var onOpenLiveRoom: ((Int) -> Void)?
        var onOpenURL: ((URL) -> Void)?
        var onImageTap: ((ImagePreviewItem) -> Void)?
    }

    private let stack = UIStackView()
    private let quotedAuthorButton = UIButton(type: .system)
    private let richTextView = UIKitDynamicRichTextView()
    private let opusTitleLabel = UILabel()
    private let opusBodyView = UIKitDynamicRichTextView()
    private let mediaCardView = UIKitDynamicMediaCardView()
    private let drawGridView = UIKitDynamicDrawGridView()
    private let readArticleButton = UIButton(type: .system)
    private let fallbackMajorLabel = UILabel()
    private var voteHostController: UIHostingController<VoteCardView>?
    private var hostedVoteID: Int?

    private var quotedAuthorMID: Int?
    private var articleCvid: Int?
    private var actions = Actions()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        quotedAuthorButton.contentHorizontalAlignment = .leading
        quotedAuthorButton.addTarget(self, action: #selector(handleQuotedAuthorTap), for: .touchUpInside)

        opusTitleLabel.numberOfLines = 2
        opusTitleLabel.textColor = .label
        opusTitleLabel.adjustsFontForContentSizeCategory = true

        readArticleButton.contentHorizontalAlignment = .leading
        readArticleButton.addTarget(self, action: #selector(handleReadArticleTap), for: .touchUpInside)

        fallbackMajorLabel.numberOfLines = 0
        fallbackMajorLabel.textColor = .secondaryLabel
        fallbackMajorLabel.adjustsFontForContentSizeCategory = true

        for view in [
            quotedAuthorButton, richTextView, opusTitleLabel, opusBodyView,
            mediaCardView, drawGridView, readArticleButton, fallbackMajorLabel,
        ] {
            view.isHidden = true
            stack.addArrangedSubview(view)
        }
    }

    func configure(
        owner: DynamicFeedResult.DynamicItem,
        quoted: Bool,
        expanded: Bool,
        availableWidth: CGFloat,
        actions: Actions
    ) {
        self.actions = actions
        resetArrangedVisibility()

        let traits = traitCollection
        let isA11y = traits.preferredContentSizeCategory.isAccessibilityCategory
        let openPost = (expanded || (quoted && actions.onOpenPost == nil)) ? nil : actions.onOpenPost
        let mediaTitleLimit: Int? = (expanded || openPost == nil || isA11y) ? nil : 2

        if quoted, let name = owner.modules?.moduleAuthor?.name, !name.isEmpty {
            configureQuotedAuthor(name: name, mid: owner.modules?.moduleAuthor?.mid, traits: traits)
        }

        let dynamic = owner.modules?.moduleDynamic
        let opusBody = Self.alternateOpusBody(owner)
        if opusBody == nil, let desc = dynamic?.desc,
           DynamicRichContent.hasContent(text: desc.text, nodes: desc.richTextNodes) {
            configureRichText(
                richTextView, text: desc.text, nodes: desc.richTextNodes, sourceID: owner.idStr,
                quoted: quoted, expanded: expanded, isSummary: false,
                width: availableWidth, openPost: openPost
            )
        }

        if let major = dynamic?.major {
            configureMajor(
                major, owner: owner, opusBody: opusBody, quoted: quoted, expanded: expanded,
                width: availableWidth, mediaTitleLimit: mediaTitleLimit, openPost: openPost
            )
        }
        configureAdditional(owner)
        isHidden = stack.arrangedSubviews.allSatisfy(\.isHidden)
    }

    func containsInteractivePoll(at view: UIView) -> Bool {
        guard let pollView = voteHostController?.view else { return false }
        return view.isDescendant(of: pollView)
    }

    func prepareForReuse() {
        actions = Actions()
        quotedAuthorMID = nil
        articleCvid = nil
        richTextView.prepareForReuse()
        opusBodyView.prepareForReuse()
        mediaCardView.prepareForReuse()
        drawGridView.prepareForReuse()
        removeVoteHost()
        resetArrangedVisibility()
    }

    @objc private func handleQuotedAuthorTap() {
        if let quotedAuthorMID { actions.onOpenProfile?(quotedAuthorMID) }
    }

    @objc private func handleReadArticleTap() {
        if let articleCvid { actions.onOpenArticle?(articleCvid) }
    }
}

private extension UIKitDynamicSourceContentView {
    func resetArrangedVisibility() {
        for view in [
            quotedAuthorButton, richTextView, opusTitleLabel, opusBodyView,
            mediaCardView, drawGridView, readArticleButton, fallbackMajorLabel,
        ] {
            view.isHidden = true
        }
    }

    func configureQuotedAuthor(name: String, mid: Int?, traits: UITraitCollection) {
        quotedAuthorMID = (mid ?? 0) > 0 ? mid : nil
        quotedAuthorButton.isHidden = false
        quotedAuthorButton.isEnabled = quotedAuthorMID != nil
        quotedAuthorButton.accessibilityLabel = quotedAuthorMID != nil
            ? String(format: String(localized: "View profile: %@"), name) : nil
        let font = UIKitFeedFont.systemFont(textStyle: .subheadline, weight: .semibold, traitCollection: traits)
        let accent = UIColor(AccentStore.shared.semanticAccent)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 4)
        config.attributedTitle = AttributedString(
            "@\(name)", attributes: AttributeContainer([.font: font, .foregroundColor: accent])
        )
        quotedAuthorButton.configuration = config
    }

    // swiftlint:disable:next function_parameter_count
    func configureRichText(
        _ target: UIKitDynamicRichTextView,
        text: String?,
        nodes: [DynamicRichContent.Node]?,
        sourceID: String?,
        quoted: Bool,
        expanded: Bool,
        isSummary: Bool,
        width: CGFloat,
        openPost: (() -> Void)?
    ) {
        target.isHidden = false
        target.onOpenPost = openPost
        target.onOpenURL = actions.onOpenURL
        target.onImageTap = actions.onImageTap
        let limit: Int? = (expanded || openPost == nil) ? nil : (quoted || isSummary ? 4 : 6)
        target.configure(.init(
            text: text,
            nodes: nodes,
            sourceID: sourceID,
            textStyle: .subheadline,
            lineSpacing: quoted ? 1.5 : 2.5,
            lineLimit: limit,
            detectTimestamps: true,
            availableWidth: width
        ))
    }

    // swiftlint:disable:next function_parameter_count
    func configureMajor(
        _ major: DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicMajor,
        owner: DynamicFeedResult.DynamicItem,
        opusBody: DynamicRichContent.Body?,
        quoted: Bool,
        expanded: Bool,
        width: CGFloat,
        mediaTitleLimit: Int?,
        openPost: (() -> Void)?
    ) {
        let ownerName = owner.modules?.moduleAuthor?.name
        if let archive = major.archive {
            configureArchive(
                archive, ownerName: ownerName, quoted: quoted, width: width, titleLineLimit: mediaTitleLimit
            )
        } else if let ugc = major.ugcSeason {
            configureArchive(
                .init(aid: ugc.aid.map(String.init), bvid: nil, title: ugc.title,
                      cover: ugc.cover, desc: ugc.desc, durationText: ugc.durationText),
                ownerName: ownerName, quoted: quoted, width: width, titleLineLimit: mediaTitleLimit
            )
        } else if let draw = major.draw, let items = draw.items, !items.isEmpty {
            configureDraw(items, width: width)
        } else if let pgc = major.pgc {
            mediaCardView.isHidden = false
            mediaCardView.onTap = nil
            let animeLabel = String(localized: "Anime")
            mediaCardView.configure(.init(
                title: pgc.title, cover: pgc.cover, kind: .labeled(animeLabel),
                subtitle: quoted ? animeLabel : nil, quoted: quoted,
                titleLineLimit: mediaTitleLimit, availableWidth: width
            ))
        } else if let common = major.common {
            mediaCardView.isHidden = false
            mediaCardView.onTap = nil
            let commonSubtitle = common.desc?.isEmpty == false ? common.desc : (quoted ? common.label : nil)
            mediaCardView.configure(.init(
                title: common.title, cover: common.cover, kind: .labeled(common.label),
                subtitle: commonSubtitle, quoted: quoted,
                titleLineLimit: mediaTitleLimit, availableWidth: width
            ))
        } else if let opus = major.opus {
            configureOpus(
                opus, owner: owner, opusBody: opusBody, quoted: quoted, expanded: expanded,
                width: width, openPost: openPost
            )
        } else if let article = major.article {
            configureArticle(
                article, cvid: owner.articleCvid, quoted: quoted, width: width, titleLineLimit: mediaTitleLimit
            )
        } else if let liveRcmd = major.liveRcmd, liveRcmd.content != nil {
            let parsed = liveRcmd.parsed
            mediaCardView.isHidden = false
            mediaCardView.configure(.init(
                title: parsed.title ?? String(localized: "Live"), cover: parsed.cover,
                kind: .live(areaName: parsed.areaName), subtitle: parsed.areaName, quoted: quoted,
                titleLineLimit: mediaTitleLimit, availableWidth: width
            ))
            mediaCardView.onTap = parsed.roomID.flatMap { roomID in
                roomID > 0 ? { [weak self] in self?.actions.onOpenLiveRoom?(roomID) } : nil
            }
        } else if let type = major.type, type != "MAJOR_TYPE_NONE" {
            fallbackMajorLabel.isHidden = false
            fallbackMajorLabel.text = type.replacingOccurrences(of: "MAJOR_TYPE_", with: "").capitalized
            fallbackMajorLabel.font = UIKitFeedFont.systemFont(textStyle: .footnote, traitCollection: traitCollection)
        }
    }

    func configureArchive(
        _ archive: DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicMajor.ArchiveInfo,
        ownerName: String?,
        quoted: Bool,
        width: CGFloat,
        titleLineLimit: Int?
    ) {
        mediaCardView.isHidden = false
        mediaCardView.configure(.init(
            title: archive.title, cover: archive.cover, kind: .video(duration: archive.durationText),
            subtitle: quoted ? String(localized: "Video") : nil, quoted: quoted,
            titleLineLimit: titleLineLimit, availableWidth: width
        ))
        let target = VideoRouteTarget.make(
            bvid: archive.bvid, aid: archive.aid.flatMap(Int.init), title: archive.title ?? "",
            coverURL: archive.cover ?? "", ownerName: ownerName ?? "",
            durationSeconds: FormatUtils.parseDurationSeconds(archive.durationText)
        )
        mediaCardView.onTap = target.map { routeTarget in
            { [weak self] in self?.actions.onOpenVideo?(routeTarget) }
        }
    }

    func configureArticle(
        _ article: DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicMajor.ArticleInfo,
        cvid: Int?,
        quoted: Bool,
        width: CGFloat,
        titleLineLimit: Int?
    ) {
        mediaCardView.isHidden = false
        let cover = article.covers?.first.flatMap { $0.isEmpty ? nil : $0 }
        let articleBadge = article.label ?? String(localized: "Article")
        let articleSubtitle = article.desc?.isEmpty == false ? article.desc : (quoted ? articleBadge : nil)
        mediaCardView.configure(.init(
            title: article.title,
            cover: cover,
            kind: cover != nil ? .labeled(articleBadge) : .live(areaName: article.desc),
            subtitle: articleSubtitle,
            quoted: quoted,
            titleLineLimit: titleLineLimit,
            availableWidth: width
        ))
        mediaCardView.onTap = cvid.flatMap { valid in
            valid > 0 ? { [weak self] in self?.actions.onOpenArticle?(valid) } : nil
        }
    }

    func configureDraw(
        _ items: [DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicMajor.DrawInfo.DrawItem],
        width: CGFloat
    ) {
        let media = items.compactMap { item -> UIKitDynamicDrawGridView.MediaItem? in
            guard let src = item.src, let url = URL(string: src.httpsURL) else { return nil }
            let size: CGSize? = if let itemWidth = item.width, let itemHeight = item.height,
                                   itemWidth > 0, itemHeight > 0 {
                CGSize(width: itemWidth, height: itemHeight)
            } else {
                nil
            }
            return UIKitDynamicDrawGridView.MediaItem(url: url, pixelSize: size)
        }
        guard !media.isEmpty else { return }
        drawGridView.isHidden = false
        drawGridView.onImageTap = actions.onImageTap
        drawGridView.configure(items: media, availableWidth: width)
    }

    // swiftlint:disable:next function_parameter_count
    func configureOpus(
        _ opus: DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicMajor.OpusInfo,
        owner: DynamicFeedResult.DynamicItem,
        opusBody: DynamicRichContent.Body?,
        quoted: Bool,
        expanded: Bool,
        width: CGFloat,
        openPost: (() -> Void)?
    ) {
        let traits = traitCollection
        if let title = opus.title, !title.isEmpty {
            opusTitleLabel.isHidden = false
            opusTitleLabel.text = title
            opusTitleLabel.font = UIKitFeedFont.systemFont(
                textStyle: expanded ? .headline : .body, weight: .medium, traitCollection: traits
            )
            let isA11y = traits.preferredContentSizeCategory.isAccessibilityCategory
            opusTitleLabel.numberOfLines = (expanded || openPost == nil || isA11y) ? 0 : 2
        }
        if let opusBody {
            configureRichText(
                opusBodyView, text: opusBody.text, nodes: opusBody.nodes, sourceID: owner.idStr,
                quoted: quoted, expanded: expanded, isSummary: true, width: width, openPost: openPost
            )
        } else if let summary = opus.summary,
                  DynamicRichContent.hasContent(text: summary.text, nodes: summary.richTextNodes) {
            configureRichText(
                opusBodyView, text: summary.text, nodes: summary.richTextNodes, sourceID: owner.idStr,
                quoted: quoted, expanded: expanded, isSummary: true, width: width, openPost: openPost
            )
        }
        let bodyNodes = opusBody.map { [$0.nodes ?? []] } ?? [
            owner.modules?.moduleDynamic?.desc?.richTextNodes ?? [], opus.summary?.richTextNodes ?? []
        ]
        if let pics = opus.pics, !pics.isEmpty, !DynamicRichContent.repeatsGallery(pics, bodies: bodyNodes) {
            let drawItems = pics.compactMap { pic in
                pic.url.map {
                    DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicMajor.DrawInfo.DrawItem(
                        src: $0, width: pic.width, height: pic.height
                    )
                }
            }
            if !drawItems.isEmpty { configureDraw(drawItems, width: width) }
        }
        if let cvid = owner.articleCvid, cvid > 0 {
            articleCvid = cvid
            readArticleButton.isHidden = false
            let accent = UIColor(AccentStore.shared.semanticAccent)
            let font = UIKitFeedFont.systemFont(textStyle: .footnote, weight: .medium, traitCollection: traits)
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: "doc.richtext")
            config.imagePadding = 6
            config.baseForegroundColor = accent
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 12)
            config.attributedTitle = AttributedString(
                String(localized: "Read Article"),
                attributes: AttributeContainer([.font: font, .foregroundColor: accent])
            )
            readArticleButton.configuration = config
        }
    }

    func configureAdditional(_ owner: DynamicFeedResult.DynamicItem) {
        guard let additional = owner.modules?.moduleDynamic?.additional else {
            removeVoteHost()
            return
        }
        if let vote = additional.vote, let voteId = vote.voteId {
            if hostedVoteID == voteId, voteHostController != nil { return }
            removeVoteHost()
            let voteView = VoteCardView(voteId: voteId, initialTitle: vote.desc, initialJoinNum: vote.joinNum)
            let host = UIHostingController(rootView: voteView)
            host.sizingOptions = [.intrinsicContentSize]
            host.view.backgroundColor = .clear
            voteHostController = host
            hostedVoteID = voteId
            stack.addArrangedSubview(host.view)
        } else {
            removeVoteHost()
            if let type = additional.type, type != "ADDITIONAL_TYPE_NONE" {
                DynamicCardView.logUnhandledAdditional(type, id: owner.idStr ?? "?")
            }
        }
    }

    func removeVoteHost() {
        guard let host = voteHostController else { return }
        stack.removeArrangedSubview(host.view)
        host.view.removeFromSuperview()
        voteHostController = nil
        hostedVoteID = nil
    }

    static func alternateOpusBody(_ owner: DynamicFeedResult.DynamicItem) -> DynamicRichContent.Body? {
        guard let dynamic = owner.modules?.moduleDynamic,
              let desc = dynamic.desc, let summary = dynamic.major?.opus?.summary else { return nil }
        return DynamicRichContent.alternateBody(
            firstText: desc.text, firstNodes: desc.richTextNodes,
            secondText: summary.text, secondNodes: summary.richTextNodes
        )
    }
}
