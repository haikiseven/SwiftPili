import Foundation

/// Projection of one supplied logical body. Picture nodes stay in document
/// order; their display labels are never interpreted as counts or image URLs.
enum DynamicRichContent {
    typealias Node = DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicDesc.RichTextNode
    typealias Picture = Node.Picture
    typealias OpusPicture = DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicMajor.OpusInfo.OpusPic

    struct TextSegment {
        let id: Int
        let nodes: [Node]
        let fallback: String?
    }

    struct Attachment {
        let id: Int
        let node: Node
    }

    struct PictureIdentity {
        let url: URL
        let width: Int?
        let height: Int?
    }

    struct Body {
        let text: String?
        let nodes: [Node]?
    }

    enum Block: Identifiable {
        case text(TextSegment)
        case pictures(Attachment)

        var id: Int {
            switch self {
            case .text(let segment): segment.id
            case .pictures(let attachment): attachment.id
            }
        }
    }

    static func hasContent(text: String?, nodes: [Node]?) -> Bool {
        meaningful(text) || (nodes ?? []).contains {
            meaningful(displayText($0)) || isPictureAttachment($0) || meaningful($0.emoji?.source)
        }
    }

    static func plainText(text: String?, nodes: [Node]?) -> String {
        if meaningful(text) { return text ?? "" }
        return (nodes ?? []).filter { !isPictureAttachment($0) }.map(displayText).joined()
    }

    static func displayText(_ node: Node) -> String {
        if let original = node.origText, !original.isEmpty { return original }
        return node.text ?? ""
    }

    static func imageURL(_ source: String?) -> URL? {
        guard let source, let url = URL(string: source.httpsURL),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    static func pictureIdentity(source: String?, width: Int?, height: Int?) -> PictureIdentity? {
        guard let url = imageURL(source) else { return nil }
        return PictureIdentity(url: url, width: width.flatMap { $0 > 0 ? $0 : nil },
                               height: height.flatMap { $0 > 0 ? $0 : nil })
    }

    static func samePictures(_ first: [PictureIdentity], _ second: [PictureIdentity]) -> Bool {
        guard !first.isEmpty, first.count == second.count else { return false }
        return zip(first, second).allSatisfy { first, second in
            first.url == second.url
                && (first.width == nil || second.width == nil || first.width == second.width)
                && (first.height == nil || second.height == nil || first.height == second.height)
        }
    }

    /// Same-source alternate galleries may match actually supplied ordered
    /// attachments. Resolved-only, different-source or different arrays remain.
    static func repeatsGallery(_ pictures: [OpusPicture], bodies: [[Node]]) -> Bool {
        let gallery = pictures.compactMap {
            pictureIdentity(source: $0.url, width: $0.width, height: $0.height)
        }
        let attachments = bodies.flatMap { nodes in
            blocks(text: nil, nodes: nodes).compactMap { block -> [PictureIdentity]? in
                guard case .pictures(let attachment) = block else { return nil }
                return (attachment.node.pics ?? []).compactMap {
                    pictureIdentity(source: $0.source, width: $0.width, height: $0.height)
                }
            }
        }
        return attachments.contains { samePictures(gallery, $0) }
            || samePictures(gallery, attachments.flatMap { $0 })
    }

    static func blocks(text: String?, nodes: [Node]?) -> [Block] {
        guard let nodes, !nodes.isEmpty,
              nodes.contains(where: {
                  meaningful(displayText($0)) || isPictureAttachment($0) || meaningful($0.emoji?.source)
              }) else {
            return meaningful(text) ? [.text(TextSegment(id: 0, nodes: [], fallback: text))] : []
        }
        var result: [Block] = []
        var pending: [Node] = []
        var textID = 0
        for (index, node) in nodes.enumerated() {
            if isPictureAttachment(node) {
                if !pending.isEmpty {
                    result.append(.text(TextSegment(id: textID, nodes: pending, fallback: nil)))
                    pending.removeAll(keepingCapacity: true)
                }
                result.append(.pictures(Attachment(id: index, node: node)))
                textID = index + 1
            } else {
                pending.append(node)
            }
        }
        if !pending.isEmpty {
            result.append(.text(TextSegment(id: textID, nodes: pending, fallback: nil)))
        }
        return result
    }

    /// Select only an ordered, metadata-richer alternate representation.
    /// Differing substantive runs/attachments are separate content, not guessed
    /// duplicates merely because their plain summary strings happen to match.
    static func preferredNodes(first: [Node]?, second: [Node]?) -> [Node]? {
        let first = first ?? []
        let second = second ?? []
        if first.isEmpty { return second.isEmpty ? nil : second }
        if second.isEmpty { return first }
        if isMetadataSuperset(first, of: second) { return first }
        if isMetadataSuperset(second, of: first) { return second }
        return nil
    }

    static func alternateBody(
        firstText: String?, firstNodes: [Node]?, secondText: String?, secondNodes: [Node]?
    ) -> Body? {
        guard hasContent(text: firstText, nodes: firstNodes),
              hasContent(text: secondText, nodes: secondNodes),
              plainText(text: firstText, nodes: firstNodes) == plainText(text: secondText, nodes: secondNodes) else {
            return nil
        }
        let nodes = preferredNodes(first: firstNodes, second: secondNodes)
        let bothPlain = (firstNodes ?? []).isEmpty && (secondNodes ?? []).isEmpty
        guard nodes != nil || bothPlain else { return nil }
        return Body(text: secondText ?? firstText, nodes: nodes)
    }

    private static func isMetadataSuperset(_ candidate: [Node], of baseline: [Node]) -> Bool {
        guard candidate.count == baseline.count else { return false }
        return zip(candidate, baseline).allSatisfy { richer, original in
            richer.type == original.type && displayText(richer) == displayText(original)
                && richer.rid == original.rid && richer.jumpUrl == original.jumpUrl
                && ((original.pics ?? []).isEmpty || richer.pics == original.pics)
                && (original.emoji == nil || richer.emoji == original.emoji)
        }
    }

    private static func isPictureAttachment(_ node: Node) -> Bool {
        node.type == "RICH_TEXT_NODE_TYPE_VIEW_PICTURE"
            && ((node.pics ?? []).contains { meaningful($0.source) } || meaningful(node.rid))
    }

    private static func meaningful(_ value: String?) -> Bool {
        !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
