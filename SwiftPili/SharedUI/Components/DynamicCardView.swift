import SwiftUI

struct DynamicCardView: View {
    let item: DynamicFeedResult.DynamicItem
    var likeState: (liked: Bool, count: Int) = (false, 0)
    var interactionStore: MomentInteractionStore?
    var expanded = false
    var showsCardBackground = true
    var onOpenPost: (() -> Void)?
    var onImageTap: ((ImagePreviewItem) -> Void)?
    var onLike: (() -> Void)?
    var onComment: (() -> Void)?
    var onRepost: (() -> Void)?
    typealias Major = DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicMajor

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    private var innerColumnWidth: CGFloat? {
        envColumnWidth.flatMap { $0 > 32 ? $0 - 32 : nil }
    }

    private var postAction: (() -> Void)? {
        guard !expanded, let id = item.idStr, !id.isEmpty else { return nil }
        return onOpenPost
    }

    var body: some View {
        if let postAction {
            cardContent
                .contentShape(Rectangle())
                .onTapGesture(perform: postAction)
                .accessibilityAction(named: Text("View Post"), postAction)
        } else {
            cardContent
        }
    }

    private var mediaTitleLimit: Int? {
        postAction == nil || dynamicTypeSize.isAccessibilitySize ? nil : 2
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            authorRow
            VStack(alignment: .leading, spacing: 10) {
                postBodyAndActions
            }
        }
        .rowCardColumnWidth(innerColumnWidth)
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .contentLinks(presentsFeedback: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if showsCardBackground {
                RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                    .fill(AppFill.card)
            }
        }
    }

    @ViewBuilder
    private var postBodyAndActions: some View {
        sourceContent(item)
        if !quotedSources.isEmpty { quoteChain }
        if interactionStore != nil || onLike != nil || onComment != nil || onRepost != nil {
            DynamicActionBar(
                item: item,
                fallbackLikeState: likeState,
                interactionStore: interactionStore,
                onRepost: onRepost,
                onComment: onComment,
                onLike: onLike
            )
        }
    }

    @ViewBuilder
    private func sourceContent(
        _ owner: DynamicFeedResult.DynamicItem, quoted: Bool = false,
        openPost: (() -> Void)? = nil
    ) -> some View {
        let dynamic = owner.modules?.moduleDynamic
        let opusBody = alternateOpusBody(owner)
        if opusBody == nil, let desc = dynamic?.desc,
           DynamicRichBodyView.hasContent(text: desc.text, nodes: desc.richTextNodes) {
            richBody(text: desc.text, nodes: desc.richTextNodes, owner: owner, quoted: quoted, openPost: openPost)
        }
        if let major = dynamic?.major {
            majorContent(major, owner: owner, opusBody: opusBody, quoted: quoted, openPost: openPost)
        }
        additionalContent(owner)
    }

    private func richBody(
        text: String?, nodes: [DynamicRichBodyView.Node]?,
        owner: DynamicFeedResult.DynamicItem, quoted: Bool, isSummary: Bool = false,
        openPost: (() -> Void)? = nil
    ) -> some View {
        let action = quoted ? openPost : postAction
        return DynamicRichBodyView(
            text: text, nodes: nodes, sourceID: owner.idStr,
            font: .subheadline, lineSpacing: quoted ? 1.5 : 2.5,
            lineLimit: expanded || action == nil ? nil : (quoted || isSummary ? 4 : 6),
            onOpenPost: action, onImageTap: onImageTap
        )
    }

    @ViewBuilder
    private var authorRow: some View {
        if let author = item.modules?.moduleAuthor {
            HStack(alignment: .center, spacing: 8) {
                profileTarget(mid: author.mid, name: author.name) {
                    HStack(alignment: .center, spacing: 10) {
                        if let face = author.face {
                            AvatarImage(urlString: face, size: 38)
                                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(author.name ?? "")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            authorMetaRow(for: author)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func authorMetaRow(
        for author: DynamicFeedResult.DynamicItem.DynamicModules.ModuleAuthor
    ) -> some View {
        let timeText = author.pubTs.map { FormatUtils.timeAgo(from: $0) }
        let hasTime = timeText?.isEmpty == false
        let hasType = contentType?.isEmpty == false
        let lineLimit = dynamicTypeSize.isAccessibilitySize ? 2 : 1
        if hasTime || hasType {
            HStack(spacing: 8) {
                if let timeText, !timeText.isEmpty {
                    Text(verbatim: timeText)
                        .foregroundStyle(.secondary)
                        .lineLimit(lineLimit)
                }
                if let contentType, !contentType.isEmpty {
                    Text(verbatim: contentType)
                        .foregroundStyle(.tertiary)
                        .lineLimit(lineLimit)
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func profileTarget<Content: View>(
        mid: Int?, name: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        if let mid, mid > 0 {
            Button {
                coordinator.navigate(to: .userSpace(mid))
            } label: {
                content()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(format: String(localized: "View profile: %@"), name ?? "")))
        } else {
            content()
        }
    }

    @ViewBuilder
    private func majorContent(
        _ major: Major, owner: DynamicFeedResult.DynamicItem,
        opusBody: DynamicRichContent.Body?,
        quoted: Bool = false,
        openPost: (() -> Void)? = nil
    ) -> some View {
        if let archive = major.archive {
            archiveCard(archive, ownerName: owner.modules?.moduleAuthor?.name, quoted: quoted)
        } else if let ugc = major.ugcSeason {
            archiveCard(Major.ArchiveInfo(
                aid: ugc.aid.map(String.init), bvid: nil, title: ugc.title,
                cover: ugc.cover, desc: ugc.desc, durationText: ugc.durationText
            ), ownerName: owner.modules?.moduleAuthor?.name, quoted: quoted)
        } else if let draw = major.draw, let items = draw.items, !items.isEmpty {
            drawGrid(items, sourceID: owner.idStr)
        } else if let pgc = major.pgc {
            let animeLabel = String(localized: "Anime")
            coverCard(
                title: pgc.title, cover: pgc.cover, badge: animeLabel,
                subtitle: quoted ? animeLabel : nil, quoted: quoted
            )
        } else if let common = major.common {
            let commonSubtitle = common.desc?.isEmpty == false ? common.desc : (quoted ? common.label : nil)
            coverCard(
                title: common.title, cover: common.cover, badge: common.label,
                subtitle: commonSubtitle, quoted: quoted
            )
        } else if let opus = major.opus {
            opusContent(opus, owner: owner, opusBody: opusBody, quoted: quoted, openPost: openPost)
        } else if let article = major.article {
            routedMedia(to: owner.articleCvid.flatMap { $0 > 0 ? .articleReader($0) : nil }) {
                articleCard(article, quoted: quoted)
            }
        } else if let liveRcmd = major.liveRcmd {
            liveRcmdContent(liveRcmd, quoted: quoted)
        } else if let type = major.type, type != "MAJOR_TYPE_NONE" {
            Text(type.replacingOccurrences(of: "MAJOR_TYPE_", with: "").capitalized)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var quotedSources: [DynamicFeedResult.DynamicItem] {
        var sources: [DynamicFeedResult.DynamicItem] = []
        var next = item.orig?.item
        while let source = next {
            sources.append(source)
            next = source.orig?.item
        }
        return sources
    }

    private var quoteChain: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(quotedSources.enumerated()), id: \.offset) { _, source in
                if let action = quotedPostAction(source) {
                    quotedContent(source, openPost: action)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: action)
                        .accessibilityAction(named: Text("View Post"), action)
                } else {
                    quotedContent(source, openPost: nil)
                }
            }
        }
        .rowCardColumnWidth(innerColumnWidth.flatMap { $0 > 26 ? $0 - 26 : nil })
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppFill.nested)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.biliAccent.opacity(0.35))
                .frame(width: 2.5)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
    }

    private func quotedContent(_ source: DynamicFeedResult.DynamicItem, openPost: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let name = source.modules?.moduleAuthor?.name, !name.isEmpty {
                profileTarget(mid: source.modules?.moduleAuthor?.mid, name: name) {
                    Text("@\(name)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.biliAccent)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
            }
            sourceContent(source, quoted: true, openPost: openPost)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotedPostAction(_ source: DynamicFeedResult.DynamicItem) -> (() -> Void)? {
        guard let id = source.idStr, !id.isEmpty, id != item.idStr else { return nil }
        return { coordinator.navigate(to: .momentDetail(id)) }
    }

    @ViewBuilder
    private func additionalContent(_ item: DynamicFeedResult.DynamicItem) -> some View {
        if let additional = item.modules?.moduleDynamic?.additional {
            if let vote = additional.vote, let voteId = vote.voteId {
                VoteCardView(
                    voteId: voteId,
                    initialTitle: vote.desc,
                    initialJoinNum: vote.joinNum
                )
            } else if let type = additional.type, type != "ADDITIONAL_TYPE_NONE" {
                unhandledAdditionalPlaceholder(type, id: item.idStr ?? "?")
            }
        }
    }

    private func unhandledAdditionalPlaceholder(_ type: String, id: String) -> EmptyView {
        Self.logUnhandledAdditional(type, id: id)
        return EmptyView()
    }

    @MainActor private static var loggedAdditionalTypes = Set<String>()

    @MainActor
    static func logUnhandledAdditional(_ type: String, id: String) {
        guard PlayerLog.isCapturing else { return }
        let key = "\(id)/\(type)"
        guard !loggedAdditionalTypes.contains(key) else { return }
        loggedAdditionalTypes.insert(key)
        PlayerLog.log("[Vote] unhandled additional type in dynamic \(id): \(type)")
    }
}

private extension DynamicCardView {
    @ViewBuilder
    func articleCard(_ article: Major.ArticleInfo, quoted: Bool) -> some View {
        if let cover = article.covers?.first, !cover.isEmpty {
            let badge = article.label ?? String(localized: "Article")
            let sub = article.desc?.isEmpty == false ? article.desc : (quoted ? badge : nil)
            DynamicMediaCard(
                title: article.title, cover: cover, kind: .labeled(badge),
                subtitle: sub, quoted: quoted, titleLineLimit: mediaTitleLimit
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(article.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(mediaTitleLimit)
                if let desc = article.desc, !desc.isEmpty {
                    Text(desc).font(.footnote).foregroundStyle(.secondary).lineLimit(postAction == nil ? nil : 3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppFill.inset, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
    }

    func archiveCard(_ archive: Major.ArchiveInfo, ownerName: String?, quoted: Bool) -> some View {
        let target = VideoRouteTarget.make(
            bvid: archive.bvid, aid: archive.aid.flatMap(Int.init), title: archive.title ?? "",
            coverURL: archive.cover ?? "", ownerName: ownerName ?? "",
            durationSeconds: FormatUtils.parseDurationSeconds(archive.durationText)
        )
        let card = DynamicMediaCard(
            title: archive.title, cover: archive.cover, kind: .video(duration: archive.durationText),
            subtitle: quoted ? String(localized: "Video") : nil, quoted: quoted, titleLineLimit: mediaTitleLimit
        )
        return Group {
            if let target { VideoNavigationButton(target: target) { card.contentShape(Rectangle()) } } else { card }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func routedMedia<Content: View>(to route: Route?, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if let route {
                Button { coordinator.navigate(to: route) } label: { content().contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            } else {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func drawGrid(_ items: [Major.DrawInfo.DrawItem], sourceID: String?) -> some View {
        let media = items.compactMap { item -> MediaGridView.Media? in
            guard let src = item.src, let url = URL(string: src.httpsURL) else { return nil }
            var size: CGSize?
            if let itemWidth = item.width, let itemHeight = item.height, itemWidth > 0, itemHeight > 0 {
                size = CGSize(width: itemWidth, height: itemHeight)
            }
            return MediaGridView.Media(url: url, pixelSize: size)
        }
        return MediaGridView(media: media, sourceID: sourceID) { onImageTap?($0) }
    }

    func coverCard(
        title: String?, cover: String?, badge: String?, subtitle: String? = nil, quoted: Bool = false
    ) -> some View {
        DynamicMediaCard(
            title: title, cover: cover, kind: .labeled(badge),
            subtitle: subtitle, quoted: quoted, titleLineLimit: mediaTitleLimit
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func opusContent(
        _ opus: Major.OpusInfo, owner: DynamicFeedResult.DynamicItem,
        opusBody: DynamicRichContent.Body?, quoted: Bool, openPost: (() -> Void)?
    ) -> some View {
        if let title = opus.title, !title.isEmpty {
            Text(title)
                .font(expanded ? .headline : .body).fontWeight(.medium).foregroundStyle(.primary)
                .lineLimit(postAction == nil || dynamicTypeSize.isAccessibilitySize ? nil : 2)
        }
        if let opusBody {
            richBody(
                text: opusBody.text, nodes: opusBody.nodes, owner: owner,
                quoted: quoted, isSummary: true, openPost: openPost
            )
        } else if let summary = opus.summary,
                  DynamicRichBodyView.hasContent(text: summary.text, nodes: summary.richTextNodes) {
            richBody(
                text: summary.text, nodes: summary.richTextNodes, owner: owner,
                quoted: quoted, isSummary: true, openPost: openPost
            )
        }
        let bodyNodes = opusBody.map { [$0.nodes ?? []] } ?? [
            owner.modules?.moduleDynamic?.desc?.richTextNodes ?? [], opus.summary?.richTextNodes ?? []
        ]
        if let pics = opus.pics, !pics.isEmpty, !DynamicRichContent.repeatsGallery(pics, bodies: bodyNodes) {
            let items = pics.compactMap { pic -> Major.DrawInfo.DrawItem? in
                pic.url.map { Major.DrawInfo.DrawItem(src: $0, width: pic.width, height: pic.height) }
            }
            if !items.isEmpty { drawGrid(items, sourceID: owner.idStr) }
        }
        if let cvid = owner.articleCvid, cvid > 0 {
            Button { coordinator.navigate(to: .articleReader(cvid)) } label: {
                Label("Read Article", systemImage: "doc.richtext")
                    .font(.footnote.weight(.medium)).foregroundStyle(.biliAccent)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
        }
    }

    func alternateOpusBody(_ owner: DynamicFeedResult.DynamicItem) -> DynamicRichContent.Body? {
        guard let dynamic = owner.modules?.moduleDynamic,
              let desc = dynamic.desc, let summary = dynamic.major?.opus?.summary else { return nil }
        return DynamicRichContent.alternateBody(
            firstText: desc.text, firstNodes: desc.richTextNodes,
            secondText: summary.text, secondNodes: summary.richTextNodes
        )
    }

    @ViewBuilder
    func liveRcmdContent(_ liveRcmd: Major.LiveRcmdInfo, quoted: Bool) -> some View {
        if liveRcmd.content != nil {
            let parsed = liveRcmd.parsed
            routedMedia(to: parsed.roomID.flatMap { $0 > 0 ? .liveRoom($0) : nil }) {
                DynamicMediaCard(
                    title: parsed.title ?? String(localized: "Live"), cover: parsed.cover,
                    kind: .live(areaName: parsed.areaName), subtitle: parsed.areaName,
                    quoted: quoted, titleLineLimit: mediaTitleLimit
                )
            }
        }
    }

    var contentType: String? {
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
