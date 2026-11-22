import UIKit

/// Extracts all cover, avatar, draw, and quoted image prefetch requests for a
/// `DynamicFeedResult.DynamicItem` so `UIKitPrefetchCoordinator` warms them
/// ahead of scroll.
enum UIKitDynamicCardMediaExtractor {
    @MainActor
    static func coverRequests(
        for item: DynamicFeedResult.DynamicItem,
        cardWidth: CGFloat,
        scale: CGFloat
    ) -> [UIKitCoverPipeline.CoverRequest] {
        var requests: [UIKitCoverPipeline.CoverRequest] = []
        let safeScale = scale > 0 ? scale : 1

        if let face = item.modules?.moduleAuthor?.face {
            let avatar = UIKitCoverPipeline.avatarRequest(
                urlString: face, pointSize: 38, scale: safeScale
            )
            if avatar.url != nil { requests.append(avatar) }
        }

        let innerWidth = max(160, cardWidth - 32)
        appendSourceRequests(for: item, width: innerWidth, quoted: false, scale: safeScale, into: &requests)

        let quotedWidth = max(160, innerWidth - 26)
        var next = item.orig?.item
        while let quoted = next {
            appendSourceRequests(for: quoted, width: quotedWidth, quoted: true, scale: safeScale, into: &requests)
            next = quoted.orig?.item
        }
        return requests
    }

    @MainActor
    private static func appendSourceRequests(
        for owner: DynamicFeedResult.DynamicItem,
        width: CGFloat,
        quoted: Bool,
        scale: CGFloat,
        into requests: inout [UIKitCoverPipeline.CoverRequest]
    ) {
        let dynamic = owner.modules?.moduleDynamic
        if let descNodes = dynamic?.desc?.richTextNodes {
            appendInlinePictureRequests(nodes: descNodes, width: width, scale: scale, into: &requests)
        }
        guard let major = dynamic?.major else { return }

        if let cover = major.archive?.cover ?? major.ugcSeason?.cover, !cover.isEmpty {
            let boxWidth = quoted ? min(132, width) : width
            appendCoverRequest(cover, boxWidth: boxWidth, scale: scale, into: &requests)
        } else if let cover = major.pgc?.cover ?? major.common?.cover
            ?? major.article?.covers?.first ?? major.liveRcmd?.parsed.cover, !cover.isEmpty {
            let boxWidth = quoted ? min(132, width) : min(320, width)
            appendCoverRequest(cover, boxWidth: boxWidth, scale: scale, into: &requests)
        }

        if let drawItems = major.draw?.items, !drawItems.isEmpty {
            let media = drawItems.compactMap { item -> UIKitDynamicDrawGridView.MediaItem? in
                guard let src = item.src, let url = URL(string: src.httpsURL) else { return nil }
                let size: CGSize? = (item.width ?? 0) > 0 && (item.height ?? 0) > 0
                    ? CGSize(width: item.width ?? 0, height: item.height ?? 0) : nil
                return UIKitDynamicDrawGridView.MediaItem(url: url, pixelSize: size)
            }
            requests.append(contentsOf: UIKitDynamicDrawGridView.coverRequests(
                for: media, availableWidth: width, scale: scale
            ))
        }

        if let opus = major.opus {
            if let summaryNodes = opus.summary?.richTextNodes {
                appendInlinePictureRequests(nodes: summaryNodes, width: width, scale: scale, into: &requests)
            }
            if let pics = opus.pics, !pics.isEmpty {
                let media = pics.compactMap { pic -> UIKitDynamicDrawGridView.MediaItem? in
                    guard let urlStr = pic.url, let url = URL(string: urlStr.httpsURL) else { return nil }
                    let size: CGSize? = (pic.width ?? 0) > 0 && (pic.height ?? 0) > 0
                        ? CGSize(width: pic.width ?? 0, height: pic.height ?? 0) : nil
                    return UIKitDynamicDrawGridView.MediaItem(url: url, pixelSize: size)
                }
                requests.append(contentsOf: UIKitDynamicDrawGridView.coverRequests(
                    for: media, availableWidth: width, scale: scale
                ))
            }
        }
    }

    @MainActor
    private static func appendInlinePictureRequests(
        nodes: [DynamicRichContent.Node],
        width: CGFloat,
        scale: CGFloat,
        into requests: inout [UIKitCoverPipeline.CoverRequest]
    ) {
        for block in DynamicRichContent.blocks(text: nil, nodes: nodes) {
            guard case let .pictures(attachment) = block else { continue }
            let media = UIKitDynamicRichTextBuilder.mediaItems(from: attachment.node.pics ?? [])
            if !media.isEmpty {
                requests.append(contentsOf: UIKitDynamicDrawGridView.coverRequests(
                    for: media, availableWidth: width, scale: scale
                ))
            }
        }
    }

    private static func appendCoverRequest(
        _ cover: String,
        boxWidth: CGFloat,
        scale: CGFloat,
        into requests: inout [UIKitCoverPipeline.CoverRequest]
    ) {
        let height = (boxWidth * 76.0 / 136.0).rounded()
        let req = UIKitCoverPipeline.request(
            urlString: cover,
            drawnBox: CGSize(width: boxWidth, height: height),
            displayMode: .fill,
            scale: scale
        )
        if req.url != nil { requests.append(req) }
    }
}

/// Static geometric skeleton matching `DynamicCardPlaceholder` dimensions
/// (zero `.redacted`, zero shimmer).
@MainActor
final class UIKitDynamicSkeletonCell: UICollectionViewCell {
    private final class CapsuleStubView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = bounds.height / 2
        }
    }

    private let platter = UIView()
    private let avatarShape = UIView()
    private let nameShape = UIView()
    private let metaShape = UIView()
    private let line1 = UIView()
    private let line2 = UIView()
    private let line3 = UIView()
    private let actionsRow = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isUserInteractionEnabled = false

        platter.translatesAutoresizingMaskIntoConstraints = false
        platter.backgroundColor = .secondarySystemGroupedBackground
        platter.layer.cornerRadius = AppRadius.panel
        platter.layer.cornerCurve = .continuous
        contentView.addSubview(platter)

        avatarShape.translatesAutoresizingMaskIntoConstraints = false
        avatarShape.backgroundColor = .secondarySystemFill
        avatarShape.layer.cornerRadius = 19

        for shape in [nameShape, metaShape, line1, line2, line3] {
            shape.translatesAutoresizingMaskIntoConstraints = false
            shape.backgroundColor = .secondarySystemFill
            shape.layer.cornerRadius = AppRadius.badge
            shape.layer.cornerCurve = .continuous
        }
        metaShape.alpha = 0.65

        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        actionsRow.axis = .horizontal
        actionsRow.spacing = 8
        actionsRow.distribution = .fillEqually
        for _ in 0 ..< 3 {
            let slot = UIView()
            let pill = CapsuleStubView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.backgroundColor = .quaternarySystemFill
            pill.layer.cornerCurve = .continuous
            slot.addSubview(pill)
            NSLayoutConstraint.activate([
                slot.heightAnchor.constraint(equalToConstant: 44),
                pill.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                pill.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                pill.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                pill.heightAnchor.constraint(equalToConstant: 32),
            ])
            actionsRow.addArrangedSubview(slot)
        }

        [avatarShape, nameShape, metaShape, line1, line2, line3, actionsRow].forEach {
            platter.addSubview($0)
        }
        activateConstraints()
    }

    private func activateConstraints() {
        NSLayoutConstraint.activate([
            platter.topAnchor.constraint(equalTo: contentView.topAnchor),
            platter.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            platter.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            platter.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            avatarShape.topAnchor.constraint(equalTo: platter.topAnchor, constant: 14),
            avatarShape.leadingAnchor.constraint(equalTo: platter.leadingAnchor, constant: 16),
            avatarShape.widthAnchor.constraint(equalToConstant: 38),
            avatarShape.heightAnchor.constraint(equalToConstant: 38),
            nameShape.topAnchor.constraint(equalTo: avatarShape.topAnchor, constant: 2),
            nameShape.leadingAnchor.constraint(equalTo: avatarShape.trailingAnchor, constant: 10),
            nameShape.widthAnchor.constraint(equalToConstant: 124),
            nameShape.heightAnchor.constraint(equalToConstant: 16),
            metaShape.topAnchor.constraint(equalTo: nameShape.bottomAnchor, constant: 5),
            metaShape.leadingAnchor.constraint(equalTo: nameShape.leadingAnchor),
            metaShape.widthAnchor.constraint(equalToConstant: 72),
            metaShape.heightAnchor.constraint(equalToConstant: 12),
            line1.topAnchor.constraint(equalTo: avatarShape.bottomAnchor, constant: 10),
            line1.leadingAnchor.constraint(equalTo: platter.leadingAnchor, constant: 16),
            line1.trailingAnchor.constraint(equalTo: platter.trailingAnchor, constant: -16),
            line1.heightAnchor.constraint(equalToConstant: 15),
            line2.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 8),
            line2.leadingAnchor.constraint(equalTo: line1.leadingAnchor),
            line2.trailingAnchor.constraint(equalTo: line1.trailingAnchor, constant: -24),
            line2.heightAnchor.constraint(equalToConstant: 15),
            line3.topAnchor.constraint(equalTo: line2.bottomAnchor, constant: 8),
            line3.leadingAnchor.constraint(equalTo: line1.leadingAnchor),
            line3.widthAnchor.constraint(equalToConstant: 180),
            line3.heightAnchor.constraint(equalToConstant: 15),
            actionsRow.topAnchor.constraint(equalTo: line3.bottomAnchor, constant: 10),
            actionsRow.leadingAnchor.constraint(equalTo: platter.leadingAnchor, constant: 16),
            actionsRow.trailingAnchor.constraint(equalTo: platter.trailingAnchor, constant: -16),
            actionsRow.bottomAnchor.constraint(equalTo: platter.bottomAnchor, constant: -6),
        ])
    }

    func configure(showsCardBackground: Bool = true, accessibilityLabel: String? = nil) {
        platter.backgroundColor = showsCardBackground ? .secondarySystemGroupedBackground : .clear
        platter.layer.borderWidth = 0
        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
    }
}
