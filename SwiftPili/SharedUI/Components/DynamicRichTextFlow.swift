import SwiftUI

/// Native Text probes allocate one line allowance across ordered text blocks.
/// Attachments remain visible when later text is clipped; each text block does
/// not silently acquire a new independent preview budget.
struct DynamicRichTextFlow: View {
    let blocks: [DynamicRichContent.Block]
    let preparedTexts: [Int: Text]
    let sourceID: String?
    let font: Font
    let lineSpacing: CGFloat
    let lineLimit: Int?
    var needsMeasurement = true
    let onOpenPost: (() -> Void)?
    let onImageTap: ((ImagePreviewItem) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @State private var width: CGFloat = 0
    @State private var measurements: [ProbeID: Measurement] = [:]

    private struct TextBlock: Identifiable {
        let id: Int
        let text: Text
    }

    private struct Inputs: Equatable {
        let blockIDs: [Int]
        let sourceID: String?
        let font: Font
        let lineSpacing: CGFloat
        let limit: Int
        let dynamicTypeSize: DynamicTypeSize
        let layoutDirection: LayoutDirection
        let locale: Locale
    }

    private struct ProbeID: Hashable {
        let blockID: Int
        /// Zero is unlimited; visible text with no remaining lines is omitted.
        let limit: Int
    }

    private struct Measurement: Equatable {
        let inputs: Inputs
        let size: CGSize
    }

    private struct Allocation {
        var limits: [Int: Int] = [:]
        var isTruncated = false
    }

    var body: some View {
        let texts = textBlocks
        let limit = (onOpenPost == nil || !needsMeasurement) ? nil : lineLimit
        let inputs = Inputs(
            blockIDs: texts.map(\.id), sourceID: sourceID, font: font, lineSpacing: lineSpacing,
            limit: max(limit ?? 0, 0), dynamicTypeSize: dynamicTypeSize,
            layoutDirection: layoutDirection, locale: locale
        )
        let allocation = allocate(inputs, texts: texts)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block {
                case .text(let segment):
                    let remaining = allocation.limits[segment.id] ?? inputs.limit
                    if limit == nil || remaining > 0 {
                        (preparedTexts[segment.id] ?? Text(verbatim: ""))
                            .font(font)
                            .foregroundStyle(.primary)
                            .lineSpacing(lineSpacing)
                            .lineLimit(limit == nil ? lineLimit : remaining)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .pictures(let attachment):
                    DynamicPictureAttachmentView(
                        attachment: attachment, sourceID: sourceID, onImageTap: onImageTap
                    )
                }
            }
            if allocation.isTruncated, let onOpenPost {
                Button(action: onOpenPost) {
                    Text("View Full Text")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.biliAccent)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appControl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            if inputs.limit > 0, width != newWidth { width = newWidth }
        }
        .overlay(alignment: .topLeading) {
            if inputs.limit > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(texts) { block in
                        probe(block, limit: 0, inputs: inputs)
                        ForEach(1...inputs.limit, id: \.self) { cappedLimit in
                            probe(block, limit: cappedLimit, inputs: inputs)
                        }
                    }
                }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private var textBlocks: [TextBlock] {
        blocks.compactMap { block in
            guard case .text(let segment) = block else { return nil }
            return TextBlock(id: segment.id, text: preparedTexts[segment.id] ?? Text(verbatim: ""))
        }
    }

    private func probe(_ block: TextBlock, limit: Int, inputs: Inputs) -> some View {
        let id = ProbeID(blockID: block.id, limit: limit)
        return block.text
            .font(font)
            .lineSpacing(lineSpacing)
            .lineLimit(limit == 0 ? nil : limit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Measurement.self) { proxy in
                Measurement(inputs: inputs, size: proxy.size)
            } action: { measurement in
                measurements[id] = measurement
            }
    }

    private func height(blockID: Int, limit: Int, inputs: Inputs) -> CGFloat? {
        let id = ProbeID(blockID: blockID, limit: limit)
        guard let measurement = measurements[id], measurement.inputs == inputs,
              width > 0, measurement.size.width == width else { return nil }
        return measurement.size.height
    }

    private func allocate(_ inputs: Inputs, texts: [TextBlock]) -> Allocation {
        guard inputs.limit > 0 else { return Allocation() }
        var allocation = Allocation()
        var remaining = inputs.limit
        for block in texts {
            allocation.limits[block.id] = remaining
            guard let full = height(blockID: block.id, limit: 0, inputs: inputs) else {
                // Until exact native receipts arrive, give only the earliest
                // unresolved text the remaining budget. Never multiply it.
                remaining = 0
                continue
            }
            if full <= 1 {
                allocation.limits[block.id] = 0
                continue
            }
            guard remaining > 0 else {
                allocation.isTruncated = allocation.isTruncated || full > 1
                continue
            }
            let measured = (1...remaining).compactMap { limit -> (Int, CGFloat)? in
                height(blockID: block.id, limit: limit, inputs: inputs).map { (limit, $0) }
            }
            guard measured.count == remaining else {
                remaining = 0
                continue
            }
            if let complete = measured.first(where: { full <= $0.1 + 1 }) {
                allocation.limits[block.id] = complete.0
                remaining -= complete.0
            } else {
                allocation.isTruncated = true
                remaining = 0
            }
        }
        return allocation
    }
}
