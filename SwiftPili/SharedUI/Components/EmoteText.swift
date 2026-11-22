import ImageIO
import Kingfisher
import os
import SwiftUI
import UIKit

/// UIKit font specification for `EmoteText` so inline sticker boxes and baseline offsets scale with the text's `UIFont` metrics and Dynamic Type without inflating line height.
struct EmoteTextFont: Equatable {
    let size: CGFloat
    let weight: UIFont.Weight
    /// Text style the size scales against.
    let textStyle: UIFont.TextStyle

    // Computed rather than stored: a `static let` of a type holding
    // `UIFont.Weight`/`UIFont.TextStyle` has to prove itself Sendable under
    // strict concurrency, and rebuilding three fields costs nothing.
    static var subheadline: Self { Self(size: 15, weight: .regular, textStyle: .subheadline) }
    static var footnote: Self { Self(size: 13, weight: .regular, textStyle: .footnote) }
    static var caption: Self { Self(size: 12, weight: .regular, textStyle: .caption1) }

    /// Builds a Dynamic Type-scaled `EmoteTextFont` preserving `style`'s nominal size and weight.
    static func app(_ style: AppTextStyle) -> Self {
        Self(size: style.nominalPointSize, weight: style.uiFontWeight, textStyle: style.uiTextStyle)
    }

    /// A size that is not one of the system text styles, scaled relative to the
    /// nearest one.
    static func points(
        _ size: CGFloat,
        weight: UIFont.Weight = .regular,
        relativeTo textStyle: UIFont.TextStyle
    ) -> Self {
        Self(size: size, weight: weight, textStyle: textStyle)
    }

    /// Same size and scaling, different weight. `.fontWeight()` is not a
    /// reliable way to re-weight a `Font` built from a concrete `UIFont` — the
    /// weight is already baked into the face — so a label that wants medium
    /// asks for it here instead.
    func weighted(_ weight: UIFont.Weight) -> Self {
        Self(size: size, weight: weight, textStyle: textStyle)
    }

    /// Minimal 0.1pt font for inline `Text(Image(...))` attachments so the
    /// surrounding paragraph font's descender does not stack with `.baselineOffset`.
    static let inlineAttachment: Font = Font(UIFont.systemFont(ofSize: 0.1))

    var uiFont: UIFont {
        scaledFont(compatibleWith: nil)
    }

    func uiFont(for dynamicTypeSize: DynamicTypeSize) -> UIFont {
        scaledFont(compatibleWith: UITraitCollection(
            preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory
        ))
    }

    private func scaledFont(compatibleWith traits: UITraitCollection?) -> UIFont {
        UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: .systemFont(ofSize: size, weight: weight),
            compatibleWith: traits
        )
    }

    /// Derived FROM `uiFont`, never built alongside it, so the metrics the
    /// emote box is cut from always belong to the face the text is drawn in.
    var swiftUIFont: Font { Font(uiFont) }
}

extension DynamicTypeSize {
    /// Shared bridge for UIKit font metrics resolved from SwiftUI's text size.
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

/// The UIKit half of `AppTextStyle`. It lives here rather than beside the
/// table because `AdaptiveLayoutPolicy.swift` imports Foundation alone, which
/// is what lets that table be executed off-device.
extension AppTextStyle {
    /// The weight baked into the system style. Only `.headline` has one; the
    /// rest are regular, and `Font.app` gets this for free by naming the style.
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .headline: .semibold
        default: .regular
        }
    }

    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .title1: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        }
    }
}

extension UIFont {
    /// Full native line-box height (`ascender - descender`, rounded up to 0.5pt)
    /// so inline stickers match the visual scale of surrounding CJK and Latin copy.
    var emoteBoxHeight: CGFloat { ceil((ascender - descender) * 2) / 2 }
    /// Vertical baseline offset centering the `emoteBoxHeight` sticker squarely on
    /// the line's `[descender, ascender]` midpoint alongside left and right glyphs.
    var emoteBaselineOffset: CGFloat { (ascender + descender - emoteBoxHeight) * 0.5 }
}

/// Downloads and caches small sticker images, pre-scaled to text size so
/// they can be embedded in a SwiftUI `Text` run.
actor EmoteImageLoader {
    static let shared = EmoteImageLoader()

    /// LRU bound on resident text-height resized sticker bitmaps (`url@height`).
    private static let maxEntries = 256

    private struct ResidentState: Sendable {
        var map: [String: UIImage] = [:]
        var accessGen: [String: UInt64] = [:]
        var nextGen: UInt64 = 0

        mutating func get(_ key: String) -> UIImage? {
            guard let image = map[key] else { return nil }
            nextGen &+= 1
            accessGen[key] = nextGen
            return image
        }

        mutating func store(_ key: String, image: UIImage, maxEntries: Int) {
            map[key] = image
            nextGen &+= 1
            accessGen[key] = nextGen
            while map.count > maxEntries {
                guard let oldestKey = accessGen.min(by: { $0.value < $1.value })?.key else { break }
                map.removeValue(forKey: oldestKey)
                accessGen.removeValue(forKey: oldestKey)
            }
        }
    }

    /// Lock-protected LRU cache shared by synchronous `residentImage` lookups and async completions.
    private let resident = OSAllocatedUnfairLock(initialState: ResidentState())
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    func image(
        for urlString: String, height: CGFloat, baselineFromBottom: CGFloat = 0, scale: CGFloat = 3.0
    ) async -> UIImage? {
        // Keyed to decimals because height and baseline offset come from scaled `UIFont` metrics.
        let key = Self.key(urlString, height: height, baselineFromBottom: baselineFromBottom)
        if let hit = resident.withLock({ $0.get(key) }) { return hit }
        if let task = inflight[key] { return await task.value }

        let task = Task.detached(priority: .utility) {
            await Self.loadAndDecode(
                urlString: urlString, height: height, baselineFromBottom: baselineFromBottom, scale: scale
            )
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result { resident.withLock { $0.store(key, image: result, maxEntries: Self.maxEntries) } }
        return result
    }

    /// Resident pre-scaled image for exactly this request, without loading.
    /// A miss means only "not resident now"; callers fall back to `image(for:)`.
    nonisolated func residentImage(
        for urlString: String, height: CGFloat, baselineFromBottom: CGFloat = 0
    ) -> UIImage? {
        let key = Self.key(urlString, height: height, baselineFromBottom: baselineFromBottom)
        return resident.withLock { $0.get(key) }
    }

    private nonisolated static func key(
        _ urlString: String, height: CGFloat, baselineFromBottom: CGFloat
    ) -> String {
        "\(urlString)@\(String(format: "%.1f", height))@\(String(format: "%.2f", baselineFromBottom))"
    }

    private nonisolated static func loadAndDecode(
        urlString: String, height: CGFloat, baselineFromBottom: CGFloat, scale: CGFloat
    ) async -> UIImage? {
        guard height > 0 else { return nil }
        let safeScale = scale.isFinite && scale > 0 ? scale : 3.0
        let requested = urlString.biliResized(
            toPixel: CGSize(width: ceil(height * safeScale * 2), height: ceil(height * safeScale))
        ).httpsURL
        guard let url = URL(string: requested) else { return nil }
        let cacheKey = url.cacheKey
        let cache = ImageCache.default

        if let data = try? cache.diskStorage.value(forKey: cacheKey),
           let cached = decodeEmote(
               data: data, height: height, baselineFromBottom: baselineFromBottom, scale: safeScale
           ) {
            return cached
        }

        guard !Task.isCancelled,
              let (data, response) = try? await URLSession.shared.data(from: url),
              !data.isEmpty else { return nil }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            return nil
        }
        guard !Task.isCancelled,
              let decoded = decodeEmote(
                  data: data, height: height, baselineFromBottom: baselineFromBottom, scale: safeScale
              ) else { return nil }
        cache.storeToDisk(data, forKey: cacheKey, completionHandler: nil)
        return decoded
    }

    private nonisolated static func decodeEmote(
        data: Data,
        height: CGFloat,
        baselineFromBottom: CGFloat,
        scale: CGFloat
    ) -> UIImage? {
        guard height > 0, scale > 0 else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
           CGImageSourceGetCount(source) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any]
            let rawW = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let rawH = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let (pixelW, pixelH) = (5 ... 8).contains(orientation) ? (rawH, rawW) : (rawW, rawH)
            let aspect: CGFloat = (pixelW > 0 && pixelH > 0) ? CGFloat(pixelW / pixelH) : 1
            let pointWidth = max(1, height * aspect)
            let maxPixel = max(1, Int(ceil(max(pointWidth, height) * scale)))
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary),
               cgImage.height > 0 {
                let effectiveScale = CGFloat(cgImage.height) / height
                if effectiveScale > 0, effectiveScale.isFinite {
                    let image = UIImage(cgImage: cgImage, scale: effectiveScale, orientation: .up)
                    return baselineFromBottom > 0 ? image.withBaselineOffset(fromBottom: baselineFromBottom) : image
                }
            }
        }

        guard let raw = UIImage(data: data), raw.size.height > 0 else { return nil }
        let size = CGSize(width: max(1, height * raw.size.width / raw.size.height), height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            raw.draw(in: CGRect(origin: .zero, size: size))
        }
        return baselineFromBottom > 0 ? rendered.withBaselineOffset(fromBottom: baselineFromBottom) : rendered
    }
}

/// One construction-time snapshot feeds task identity and fallback rendering.
private struct EmoteTextPreparedContent {
    let message: String
    let emotes: [String: String]
    let links: [String: URL]
    let identity: EmoteTextContentIdentity

    init(message: String, emotes: [String: String], links: [String: URL]) {
        self.message = message
        self.emotes = emotes
        self.links = links
        identity = EmoteTextContentIdentity(message: message, emotes: emotes, links: links)
    }
}

private struct EmoteTextContentIdentity: Equatable {
    // The inputs are kept as given: String and Dictionary are copy-on-write, so
    // preparing this per parent pass allocates nothing. Equality compares literal
    // UTF-8 (below), because String == folds NFC/NFD spellings while the
    // identity must retain the input bytes, and Dictionary equality ignores
    // insertion order, which is what a changed-content check wants.
    private let message: String
    private let emotes: [String: String]
    private let links: [String: URL]

    init(message: String, emotes: [String: String], links: [String: URL]) {
        self.message = message
        self.emotes = emotes
        self.links = links
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        literallyEqual(lhs.message, rhs.message)
            && literallyEqual(lhs.emotes, rhs.emotes) { literallyEqual($0, $1) }
            && literallyEqual(lhs.links, rhs.links) { literallyEqual($0.absoluteString, $1.absoluteString) }
    }

    private static func literallyEqual(_ lhs: String, _ rhs: String) -> Bool {
        var lhs = lhs
        var rhs = rhs
        return lhs.withUTF8 { left in
            rhs.withUTF8 { right in
                // An empty buffer may have no base address; equal counts then mean equal.
                left.count == right.count && (
                    left.baseAddress.flatMap { leftBase in
                        right.baseAddress.map { memcmp(leftBase, $0, left.count) == 0 }
                    } ?? true
                )
            }
        }
    }

    /// Same key set by literal spelling, and equal values. A lookup finds the
    /// canonically equal key, so its stored spelling is compared as well.
    private static func literallyEqual<Value>(
        _ lhs: [String: Value], _ rhs: [String: Value], values equal: (Value, Value) -> Bool
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, value) in lhs {
            guard let index = rhs.index(forKey: key) else { return false }
            let other = rhs[index]
            guard literallyEqual(key, other.key), equal(value, other.value) else { return false }
        }
        return true
    }
}

/// One unfonted fallback per retained view; lookup publishes no view state.
@MainActor
private final class EmoteTextFallbackMemo {
    private struct Entry {
        let content: EmoteTextContentIdentity
        let accent: Color
        let text: Text
    }

    private var entry: Entry?

    func text(for content: EmoteTextPreparedContent, accent: Color) -> Text {
        if let entry, entry.content == content.identity, entry.accent == accent {
            return entry.text
        }
        let text = EmoteText.linkified(content.message, links: content.links, accent: accent)
        entry = Entry(content: content.identity, accent: accent, text: text)
        return text
    }
}

/// One locally retained final Text assembled from resident sticker images,
/// keyed by the complete render identity; lookup publishes no view state.
/// Like the fallback memo this is a per-view entry, not a global styled-Text
/// cache: what rows share is only the pre-scaled bitmaps.
@MainActor
private final class EmoteTextResidentMemo<Key: Equatable> {
    private var entry: (key: Key, text: Text?)?
    /// The last resident Text a key change displaced. When this row's task
    /// cleared `rendered` on a resident hit, this is what keeps the old
    /// stickers on screen until the new key's replacement publishes, as the
    /// async path always did.
    private(set) var predecessor: Text?

    /// The resident Text for `key`, assembled at most once per key. `nil`
    /// when any referenced sticker is not resident (the task owns that).
    func text(for key: Key, assemble: () -> Text?) -> Text? {
        if let entry, entry.key == key { return entry.text }
        if let displaced = entry?.text { predecessor = displaced }
        let text = assemble()
        entry = (key, text)
        if text != nil { predecessor = nil }
        return text
    }

    func hasText(for key: Key) -> Bool {
        guard let entry else { return false }
        return entry.key == key && entry.text != nil
    }

    /// Called right before an async replacement publishes, so an accepted nil
    /// falls back to plain text rather than to displaced stickers. Returns
    /// whether the body may still be drawing what was retired.
    @discardableResult
    func retirePredecessor() -> Bool {
        defer { predecessor = nil }
        return predecessor != nil
    }
}

/// One disclosure verdict from a single coherent layout: the visible limited
/// Text's width and whether the unlimited Text at that width is taller.
private struct EmoteTextOverflowVerdict: Equatable {
    let width: CGFloat
    let isTruncated: Bool
}

private struct EmoteTextOverflowPreferenceKey: PreferenceKey {
    static var defaultValue: EmoteTextOverflowVerdict? { nil }

    static func reduce(value: inout EmoteTextOverflowVerdict?, nextValue: () -> EmoteTextOverflowVerdict?) {
        value = nextValue() ?? value
    }
}

/// Last measured disclosure verdict per drawn text, retained across lazy-row
/// recycling. A recreated collapsible seeds its verdict from here, so it does
/// not lay out a hidden full copy, write State after layout and grow by the
/// button row each time it scrolls back into view (which shifted visible
/// content when scrolling up). The key is what decides wrapping: the message,
/// whether stickers replace their tokens, the resolved point size and the
/// limit; the width is stored and must match for a measurement to be skipped.
/// Only Texts that are a pure function of the key are retained: the fallback,
/// or a resident assembly with every sticker. A partial async build (a failed
/// image keeps its token) or a predecessor's Text is measured and never stored.
/// Bounded FIFO; a miss only means measuring as before.
@MainActor
private enum EmoteTextOverflowVerdicts {
    struct Key: Hashable {
        let message: String
        let substitutesStickers: Bool
        /// Face and size: `fontName` carries the weight, `pointSize` Dynamic Type.
        let fontName: String
        let pointSize: CGFloat
        let limit: Int
    }

    private static let maxEntries = 512
    private static var entries: [Key: EmoteTextOverflowVerdict] = [:]
    private static var order: [Key] = []

    static func lastVerdict(for key: Key) -> Bool? { entries[key]?.isTruncated }

    /// The retained verdict only for the same width; any other width measures.
    static func verdict(for key: Key, width: CGFloat) -> Bool? {
        guard let entry = entries[key], abs(entry.width - width) < 0.5 else { return nil }
        return entry.isTruncated
    }

    static func record(_ verdict: EmoteTextOverflowVerdict, for key: Key) {
        if entries.updateValue(verdict, forKey: key) == nil {
            order.append(key)
            if order.count > maxEntries { entries.removeValue(forKey: order.removeFirst()) }
        }
    }
}

/// Geometry feedback updates only the disclosure verdict, not text preparation.
private struct EmoteTextCollapsibleContent: View {
    @AppMotion private var motion
    let text: Text
    let limit: Int
    @Binding var isExpanded: Bool
    /// `nil` when the drawn Text is not a pure function of a key: measure, never retain.
    let verdictKey: EmoteTextOverflowVerdicts.Key?
    @State private var isTruncated: Bool

    init(text: Text, limit: Int, isExpanded: Binding<Bool>, verdictKey: EmoteTextOverflowVerdicts.Key?) {
        self.text = text
        self.limit = limit
        _isExpanded = isExpanded
        self.verdictKey = verdictKey
        _isTruncated = State(initialValue: verdictKey.flatMap(EmoteTextOverflowVerdicts.lastVerdict(for:)) ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            text
                .lineLimit(isExpanded ? nil : limit)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    if !isExpanded {
                        GeometryReader { collapsed in
                            let width = collapsed.size.width
                            if let verdictKey,
                               let retained = EmoteTextOverflowVerdicts.verdict(for: verdictKey, width: width) {
                                // Same drawn text at the same width: the verdict
                                // is known, so no hidden full copy is laid out.
                                Color.clear.preference(
                                    key: EmoteTextOverflowPreferenceKey.self,
                                    value: EmoteTextOverflowVerdict(width: width, isTruncated: retained)
                                )
                            } else {
                                text
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(width: width)
                                    .hidden()
                                    .background {
                                        GeometryReader { full in
                                            Color.clear.preference(
                                                key: EmoteTextOverflowPreferenceKey.self,
                                                value: Self.verdict(
                                                    width: width,
                                                    fullHeight: full.size.height,
                                                    collapsedHeight: collapsed.size.height
                                                )
                                            )
                                        }
                                    }
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // Native link runs retain precedence over this text gesture.
                    guard isTruncated || isExpanded else { return }
                    withAnimation(motion.animation(normal: .easeInOut(duration: 0.2))) { isExpanded.toggle() }
                }

            if isTruncated || isExpanded {
                Button {
                    withAnimation(motion.animation(normal: .easeInOut(duration: 0.2))) { isExpanded.toggle() }
                } label: {
                    // Text only in comment rows (frequent; HIG Motion): the label
                    // interpolates and the control gives press feedback.
                    (isExpanded ? Text("Show Less") : Text("Show More"))
                        .font(.footnote.weight(.medium))
                        .contentTransition(.interpolate)
                        .foregroundStyle(.biliAccent)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appControl)
            }
        }
        .onPreferenceChange(EmoteTextOverflowPreferenceKey.self) { verdict in
            guard !isExpanded, let verdict else { return }
            if let verdictKey { EmoteTextOverflowVerdicts.record(verdict, for: verdictKey) }
            if verdict.isTruncated != isTruncated { isTruncated = verdict.isTruncated }
        }
    }

    /// Invalid samples publish nothing rather than claiming no overflow.
    private static func verdict(
        width: CGFloat, fullHeight: CGFloat, collapsedHeight: CGFloat
    ) -> EmoteTextOverflowVerdict? {
        guard width.isFinite, width > 0,
              fullHeight.isFinite, fullHeight > 0,
              collapsedHeight.isFinite, collapsedHeight > 0 else { return nil }
        return EmoteTextOverflowVerdict(width: width, isTruncated: fullHeight > collapsedHeight + 1)
    }
}

/// Comment text with BiliBili "[doge]"-style emote tokens rendered as
/// inline sticker images, and jump_url substrings ("查看图片", BV links,
/// plain URLs) rendered as tappable links. Taps route through the
/// openURL environment (RootView sends bilibili URLs in-app).
struct EmoteText: View {
    let message: String
    /// token → image URL, from CommentContent.emote.
    let emotes: [String: String]
    /// literal substring → destination, from CommentContent.resolvedLinks.
    let links: [String: URL]
    /// Carries its own metrics; the emote box and baseline offset are derived
    /// from it rather than passed alongside it, because the two drifting apart
    /// is precisely what made lines with emotes taller than lines without.
    var font: EmoteTextFont = .subheadline
    /// When set, messages taller than this many lines start collapsed
    /// with a Show More / Show Less toggle (tap the text or the button).
    let collapsedLineLimit: Int?

    /// Detect m:ss / mm:ss / h:mm:ss timestamps in the text and render
    /// them as accent seek-links (video comment lists turn this on; it
    /// makes no sense in profile bios or chat).
    let detectTimestamps: Bool
    /// Optional inline prefix (e.g., `"昵称："` in compact sub-reply cards)
    /// prepended to the first line so wrapped lines flow under the prefix.
    var leadingText: Text?

    private let preparedContent: EmoteTextPreparedContent
    private let needsCollapseMeasurement: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @State private var rendered: Text?
    @State private var fallbackMemo = EmoteTextFallbackMemo()
    @State private var residentMemo = EmoteTextResidentMemo<RenderKey>()
    /// Bumped only when a displaced resident Text that the body may be drawing
    /// is retired without a `rendered` change, so the fallback is re-read.
    @State private var predecessorRetirements = 0
    @State private var isExpanded = false

    init(
        message: String,
        emotes: [String: String],
        links: [String: URL] = [:],
        font: EmoteTextFont = .subheadline,
        collapsedLineLimit: Int? = nil,
        detectTimestamps: Bool = false,
        leadingText: Text? = nil
    ) {
        self.message = message
        self.emotes = emotes
        self.links = links
        self.font = font
        self.collapsedLineLimit = collapsedLineLimit
        self.detectTimestamps = detectTimestamps
        self.leadingText = leadingText
        let effectiveLinks = detectTimestamps
            ? Self.timestampLinks(in: message).merging(links) { _, explicit in explicit }
            : links
        preparedContent = EmoteTextPreparedContent(message: message, emotes: emotes, links: effectiveLinks)
        needsCollapseMeasurement = collapsedLineLimit.map {
            leadingText != nil || Self.mightExceed($0, message: message)
        } ?? false
    }

    /// The captured content stays coherent with the body-resolved style metrics.
    private struct RenderInputs {
        let content: EmoteTextPreparedContent
        let accent: Color
        let height: CGFloat
        let baselineOffset: CGFloat
        let scale: CGFloat

        var message: String { content.message }
        var emotes: [String: String] { content.emotes }
        var links: [String: URL] { content.links }
    }

    /// Only inputs baked into rendered Text participate in the image task key.
    private struct RenderKey: Equatable {
        let content: EmoteTextContentIdentity
        let accent: Color
        let emoteBox: CGFloat
        let baselineOffset: CGFloat

        init(_ inputs: RenderInputs) {
            content = inputs.content.identity
            accent = inputs.accent
            emoteBox = inputs.height
            baselineOffset = inputs.baselineOffset
        }
    }

    /// A displaced resident Text stands in only for a successor with stickers
    /// of its own. Reading the counter makes a silent retirement re-evaluate.
    private func displacedResident(_ inputs: RenderInputs) -> Text? {
        _ = predecessorRetirements
        return inputs.emotes.isEmpty ? nil : residentMemo.predecessor
    }

    /// The body shares one resolved face with Text and its emote metrics.
    private var resolvedFont: UIFont { font.uiFont(for: dynamicTypeSize) }

    var body: some View {
        let _ = UIHitchMonitor.countBody("emote")
        let metrics = resolvedFont
        let inputs = RenderInputs(
            content: preparedContent,
            accent: Color.biliAccent,
            height: metrics.emoteBoxHeight,
            baselineOffset: metrics.emoteBaselineOffset,
            scale: displayScale
        )
        let key = RenderKey(inputs)
        // Resident first: it is the final output for THIS key, while `rendered`
        // may still hold a predecessor's Text until its replacement publishes.
        let resident = inputs.emotes.isEmpty ? nil : residentMemo.text(for: key) {
            Self.residentImages(inputs).flatMap { Self.assemble(inputs, images: $0) }
        }
        let substituted = resident ?? rendered ?? displacedResident(inputs)
        // Retainable only when the drawn Text is determined by the key: the
        // complete resident assembly, or the plain fallback.
        let verdictIsRetainable = leadingText == nil && (resident != nil || substituted == nil)
        let bodyText = (substituted ?? fallbackMemo.text(
            for: preparedContent, accent: inputs.accent
        )).font(Font(metrics))
        let text = leadingText.map { $0 + bodyText } ?? bodyText
        Group {
            if let limit = collapsedLineLimit, needsCollapseMeasurement {
                EmoteTextCollapsibleContent(
                    text: text, limit: limit, isExpanded: $isExpanded,
                    verdictKey: verdictIsRetainable ? .init(
                        message: preparedContent.message,
                        substitutesStickers: resident != nil,
                        fontName: metrics.fontName,
                        pointSize: metrics.pointSize,
                        limit: limit
                    ) : nil
                )
            } else {
                text.fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: key) {
            guard !Task.isCancelled else { return }
            // Lazy rows retain State, so an emote-free successor must clear it.
            // Unchanged writes are skipped so an emote-free row costs no extra pass.
            guard !inputs.emotes.isEmpty else {
                residentMemo.retirePredecessor()
                if rendered != nil { rendered = nil }
                return
            }
            // The body already draws this key's final Text from resident images;
            // only drop a predecessor's retained Text, never rebuild.
            if residentMemo.hasText(for: key) {
                if rendered != nil { rendered = nil }
                return
            }
            // Keep the previous Text visible until an eligible replacement.
            let result = await Self.build(inputs)
            guard !Task.isCancelled else { return }
            let retiredVisible = residentMemo.retirePredecessor()
            // An unchanged nil (no substitutable token, or every image failed
            // with nothing retained) is not written, so it costs no extra pass.
            if result != nil || rendered != nil {
                rendered = result
            } else if retiredVisible {
                predecessorRetirements &+= 1
            }
        }
    }

    /// Cheap pre-filter so the probe machinery only mounts for messages
    /// that could plausibly exceed the limit: ~18 chars/line is a CJK
    /// floor at .subheadline in the narrowest indented comment column.
    /// Latin text fits more per line — that only costs a harmless extra
    /// probe, never a missed collapse.
    private static func mightExceed(_ limit: Int, message: String) -> Bool {
        guard limit > 0 else { return true }
        let threshold = limit * 18
        var characterCount = 0
        var newlineCount = 0
        var lastNewlineWasCarriageReturn = false
        for character in message {
            characterCount += 1
            if characterCount > threshold { return true }
            if character.isNewline {
                // Filtering can join CR/LF across discarded non-newline text.
                if !lastNewlineWasCarriageReturn || character != "\n" {
                    newlineCount += 1
                }
                lastNewlineWasCarriageReturn = character == "\r"
                if newlineCount + 1 > limit { return true }
            }
        }
        return false
    }

    private static func referencedEmotes(
        in message: String, emotes: [String: String]
    ) -> [(token: String, url: String)] {
        var matches: [(token: String, url: String)] = []
        var seen: Set<String> = []
        var remaining = Substring(message)
        while let start = remaining.firstIndex(of: "[") {
            guard let end = remaining[start...].firstIndex(of: "]") else { break }
            let token = String(remaining[start ... end])
            if let url = emotes[token], seen.insert(token).inserted {
                matches.append((token, url))
            }
            // Consume unknown/nested candidates exactly as the assembly does.
            remaining = remaining[remaining.index(after: end)...]
        }
        return matches
    }

    private static func build(_ inputs: RenderInputs) async -> Text? {
        guard !Task.isCancelled else { return nil }
        let candidates = referencedEmotes(in: inputs.message, emotes: inputs.emotes)
        guard !candidates.isEmpty else { return nil }
        var images: [String: UIImage] = [:]
        if candidates.count == 1 {
            let (token, url) = candidates[0]
            if let image = await EmoteImageLoader.shared.image(
                for: url, height: inputs.height, scale: inputs.scale
            ) {
                guard !Task.isCancelled else { return nil }
                images[token] = image
            }
        } else {
            let height = inputs.height
            let scale = inputs.scale
            await withTaskGroup(of: (String, UIImage?).self) { group in
                for (token, url) in candidates {
                    group.addTask {
                        let image = await EmoteImageLoader.shared.image(
                            for: url, height: height, scale: scale
                        )
                        return (token, image)
                    }
                }
                for await (token, image) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if let image {
                        images[token] = image
                    }
                }
            }
            guard !Task.isCancelled else { return nil }
        }
        return assemble(inputs, images: images)
    }

    /// Every referenced sticker, if ALL are resident at this height; otherwise
    /// nil, so a partially resident message never draws a half-substituted
    /// frame — the async path publishes it once, as before.
    private static func residentImages(_ inputs: RenderInputs) -> [String: UIImage]? {
        let candidates = referencedEmotes(in: inputs.message, emotes: inputs.emotes)
        guard !candidates.isEmpty else { return nil }
        var images: [String: UIImage] = [:]
        for (token, url) in candidates {
            guard let image = EmoteImageLoader.shared.residentImage(
                for: url, height: inputs.height
            ) else {
                return nil
            }
            images[token] = image
        }
        return images
    }

    /// Splices loaded stickers into the message. Shared by the async build and
    /// the resident first-frame path so both produce identical Text.
    private static func assemble(_ inputs: RenderInputs, images: [String: UIImage]) -> Text? {
        // No actual image uses the whole-message plain/linkified fallback.
        guard !images.isEmpty else { return nil }

        let links = inputs.links
        let accent = inputs.accent
        var result = Text(verbatim: "")
        var remaining = Substring(inputs.message)
        while let start = remaining.firstIndex(of: "[") {
            guard let end = remaining[start...].firstIndex(of: "]") else { break }
            let token = String(remaining[start ... end])
            if let image = images[token] {
                result = result + linkified(
                    String(remaining[..<start]), links: links, accent: accent
                )
                // Zero-width space preserves outer line metrics on emote-only lines while
                // `EmoteTextFont.inlineAttachment` avoids inheriting descent when shifted by `.baselineOffset`.
                result = result
                    + Text(verbatim: "\u{200B}")
                    + Text(Image(uiImage: image))
                        .font(EmoteTextFont.inlineAttachment)
                        .baselineOffset(inputs.baselineOffset)
                remaining = remaining[remaining.index(after: end)...]
            } else {
                // Not an emote — emit through the "]" and keep scanning.
                result = result + linkified(
                    String(remaining[...end]), links: links, accent: accent
                )
                remaining = remaining[remaining.index(after: end)...]
            }
        }
        result = result + linkified(String(remaining), links: links, accent: accent)
        return result
    }

    /// Compiled once and kept `nonisolated` for pure timestamp scanning off the main actor.
    nonisolated private static let timestampRegex = try? NSRegularExpression(
        pattern: "(?<![0-9:])([0-9]{1,2}):([0-5][0-9])(?::([0-5][0-9]))?(?![0-9:])"
    )

    /// Bounded memo (`<= 1024` entries) mapping message strings to detected timestamp links.
    nonisolated private static let timestampCache = OSAllocatedUnfairLock(
        initialState: [String: [String: URL]]()
    )

    /// "1:23" / "01:23" / "1:02:03" → swiftpili://seek/<seconds> links.
    /// NSRegularExpression, not Swift Regex: the lookarounds that keep
    /// "12:34:56.789" and IP:port-ish strings from half-matching need
    /// ICU. Minutes/seconds are 0–59-validated; RootView's handler
    /// range-checks against the playing video's duration.
    nonisolated static func timestampLinks(in text: String) -> [String: URL] {
        guard text.contains(":") || text.contains("：") else { return [:] }
        if let cached = timestampCache.withLock({ $0[text] }) { return cached }
        guard let regex = timestampRegex else { return [:] }
        var found: [String: URL] = [:]
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            let first = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let second = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let seconds: Int
            if match.range(at: 3).location != NSNotFound {
                let third = Int(ns.substring(with: match.range(at: 3))) ?? 0
                seconds = first * 3600 + second * 60 + third
            } else {
                seconds = first * 60 + second
            }
            found[token] = URL(string: "swiftpili://seek/\(seconds)")
        }
        // Frozen copy: withLock's closure is @Sendable and may not
        // capture the mutable `found` (Swift 6), only a let.
        let links = found
        timestampCache.withLock {
            if $0.count >= 1024 { $0.removeAll(keepingCapacity: true) }
            $0[text] = links
        }
        return links
    }

    /// One piece of a linkified message: plain when `url` is nil.
    struct LinkRun: Equatable, Sendable {
        let text: String
        let url: URL?
    }

    /// Splits `text` into plain and linked runs in a single left-to-right pass, bucketing keys by first character and preferring longer matches on ties.
    nonisolated static func linkRuns(_ text: String, links: [String: URL]) -> [LinkRun] {
        guard !text.isEmpty else { return [] }
        guard !links.isEmpty else { return [LinkRun(text: text, url: nil)] }

        var buckets: [Character: [(key: String, url: URL)]] = [:]
        for (key, url) in links {
            guard let first = key.first else { continue }
            buckets[first, default: []].append((key, url))
        }
        for first in buckets.keys where buckets[first]!.count > 1 {
            buckets[first]!.sort { $0.key.count > $1.key.count }
        }

        var runs: [LinkRun] = []
        var plainStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            guard let candidates = buckets[text[index]] else {
                text.formIndex(after: &index)
                continue
            }
            let tail = text[index...]
            guard let hit = candidates.first(where: { tail.hasPrefix($0.key) }) else {
                text.formIndex(after: &index)
                continue
            }
            if plainStart < index {
                runs.append(LinkRun(text: String(text[plainStart ..< index]), url: nil))
            }
            let end = text.index(index, offsetBy: hit.key.count)
            runs.append(LinkRun(text: String(text[index ..< end]), url: hit.url))
            index = end
            plainStart = end
        }
        if plainStart < text.endIndex {
            runs.append(LinkRun(text: String(text[plainStart...]), url: nil))
        }
        return runs
    }

    /// Plain text with the link substrings emitted as tappable,
    /// accent-tinted runs (AttributedString .link inside Text).
    ///
    /// The MainActor body captures the observable accent for fallback and build.
    /// Passing it explicitly keeps this nonisolated assembler from rereading
    /// AccentStore or applying a different color than the rendered task's key.
    nonisolated static func linkified(
        _ text: String,
        links: [String: URL],
        accent: Color,
        cache: EmoteLinkRunCache = .shared
    ) -> Text {
        guard !links.isEmpty, !text.isEmpty else { return Text(verbatim: text) }
        let runs = UIHitchMonitor.measure("linkify") { cache.runs(text, links: links) }
        // Nothing matched: skip the Text concatenation entirely — this is
        // the overwhelmingly common case (a comment whose links dictionary
        // is non-empty but whose text carries none of them).
        guard runs.contains(where: { $0.url != nil }) else { return Text(verbatim: text) }
        var result = Text(verbatim: "")
        for run in runs {
            guard let url = run.url else {
                result = result + Text(verbatim: run.text)
                continue
            }
            var attributed = AttributedString(run.text)
            attributed.link = url
            attributed.foregroundColor = accent
            result = result + Text(attributed)
        }
        return result
    }
}
