import SwiftUI
import UIKit

/// Pure UIKit rich body view rendering `DynamicRichContent.blocks(text:nodes:)`
/// with inline Bilibili emotes, clickable links, inline picture attachments,
/// Dynamic Type scaling, and truncation disclosure.
@MainActor
final class UIKitDynamicRichTextView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    struct Configuration: Equatable {
        let text: String?
        let nodes: [DynamicRichContent.Node]?
        let sourceID: String?
        var textStyle: UIFont.TextStyle = .body
        var lineSpacing: CGFloat = 3
        var lineLimit: Int?
        var detectTimestamps: Bool = true
        var availableWidth: CGFloat?
    }

    var onOpenPost: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onImageTap: ((ImagePreviewItem) -> Void)?

    private let stackView = UIStackView()
    private let primaryTextView = UITextView()
    private let viewFullTextButton = UIButton(type: .system)

    private var extraViews: [UIView] = []
    private var textViews: [Int: UITextView] = [:]
    private var drawGridViews: [UIKitDynamicDrawGridView] = []
    private var blocks: [DynamicRichContent.Block] = []
    private var configuration: Configuration?
    private var loadedEmotes: [String: UIImage] = [:]
    private var emoteTask: Task<Void, Never>?
    private var emoteToken = UUID()
    private var attachmentTasks: [Int: Task<Void, Never>] = [:]
    private var attachmentToken = UUID()
    private var lastMeasuredWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 12
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        configureTextView(primaryTextView)
        var buttonConfig = UIButton.Configuration.plain()
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 12)
        viewFullTextButton.configuration = buttonConfig
        viewFullTextButton.contentHorizontalAlignment = .leading
        viewFullTextButton.isHidden = true
        viewFullTextButton.addTarget(self, action: #selector(handleOpenPostTap), for: .touchUpInside)

        registerForTraitChanges([
            UITraitPreferredContentSizeCategory.self,
            UITraitUserInterfaceStyle.self,
            UITraitDisplayScale.self,
        ]) { (self: UIKitDynamicRichTextView, _) in
            self.handleTraitsChanged()
        }
    }

    private func configureTextView(_ textView: UITextView) {
        textView.isScrollEnabled = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = self
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTextViewBlankTap(_:)))
        tap.delegate = self
        textView.addGestureRecognizer(tap)
    }

    func configure(_ configuration: Configuration) {
        let sameContent = self.configuration?.text == configuration.text
            && self.configuration?.nodes == configuration.nodes
            && self.configuration?.sourceID == configuration.sourceID
            && self.configuration?.textStyle == configuration.textStyle
        self.configuration = configuration

        if !sameContent {
            emoteTask?.cancel()
            emoteTask = nil
            emoteToken = UUID()
            loadedEmotes.removeAll()
            cancelAttachmentTasks()
            blocks = DynamicRichContent.blocks(text: configuration.text, nodes: configuration.nodes)
        }

        rebuildContentViews()
        startEmoteLoadingIfNeeded()
        updateTruncationState()
    }

    func prepareForReuse() {
        emoteTask?.cancel()
        emoteTask = nil
        emoteToken = UUID()
        loadedEmotes.removeAll()
        cancelAttachmentTasks()
        configuration = nil
        blocks = []
        lastMeasuredWidth = 0
        onOpenPost = nil
        onOpenURL = nil
        onImageTap = nil

        clearArrangedViews()
        primaryTextView.attributedText = nil
        primaryTextView.textContainer.maximumNumberOfLines = 0
        viewFullTextButton.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 1, abs(width - lastMeasuredWidth) > 0.5 else { return }
        lastMeasuredWidth = width
        for gridView in drawGridViews {
            gridView.updateAvailableWidth(width)
        }
        updateTruncationState()
    }

    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case let .link(url) = textItem.content else { return defaultAction }
        return UIAction { [weak self] _ in
            guard let self else { return }
            if let onOpenURL = self.onOpenURL {
                onOpenURL(url)
            } else {
                UIApplication.shared.open(url)
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard onOpenPost != nil, let textView = gestureRecognizer.view as? UITextView else {
            return false
        }
        return !UIKitDynamicRichTextBuilder.hasLink(at: touch.location(in: textView), in: textView)
    }

    func isLinkTouch(_ touch: UITouch) -> Bool {
        for textView in textViews.values where !textView.isHidden {
            let point = touch.location(in: textView)
            if textView.bounds.contains(point),
               UIKitDynamicRichTextBuilder.hasLink(at: point, in: textView) {
                return true
            }
        }
        return false
    }

    @objc private func handleTextViewBlankTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onOpenPost?()
    }

    @objc private func handleOpenPostTap() {
        onOpenPost?()
    }
}

private extension UIKitDynamicRichTextView {
    var effectiveWidth: CGFloat {
        if bounds.width > 1 { return bounds.width }
        if let available = configuration?.availableWidth, available > 1 { return available }
        return max(160, FeedWidth.fullContainerSeed(cappedTo: ReadableWidth.feed) - 64)
    }

    func rebuildContentViews() {
        guard let configuration else { return }
        clearArrangedViews()
        textViews.removeAll()
        drawGridViews.removeAll()

        let resolvedFont = scaledFont(for: configuration.textStyle)
        let accent = UIColor(AccentStore.shared.semanticAccent)
        let width = effectiveWidth
        let textCount = blocks.reduce(0) { count, block in
            if case .text = block { return count + 1 }
            return count
        }

        for block in blocks {
            switch block {
            case let .text(segment):
                let textView = textViews.isEmpty ? primaryTextView : makeDetachedTextView()
                let limit = textCount == 1 ? configuration.lineLimit : nil
                textView.textContainer.maximumNumberOfLines = limit ?? 0
                textView.textContainer.lineBreakMode = limit == nil ? .byWordWrapping : .byTruncatingTail
                textView.linkTextAttributes = [.foregroundColor: accent]
                textView.attributedText = buildAttributed(for: segment, font: resolvedFont, accent: accent)
                stackView.addArrangedSubview(textView)
                if textView !== primaryTextView { extraViews.append(textView) }
                textViews[segment.id] = textView
            case let .pictures(attachment):
                let view = makePictureAttachmentView(attachment, width: width)
                stackView.addArrangedSubview(view)
                extraViews.append(view)
            }
        }

        styleViewFullTextButton(accent: accent)
        stackView.addArrangedSubview(viewFullTextButton)
    }

    func makeDetachedTextView() -> UITextView {
        let view = UITextView()
        configureTextView(view)
        return view
    }

    func clearArrangedViews() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for grid in drawGridViews { grid.prepareForReuse() }
        extraViews.removeAll()
    }

    func buildAttributed(
        for segment: DynamicRichContent.TextSegment,
        font: UIFont,
        accent: UIColor
    ) -> NSAttributedString {
        guard let configuration else { return NSAttributedString() }
        return UIKitDynamicRichTextBuilder.makeAttributedString(
            for: segment,
            options: .init(
                font: font,
                lineSpacing: configuration.lineSpacing,
                accent: accent,
                detectTimestamps: configuration.detectTimestamps
            )
        ) { [weak self] source in
            self?.emoteImage(for: source, font: font)
        }
    }

    func styleViewFullTextButton(accent: UIColor) {
        var config = viewFullTextButton.configuration ?? .plain()
        let font = UIKitFeedFont.systemFont(textStyle: .footnote, weight: .medium, traitCollection: traitCollection)
        config.baseForegroundColor = accent
        config.attributedTitle = AttributedString(
            String(localized: "View Full Text"),
            attributes: AttributeContainer([.font: font, .foregroundColor: accent])
        )
        viewFullTextButton.configuration = config
    }

    func makePictureAttachmentView(_ attachment: DynamicRichContent.Attachment, width: CGFloat) -> UIView {
        let supplied = UIKitDynamicRichTextBuilder.mediaItems(from: attachment.node.pics ?? [])
        if !supplied.isEmpty {
            let grid = makeGridView(items: supplied, width: width)
            drawGridViews.append(grid)
            return grid
        }
        let container = UIView()
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        container.addSubview(spinner)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            spinner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        resolvePictureAttachment(attachment, inside: container)
        return container
    }

    func makeGridView(items: [UIKitDynamicDrawGridView.MediaItem], width: CGFloat) -> UIKitDynamicDrawGridView {
        let grid = UIKitDynamicDrawGridView()
        grid.onImageTap = { [weak self] item in self?.onImageTap?(item) }
        grid.configure(items: items, availableWidth: width)
        return grid
    }

    func resolvePictureAttachment(_ attachment: DynamicRichContent.Attachment, inside container: UIView) {
        guard let rid = attachment.node.rid?.trimmingCharacters(in: .whitespacesAndNewlines), !rid.isEmpty else {
            UIKitDynamicRichTextBuilder.showFallback(
                String(localized: "No images"), inside: container, traitCollection: traitCollection
            )
            return
        }
        let token = attachmentToken
        attachmentTasks[attachment.id] = Task { @MainActor [weak self, weak container] in
            do {
                let pictures = try await DynamicAPI.getPictures(attachmentID: rid)
                guard let self, let container, !Task.isCancelled, self.attachmentToken == token else { return }
                let resolved = UIKitDynamicRichTextBuilder.mediaItems(from: pictures)
                container.subviews.forEach { $0.removeFromSuperview() }
                if !resolved.isEmpty {
                    let grid = self.makeGridView(items: resolved, width: self.effectiveWidth)
                    UIKitDynamicRichTextBuilder.pin(grid, inside: container)
                    self.drawGridViews.append(grid)
                    self.invalidateIntrinsicContentSize()
                } else {
                    UIKitDynamicRichTextBuilder.showFallback(
                        String(localized: "No images"), inside: container, traitCollection: self.traitCollection
                    )
                }
            } catch {
                guard let self, let container, !Task.isCancelled, self.attachmentToken == token,
                      !BiliAPIRetryPolicy.isCancellation(error),
                      (error as? BiliError)?.isCancellation != true else { return }
                UIKitDynamicRichTextBuilder.showFallback(
                    error.localizedDescription, inside: container, traitCollection: self.traitCollection
                )
            }
        }
    }

    func cancelAttachmentTasks() {
        attachmentToken = UUID()
        attachmentTasks.values.forEach { $0.cancel() }
        attachmentTasks.removeAll()
    }

    func emoteImage(for source: String, font: UIFont) -> UIImage? {
        loadedEmotes[source] ?? EmoteImageLoader.shared.residentImage(
            for: source, height: font.emoteBoxHeight
        )
    }

    func startEmoteLoadingIfNeeded() {
        guard let configuration, let nodes = configuration.nodes, !nodes.isEmpty else { return }
        let font = scaledFont(for: configuration.textStyle)
        let height = font.emoteBoxHeight
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3.0

        var missing: [String] = []
        var seen: Set<String> = []
        for node in nodes where node.type == "RICH_TEXT_NODE_TYPE_EMOJI" {
            guard let source = DynamicRichContent.imageURL(node.emoji?.source)?.absoluteString,
                  seen.insert(source).inserted, emoteImage(for: source, font: font) == nil else { continue }
            missing.append(source)
        }
        guard !missing.isEmpty else { return }

        let token = emoteToken
        emoteTask = Task { @MainActor [weak self] in
            var fetched: [String: UIImage] = [:]
            for source in missing {
                guard !Task.isCancelled else { return }
                if let image = await EmoteImageLoader.shared.image(
                    for: source, height: height, scale: scale
                ) {
                    fetched[source] = image
                }
            }
            guard let self, !Task.isCancelled, self.emoteToken == token, !fetched.isEmpty else { return }
            self.loadedEmotes.merge(fetched) { _, new in new }
            self.refreshTextAttributedStrings()
        }
    }

    func refreshTextAttributedStrings() {
        guard let configuration else { return }
        let font = scaledFont(for: configuration.textStyle)
        let accent = UIColor(AccentStore.shared.semanticAccent)
        for block in blocks {
            guard case let .text(segment) = block, let textView = textViews[segment.id] else { continue }
            textView.attributedText = buildAttributed(for: segment, font: font, accent: accent)
        }
        updateTruncationState()
        invalidateIntrinsicContentSize()
    }

    func updateTruncationState() {
        guard let configuration, let limit = configuration.lineLimit, limit > 0,
              onOpenPost != nil, blocks.count == 1, case .text = blocks[0] else {
            viewFullTextButton.isHidden = true
            return
        }
        let width = effectiveWidth
        guard width > 1, let attributed = primaryTextView.attributedText, attributed.length > 0 else {
            viewFullTextButton.isHidden = true
            return
        }
        let truncated = UIKitDynamicRichTextBuilder.isAttributedText(
            attributed, truncatedAtWidth: width, lineLimit: limit
        )
        if viewFullTextButton.isHidden == truncated {
            viewFullTextButton.isHidden = !truncated
            invalidateIntrinsicContentSize()
        }
    }

    func handleTraitsChanged() {
        guard configuration != nil else { return }
        let accent = UIColor(AccentStore.shared.semanticAccent)
        textViews.values.forEach { $0.linkTextAttributes = [.foregroundColor: accent] }
        styleViewFullTextButton(accent: accent)
        refreshTextAttributedStrings()
        startEmoteLoadingIfNeeded()
    }

    func scaledFont(for style: UIFont.TextStyle) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traitCollection)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base, compatibleWith: traitCollection)
    }
}
