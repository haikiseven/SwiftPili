import ImageIO
import Kingfisher
import os
import SwiftUI
import UIKit

struct EmoteTextFont: Equatable {
    let size: CGFloat
    let weight: UIFont.Weight
    let textStyle: UIFont.TextStyle

    static var subheadline: Self { Self(size: 15, weight: .regular, textStyle: .subheadline) }
    static var footnote: Self { Self(size: 13, weight: .regular, textStyle: .footnote) }
    static var caption: Self { Self(size: 12, weight: .regular, textStyle: .caption1) }

    static func app(_ style: AppTextStyle) -> Self {
        Self(size: style.nominalPointSize, weight: style.uiFontWeight, textStyle: style.uiTextStyle)
    }

    static func points(
        _ size: CGFloat,
        weight: UIFont.Weight = .regular,
        relativeTo textStyle: UIFont.TextStyle
    ) -> Self {
        Self(size: size, weight: weight, textStyle: textStyle)
    }

    func weighted(_ weight: UIFont.Weight) -> Self {
        Self(size: size, weight: weight, textStyle: textStyle)
    }

    static let inlineAttachment: Font = Font(UIFont.systemFont(ofSize: 0.1))

    private struct FontCacheKey: Hashable, Sendable {
        let size: CGFloat
        let weightRaw: CGFloat
        let textStyleRaw: String
        let categoryRaw: String
    }

    private static let scaledFontCache = OSAllocatedUnfairLock(
        uncheckedState: [FontCacheKey: UIFont]()
    )

    var uiFont: UIFont {
        scaledFont(compatibleWith: nil)
    }

    func uiFont(for dynamicTypeSize: DynamicTypeSize) -> UIFont {
        let category = dynamicTypeSize.uiContentSizeCategory
        let key = FontCacheKey(
            size: size,
            weightRaw: weight.rawValue,
            textStyleRaw: textStyle.rawValue,
            categoryRaw: category.rawValue
        )
        if let cached = Self.scaledFontCache.withLockUnchecked({ $0[key] }) {
            return cached
        }
        let font = scaledFont(compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        Self.scaledFontCache.withLockUnchecked { cache in
            if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
            cache[key] = font
        }
        return font
    }

    private func scaledFont(compatibleWith traits: UITraitCollection?) -> UIFont {
        UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: .systemFont(ofSize: size, weight: weight),
            compatibleWith: traits
        )
    }

    var swiftUIFont: Font { Font(uiFont) }
}

extension DynamicTypeSize {
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

extension AppTextStyle {
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
    var emoteBoxHeight: CGFloat { ceil((ascender - descender) * 2) / 2 }
    var emoteBaselineOffset: CGFloat { (ascender + descender - emoteBoxHeight) * 0.5 }
}

actor EmoteImageLoader {
    static let shared = EmoteImageLoader()

    private static let maxEntries = 256

    private struct CacheKey: Hashable, Sendable {
        let url: String
        let heightTenths: Int
        let baselineHundredths: Int

        init(_ urlString: String, height: CGFloat, baselineFromBottom: CGFloat) {
            url = urlString
            heightTenths = Int((height * 10).rounded())
            baselineHundredths = Int((baselineFromBottom * 100).rounded())
        }
    }

    private struct ResidentState: Sendable {
        var map: [CacheKey: UIImage] = [:]
        var accessGen: [CacheKey: UInt64] = [:]
        var nextGen: UInt64 = 0

        mutating func get(_ key: CacheKey) -> UIImage? {
            guard let image = map[key] else { return nil }
            nextGen &+= 1
            accessGen[key] = nextGen
            return image
        }

        mutating func store(_ key: CacheKey, image: UIImage, maxEntries: Int) {
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

    private let resident = OSAllocatedUnfairLock(initialState: ResidentState())
    private var inflight: [CacheKey: Task<UIImage?, Never>] = [:]

    func image(
        for urlString: String, height: CGFloat, baselineFromBottom: CGFloat = 0, scale: CGFloat = 3.0
    ) async -> UIImage? {
        let key = CacheKey(urlString, height: height, baselineFromBottom: baselineFromBottom)
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

    nonisolated func residentImage(
        for urlString: String, height: CGFloat, baselineFromBottom: CGFloat = 0
    ) -> UIImage? {
        let key = CacheKey(urlString, height: height, baselineFromBottom: baselineFromBottom)
        return resident.withLock { $0.get(key) }
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
        let left = lhs.utf8
        let right = rhs.utf8
        guard left.count == right.count else { return false }
        return left.elementsEqual(right)
    }

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

@MainActor
private final class EmoteTextResidentMemo<Key: Equatable> {
    private var entry: (key: Key, text: Text?)?
    private(set) var predecessor: Text?

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

    @discardableResult
    func retirePredecessor() -> Bool {
        defer { predecessor = nil }
        return predecessor != nil
    }
}

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

@MainActor
private enum EmoteTextOverflowVerdicts {
    struct Key: Hashable {
        let message: String
        let substitutesStickers: Bool
        let fontName: String
        let pointSize: CGFloat
        let limit: Int
    }

    private static let maxEntries = 512
    private static var entries: [Key: EmoteTextOverflowVerdict] = [:]
    private static var order: [Key] = []

    static func lastVerdict(for key: Key) -> Bool? { entries[key]?.isTruncated }

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

@MainActor
final class LinkAwareTapScope {
    weak var parent: LinkAwareTapScope?
    private var descendantClaimedAt: CFTimeInterval = -.greatestFiniteMagnitude
    private var subtreeSuppressedAt: CFTimeInterval = -.greatestFiniteMagnitude
    private var pendingToken: UInt64 = 0

    func attach(parent: LinkAwareTapScope?) {
        guard parent !== self else { return }
        self.parent = parent
    }

    func claimFromDescendant() {
        descendantClaimedAt = CACurrentMediaTime()
        pendingToken &+= 1
        parent?.claimFromDescendant()
    }

    func suppressAroundGesture() {
        let now = CACurrentMediaTime()
        descendantClaimedAt = now
        subtreeSuppressedAt = now
        pendingToken &+= 1
        parent?.claimFromDescendant()
    }

    private func isSuppressedByAncestor(at now: CFTimeInterval) -> Bool {
        if now - subtreeSuppressedAt < 0.12 { return true }
        return parent?.isSuppressedByAncestor(at: now) ?? false
    }

    private func isBlocked(at now: CFTimeInterval) -> Bool {
        if now - descendantClaimedAt < 0.08 { return true }
        return isSuppressedByAncestor(at: now)
    }

    func scheduleFallbackTap(_ action: @escaping @MainActor () -> Void) {
        let now = CACurrentMediaTime()
        guard !isBlocked(at: now) else { return }
        parent?.claimFromDescendant()
        pendingToken &+= 1
        let token = pendingToken
        scheduleMainRunloopTurn { [weak self] in
            guard let self,
                  self.pendingToken == token,
                  !self.isBlocked(at: CACurrentMediaTime()) else { return }
            action()
        }
    }
}

private struct LinkAwareTapScopeKey: EnvironmentKey {
    static let defaultValue: LinkAwareTapScope? = nil
}

extension EnvironmentValues {
    var linkAwareTapScope: LinkAwareTapScope? {
        get { self[LinkAwareTapScopeKey.self] }
        set { self[LinkAwareTapScopeKey.self] = newValue }
    }
}

private struct LinkAwareTapModifier: ViewModifier {
    let isEnabled: Bool
    let action: @MainActor () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.linkAwareTapScope) private var parentScope
    @State private var scope = LinkAwareTapScope()

    func body(content: Content) -> some View {
        let _ = scope.attach(parent: parentScope)
        content
            .environment(\.linkAwareTapScope, scope)
            .environment(\.openURL, OpenURLAction { url in
                scope.claimFromDescendant()
                openURL(url)
                return .handled
            })
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard isEnabled else { return }
                    scope.scheduleFallbackTap(action)
                },
                including: isEnabled ? .all : .subviews
            )
    }
}

private struct LinkAwareLongPressModifier: ViewModifier {
    let minimumDuration: Double
    let action: @MainActor () -> Void
    @Environment(\.linkAwareTapScope) private var parentScope
    @State private var scope = LinkAwareTapScope()
    @State private var longPressFired = false

    func body(content: Content) -> some View {
        let _ = scope.attach(parent: parentScope)
        content
            .environment(\.linkAwareTapScope, scope)
            .onLongPressGesture(minimumDuration: minimumDuration) {
                longPressFired = true
                scope.suppressAroundGesture()
                action()
            } onPressingChanged: { pressing in
                if pressing {
                    longPressFired = false
                } else if longPressFired {
                    scope.suppressAroundGesture()
                    longPressFired = false
                }
            }
    }
}

extension View {
    func linkAwareTap(
        isEnabled: Bool = true,
        perform action: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(LinkAwareTapModifier(isEnabled: isEnabled, action: action))
    }

    func linkAwareLongPress(
        minimumDuration: Double = 0.4,
        perform action: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(LinkAwareLongPressModifier(minimumDuration: minimumDuration, action: action))
    }
}

private struct EmoteTextCollapsibleContent: View {
    @AppMotion private var motion
    @Environment(\.linkAwareTapScope) private var parentTapScope
    let text: Text
    let limit: Int
    @Binding var isExpanded: Bool
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
                .linkAwareTap(isEnabled: isTruncated || isExpanded) {
                    withAnimation(motion.animation(normal: .easeInOut(duration: 0.2))) { isExpanded.toggle() }
                }

            if isTruncated || isExpanded {
                Button {
                    parentTapScope?.claimFromDescendant()
                    withAnimation(motion.animation(normal: .easeInOut(duration: 0.2))) { isExpanded.toggle() }
                } label: {
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

    private static func verdict(
        width: CGFloat, fullHeight: CGFloat, collapsedHeight: CGFloat
    ) -> EmoteTextOverflowVerdict? {
        guard width.isFinite, width > 0,
              fullHeight.isFinite, fullHeight > 0,
              collapsedHeight.isFinite, collapsedHeight > 0 else { return nil }
        return EmoteTextOverflowVerdict(width: width, isTruncated: fullHeight > collapsedHeight + 1)
    }
}

struct EmoteText: View {
    let message: String
    let emotes: [String: String]
    let links: [String: URL]
    var font: EmoteTextFont = .subheadline
    let collapsedLineLimit: Int?

    let detectTimestamps: Bool
    var leadingText: Text?

    private let preparedContent: EmoteTextPreparedContent
    private let needsCollapseMeasurement: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @State private var rendered: Text?
    @State private var fallbackMemo = EmoteTextFallbackMemo()
    @State private var residentMemo = EmoteTextResidentMemo<RenderKey>()
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

    private func displacedResident(_ inputs: RenderInputs) -> Text? {
        _ = predecessorRetirements
        return inputs.emotes.isEmpty ? nil : residentMemo.predecessor
    }

    private var resolvedFont: UIFont { font.uiFont(for: dynamicTypeSize) }

    var body: some View {
        let metrics = resolvedFont
        let inputs = RenderInputs(
            content: preparedContent,
            accent: Color.biliAccent,
            height: metrics.emoteBoxHeight,
            baselineOffset: metrics.emoteBaselineOffset,
            scale: displayScale
        )
        let key = RenderKey(inputs)
        let resident = inputs.emotes.isEmpty ? nil : residentMemo.text(for: key) {
            Self.residentImages(inputs).flatMap { Self.assemble(inputs, images: $0) }
        }
        let substituted = resident ?? rendered ?? displacedResident(inputs)
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
            guard !inputs.emotes.isEmpty else {
                residentMemo.retirePredecessor()
                if rendered != nil { rendered = nil }
                return
            }
            if residentMemo.hasText(for: key) {
                if rendered != nil { rendered = nil }
                return
            }
            let result = await Self.build(inputs)
            guard !Task.isCancelled else { return }
            let retiredVisible = residentMemo.retirePredecessor()
            if result != nil || rendered != nil {
                rendered = result
            } else if retiredVisible {
                predecessorRetirements &+= 1
            }
        }
    }

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
        guard !emotes.isEmpty, message.utf8.contains(0x5B) else { return [] }
        var matches: [(token: String, url: String)] = []
        var seen: Set<String> = []
        var remaining = Substring(message)
        while let start = remaining.firstIndex(of: "[") {
            guard let end = remaining[start...].firstIndex(of: "]") else { break }
            let token = String(remaining[start ... end])
            if let url = emotes[token], seen.insert(token).inserted {
                matches.append((token, url))
            }
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

    private static func assemble(_ inputs: RenderInputs, images: [String: UIImage]) -> Text? {
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
                result = result
                    + Text(verbatim: "\u{200B}")
                    + Text(Image(uiImage: image))
                        .font(EmoteTextFont.inlineAttachment)
                        .baselineOffset(inputs.baselineOffset)
                remaining = remaining[remaining.index(after: end)...]
            } else {
                result = result + linkified(
                    String(remaining[...end]), links: links, accent: accent
                )
                remaining = remaining[remaining.index(after: end)...]
            }
        }
        result = result + linkified(String(remaining), links: links, accent: accent)
        return result
    }

    nonisolated private static let timestampRegex = try? NSRegularExpression(
        pattern: "(?<![0-9:])([0-9]{1,2}):([0-5][0-9])(?::([0-5][0-9]))?(?![0-9:])"
    )

    nonisolated private static let timestampCache = OSAllocatedUnfairLock(
        initialState: [String: [String: URL]]()
    )

    nonisolated private static func hasDigitColonDigit(_ text: String) -> Bool {
        var prevIsDigit = false
        var sawDigitColon = false
        for byte in text.utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            if sawDigitColon, isDigit { return true }
            sawDigitColon = prevIsDigit && byte == 0x3A // ':'
            prevIsDigit = isDigit
        }
        return false
    }

    nonisolated static func timestampLinks(in text: String) -> [String: URL] {
        guard hasDigitColonDigit(text) else { return [:] }
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
        let links = found
        timestampCache.withLock {
            if $0.count >= 1024 { $0.removeAll(keepingCapacity: true) }
            $0[text] = links
        }
        return links
    }

    struct LinkRun: Equatable, Sendable {
        let text: String
        let url: URL?
    }

    nonisolated static func linkRuns(_ text: String, links: [String: URL]) -> [LinkRun] {
        guard !text.isEmpty else { return [] }
        guard !links.isEmpty else { return [LinkRun(text: text, url: nil)] }

        if links.count == 1, let (key, url) = links.first, !key.isEmpty {
            if text == key {
                return [LinkRun(text: text, url: url)]
            }
            var runs: [LinkRun] = []
            var searchStart = text.startIndex
            while let range = text.range(of: key, options: .literal, range: searchStart ..< text.endIndex) {
                if searchStart < range.lowerBound {
                    runs.append(LinkRun(text: String(text[searchStart ..< range.lowerBound]), url: nil))
                }
                runs.append(LinkRun(text: key, url: url))
                searchStart = range.upperBound
            }
            if runs.isEmpty {
                return [LinkRun(text: text, url: nil)]
            }
            if searchStart < text.endIndex {
                runs.append(LinkRun(text: String(text[searchStart...]), url: nil))
            }
            return runs
        }

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

    nonisolated static func linkified(
        _ text: String,
        links: [String: URL],
        accent: Color,
        cache: EmoteLinkRunCache = .shared
    ) -> Text {
        guard !links.isEmpty, !text.isEmpty else { return Text(verbatim: text) }
        if links.count == 1, let url = links[text] {
            var attributed = AttributedString(text)
            attributed.link = url
            attributed.foregroundColor = accent
            return Text(attributed)
        }
        let runs = cache.runs(text, links: links)
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
