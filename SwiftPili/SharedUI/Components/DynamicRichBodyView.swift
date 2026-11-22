import SwiftUI
import UIKit

@MainActor
struct DynamicRichBodyView: View {
    typealias Node = DynamicFeedResult.DynamicItem.DynamicModules.ModuleDynamic.DynamicDesc.RichTextNode
    let text: String?
    let nodes: [Node]?
    let sourceID: String?
    var font: Font = .body
    var lineSpacing: CGFloat = 3
    var lineLimit: Int?
    var onOpenPost: (() -> Void)?
    var onImageTap: ((ImagePreviewItem) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @State private var rendered: Rendered?

    private struct RenderInputs: Equatable {
        let text: String?
        let nodes: [Node]?
        let sourceID: String?
        let font: Font
        let dynamicTypeSize: DynamicTypeSize
        let layoutDirection: LayoutDirection
        let locale: Locale
        let accent: Color
        let emoteHeight: CGFloat?
        let emoteBaselineOffset: CGFloat?
        let scale: CGFloat
    }

    private struct Rendered {
        let inputs: RenderInputs
        let texts: [Int: Text]
    }

    static func hasContent(text: String?, nodes: [Node]?) -> Bool {
        DynamicRichContent.hasContent(text: text, nodes: nodes)
    }

    var body: some View {
        let blocks = DynamicRichContent.blocks(text: text, nodes: nodes)
        let metrics = emoteFont
        let inputs = RenderInputs(
            text: text, nodes: nodes, sourceID: sourceID, font: font,
            dynamicTypeSize: dynamicTypeSize, layoutDirection: layoutDirection,
            locale: locale, accent: .biliAccent,
            emoteHeight: metrics?.emoteBoxHeight, emoteBaselineOffset: metrics?.emoteBaselineOffset,
            scale: displayScale
        )
        let asyncTexts = rendered.flatMap { $0.inputs == inputs ? $0.texts : nil }
        let residentImages = asyncTexts == nil ? residentEmoteImages(inputs: inputs) : nil
        let prepared = asyncTexts ?? prepare(blocks, images: residentImages ?? [:], inputs: inputs)
        let needsMeasurement = lineLimit.map { Self.mightExceed($0, blocks: blocks) } ?? false
        Group {
            if blocks.count == 1, case .text(let segment) = blocks[0] {
                let plainKey: String? = needsMeasurement
                    ? (segment.fallback ?? segment.nodes.map(DynamicRichContent.displayText).joined())
                    : nil
                DynamicPostText(
                    text: prepared[segment.id] ?? Text(verbatim: ""), sourceID: sourceID,
                    font: font, lineSpacing: lineSpacing, lineLimit: lineLimit,
                    needsMeasurement: needsMeasurement,
                    plainText: plainKey,
                    substitutesStickers: asyncTexts != nil || residentImages != nil,
                    onOpenPost: onOpenPost
                )
            } else {
                DynamicRichTextFlow(
                    blocks: blocks, preparedTexts: prepared, sourceID: sourceID, font: font,
                    lineSpacing: lineSpacing, lineLimit: lineLimit,
                    needsMeasurement: needsMeasurement,
                    onOpenPost: onOpenPost, onImageTap: onImageTap
                )
            }
        }
        .task(id: inputs) {
            if residentImages != nil { return }
            await prepareEmotes(blocks, inputs: inputs)
        }
    }

    private static func mightExceed(_ limit: Int, blocks: [DynamicRichContent.Block]) -> Bool {
        guard limit > 0 else { return true }
        let threshold = limit * 16
        var characterCount = 0
        var newlineCount = 0
        for block in blocks {
            guard case .text(let segment) = block else { continue }
            let raw: String
            if let fallback = segment.fallback {
                raw = fallback
            } else {
                raw = segment.nodes.map(DynamicRichContent.displayText).joined()
            }
            for ch in raw {
                characterCount += 1
                if characterCount > threshold { return true }
                if ch.isNewline {
                    newlineCount += 1
                    if newlineCount + 1 > limit { return true }
                }
            }
        }
        return false
    }

    private var emoteFont: UIFont? {
        let style: UIFont.TextStyle
        if font == .body {
            style = .body
        } else if font == .subheadline {
            style = .subheadline
        } else {
            return nil
        }
        return UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory)
        )
    }

    private func residentEmoteImages(inputs: RenderInputs) -> [String: UIImage]? {
        guard let height = inputs.emoteHeight, let nodes = inputs.nodes, !nodes.isEmpty else { return nil }
        var images: [String: UIImage] = [:]
        var hasEmoji = false
        for node in nodes where node.type == "RICH_TEXT_NODE_TYPE_EMOJI" {
            guard let source = DynamicRichContent.imageURL(node.emoji?.source)?.absoluteString else { continue }
            hasEmoji = true
            if images[source] != nil { continue }
            guard let image = EmoteImageLoader.shared.residentImage(
                for: source, height: height
            ) else {
                return nil
            }
            images[source] = image
        }
        return hasEmoji ? images : nil
    }

    private func prepareEmotes(_ blocks: [DynamicRichContent.Block], inputs: RenderInputs) async {
        guard !Task.isCancelled, let height = inputs.emoteHeight else { return }
        let emojiNodes = (inputs.nodes ?? []).filter { $0.type == "RICH_TEXT_NODE_TYPE_EMOJI" }
        guard !emojiNodes.isEmpty else { return }
        var images: [String: UIImage] = [:]
        var attemptedSources: Set<String> = []
        for node in emojiNodes {
            guard let source = DynamicRichContent.imageURL(node.emoji?.source)?.absoluteString,
                  attemptedSources.insert(source).inserted else { continue }
            let image = await EmoteImageLoader.shared.image(
                for: source, height: height, scale: inputs.scale
            )
            guard !Task.isCancelled else { return }
            images[source] = image
        }
        guard !Task.isCancelled, !images.isEmpty else { return }
        rendered = Rendered(inputs: inputs, texts: prepare(blocks, images: images, inputs: inputs))
    }

    private func prepare(
        _ blocks: [DynamicRichContent.Block], images: [String: UIImage], inputs: RenderInputs
    ) -> [Int: Text] {
        var result: [Int: Text] = [:]
        for block in blocks {
            guard case .text(let segment) = block else { continue }
            if let fallback = segment.fallback {
                result[segment.id] = Text(verbatim: fallback)
                continue
            }
            let runs = segment.nodes.map { node -> Text in
                let label = DynamicRichContent.displayText(node)
                if node.type == "RICH_TEXT_NODE_TYPE_EMOJI",
                   let source = DynamicRichContent.imageURL(node.emoji?.source)?.absoluteString,
                   let image = images[source], let baseline = inputs.emoteBaselineOffset {
                    return Text(verbatim: "\u{200B}")
                        + Text(Image(uiImage: image))
                            .font(EmoteTextFont.inlineAttachment)
                            .baselineOffset(baseline)
                } else if let target = linkTarget(node), !label.isEmpty {
                    return EmoteText.linkified(
                        label, links: [label: target], accent: inputs.accent
                    )
                } else {
                    return Text(verbatim: label)
                }
            }
            result[segment.id] = runs.reduce(Text(verbatim: "")) { $0 + $1 }
        }
        return result
    }

    private func linkTarget(_ node: Node) -> URL? {
        switch node.type {
        case "RICH_TEXT_NODE_TYPE_AT":
            if let rid = node.rid, let mid = Int(rid), mid > 0 {
                return URL(string: "https://space.bilibili.com/\(rid)")
            }
        case "RICH_TEXT_NODE_TYPE_BV", "RICH_TEXT_NODE_TYPE_AV":
            if let rid = node.rid, !rid.isEmpty {
                return URL(string: "https://www.bilibili.com/video/\(rid)")
            }
        default:
            break
        }
        guard let jump = node.jumpUrl, !jump.isEmpty else { return nil }
        return URL(string: jump.hasPrefix("//") ? "https:" + jump : jump)
    }
}
