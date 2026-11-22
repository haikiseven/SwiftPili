import SwiftUI

private struct DynamicPostTextOverflowVerdict: Equatable {
    let width: CGFloat
    let isTruncated: Bool
}

@MainActor
private enum DynamicPostTextOverflowVerdicts {
    struct Key: Hashable {
        let text: String
        let substitutesStickers: Bool
        let font: Font
        let lineSpacing: CGFloat
        let lineLimit: Int
        let dynamicTypeSize: DynamicTypeSize
    }

    private static let maxEntries = 512
    private static var entries: [Key: DynamicPostTextOverflowVerdict] = [:]
    private static var order: [Key] = []

    static func entry(for key: Key) -> DynamicPostTextOverflowVerdict? { entries[key] }

    static func record(_ verdict: DynamicPostTextOverflowVerdict, for key: Key) {
        if entries.updateValue(verdict, forKey: key) == nil {
            order.append(key)
            if order.count > maxEntries { entries.removeValue(forKey: order.removeFirst()) }
        }
    }
}

struct DynamicPostText: View {
    let text: Text
    let sourceID: String?
    var font: Font = .body
    var lineSpacing: CGFloat = 3
    var lineLimit: Int?
    var needsMeasurement = true
    var plainText: String?
    var substitutesStickers = false
    var onOpenPost: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @Environment(\.rowCardColumnWidth) private var envColumnWidth
    @State private var fullMeasurement: Measurement?
    @State private var cappedMeasurement: Measurement?

    private struct Inputs: Equatable {
        let sourceID: String?
        let plainText: String?
        let substitutesStickers: Bool
        let font: Font
        let lineSpacing: CGFloat
        let lineLimit: Int
        let dynamicTypeSize: DynamicTypeSize
        let layoutDirection: LayoutDirection
        let locale: Locale
    }

    private struct Measurement: Equatable {
        let inputs: Inputs
        let size: CGSize
    }

    var body: some View {
        let prepared = text.font(font)
        if let lineLimit, let onOpenPost, needsMeasurement {
            let inputs = Inputs(
                sourceID: sourceID, plainText: plainText, substitutesStickers: substitutesStickers,
                font: font, lineSpacing: lineSpacing, lineLimit: lineLimit,
                dynamicTypeSize: dynamicTypeSize, layoutDirection: layoutDirection, locale: locale
            )
            let verdictKey = cacheKey(lineLimit: lineLimit)
            let retained = retainedVerdict(for: verdictKey, inputs: inputs)
            VStack(alignment: .leading, spacing: 2) {
                prepared
                    .foregroundStyle(.primary)
                    .lineSpacing(lineSpacing)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        if retained == nil {
                            prepared
                                .lineSpacing(lineSpacing)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .onGeometryChange(for: Measurement.self) { proxy in
                                    Measurement(inputs: inputs, size: proxy.size)
                                } action: { measurement in
                                    fullMeasurement = measurement
                                    recordVerdictIfReady(inputs: inputs, key: verdictKey)
                                }
                        }
                    }
                    .onGeometryChange(for: Measurement.self) { proxy in
                        Measurement(inputs: inputs, size: proxy.size)
                    } action: { measurement in
                        cappedMeasurement = measurement
                        recordVerdictIfReady(inputs: inputs, key: verdictKey)
                    }

                if retained ?? isTruncated(for: inputs) {
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
        } else {
            prepared
                .foregroundStyle(.primary)
                .lineSpacing(lineSpacing)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cacheKey(lineLimit: Int) -> DynamicPostTextOverflowVerdicts.Key? {
        guard let identity = plainText ?? sourceID, !identity.isEmpty else { return nil }
        return .init(
            text: identity,
            substitutesStickers: substitutesStickers,
            font: font,
            lineSpacing: lineSpacing,
            lineLimit: lineLimit,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    private func retainedVerdict(
        for key: DynamicPostTextOverflowVerdicts.Key?,
        inputs: Inputs
    ) -> Bool? {
        guard let key, let entry = DynamicPostTextOverflowVerdicts.entry(for: key) else { return nil }
        let expectedWidth: CGFloat
        if let cappedMeasurement, cappedMeasurement.inputs == inputs, cappedMeasurement.size.width > 0 {
            expectedWidth = cappedMeasurement.size.width
        } else if let col = envColumnWidth, col > 0 {
            expectedWidth = col
        } else if let last = cappedMeasurement?.size.width, last > 0 {
            expectedWidth = last
        } else {
            expectedWidth = entry.width
        }
        guard abs(entry.width - expectedWidth) < 0.5 else { return nil }
        return entry.isTruncated
    }

    private func recordVerdictIfReady(
        inputs: Inputs,
        key: DynamicPostTextOverflowVerdicts.Key?
    ) {
        guard let key,
              let fullMeasurement, let cappedMeasurement,
              fullMeasurement.inputs == inputs, cappedMeasurement.inputs == inputs,
              cappedMeasurement.size.width.isFinite, cappedMeasurement.size.width > 0,
              fullMeasurement.size.height.isFinite, fullMeasurement.size.height > 0,
              cappedMeasurement.size.height.isFinite, cappedMeasurement.size.height > 0,
              abs(fullMeasurement.size.width - cappedMeasurement.size.width) < 0.5 else { return }
        let truncated = fullMeasurement.size.height > cappedMeasurement.size.height + 1
        DynamicPostTextOverflowVerdicts.record(
            DynamicPostTextOverflowVerdict(width: cappedMeasurement.size.width, isTruncated: truncated),
            for: key
        )
    }

    private func isTruncated(for inputs: Inputs) -> Bool {
        guard let fullMeasurement, let cappedMeasurement,
              fullMeasurement.inputs == inputs, cappedMeasurement.inputs == inputs,
              abs(fullMeasurement.size.width - cappedMeasurement.size.width) < 0.5 else { return false }
        return fullMeasurement.size.height > cappedMeasurement.size.height + 1
    }
}
