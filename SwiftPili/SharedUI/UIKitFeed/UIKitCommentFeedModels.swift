import SwiftUI
import UIKit

struct AnyHashableSendable: Hashable, @unchecked Sendable {
    let base: AnyHashable

    init<T: Hashable & Sendable>(_ value: T) {
        if let existing = value as? AnyHashableSendable {
            self = existing
        } else {
            self.base = AnyHashable(value)
        }
    }
}

struct UIKitCommentItemFingerprint: Hashable, Sendable {
    let rpid: Int
    let like: Int
    let action: Int?
    let rcount: Int
    let isPinned: Bool
    let replyPreviewCount: Int
    let message: String
    let upLiked: Bool?
    let extra: AnyHashableSendable?

    init(
        _ comment: CommentResult.CommentItem,
        extra: AnyHashableSendable? = nil
    ) {
        rpid = comment.rpid
        like = comment.like
        action = comment.action
        rcount = comment.rcount
        isPinned = comment.isPinned
        replyPreviewCount = comment.replies?.count ?? 0
        message = comment.content.displayMessage
        upLiked = comment.upAction?.like
        self.extra = extra
    }
}

struct UIKitCommentFeedItem: Identifiable {
    let id: AnyHashableSendable
    let fingerprint: AnyHashableSendable
    let hasExplicitFingerprint: Bool
    let comment: CommentResult.CommentItem?
    let prefetchAvatarPointSize: CGFloat
    let makeContent: @MainActor () -> AnyView

    init<ID: Hashable & Sendable, F: Hashable & Sendable, Content: View>(
        id: ID,
        fingerprint: F,
        hasExplicitFingerprint: Bool = true,
        comment: CommentResult.CommentItem? = nil,
        prefetchAvatarPointSize: CGFloat = 36,
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        self.id = AnyHashableSendable(id)
        self.fingerprint = AnyHashableSendable(fingerprint)
        self.hasExplicitFingerprint = hasExplicitFingerprint
        self.comment = comment
        self.prefetchAvatarPointSize = prefetchAvatarPointSize
        self.makeContent = { AnyView(content()) }
    }

    init<Content: View>(
        comment: CommentResult.CommentItem,
        extraFingerprint: AnyHashableSendable? = nil,
        prefetchAvatarPointSize: CGFloat = 36,
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        self.id = AnyHashableSendable(comment.rpid)
        self.fingerprint = AnyHashableSendable(
            UIKitCommentItemFingerprint(comment, extra: extraFingerprint)
        )
        self.hasExplicitFingerprint = true
        self.comment = comment
        self.prefetchAvatarPointSize = prefetchAvatarPointSize
        self.makeContent = { AnyView(content()) }
    }
}

enum UIKitCommentPrefetchExtractor {
    @MainActor
    static func coverRequests(
        for comment: CommentResult.CommentItem,
        scale: CGFloat
    ) -> [UIKitCoverPipeline.CoverRequest] {
        coverRequests(for: comment, avatarPointSize: 36, scale: scale)
    }

    @MainActor
    static func coverRequests(
        for comment: CommentResult.CommentItem,
        avatarPointSize: CGFloat,
        scale: CGFloat
    ) -> [UIKitCoverPipeline.CoverRequest] {
        var requests: [UIKitCoverPipeline.CoverRequest] = []
        let safeScale = scale > 0 ? scale : 1

        let authorAvatar = UIKitCoverPipeline.avatarRequest(
            urlString: comment.member.avatar.httpsURL,
            pointSize: avatarPointSize,
            scale: safeScale
        )
        if authorAvatar.url != nil {
            requests.append(authorAvatar)
        }

        appendPictureRequests(for: comment, scale: safeScale, into: &requests)

        for reply in (comment.replies ?? []).prefix(3) {
            let replyAvatar = UIKitCoverPipeline.avatarRequest(
                urlString: reply.member.avatar.httpsURL,
                pointSize: 30,
                scale: safeScale
            )
            if replyAvatar.url != nil {
                requests.append(replyAvatar)
            }
        }
        return requests
    }

    @MainActor
    private static func appendPictureRequests(
        for comment: CommentResult.CommentItem,
        scale: CGFloat,
        into requests: inout [UIKitCoverPipeline.CoverRequest]
    ) {
        let media = CommentRowView.mediaItems(comment)
        guard !media.isEmpty else { return }

        let geometry = CommentMediaMetrics.gridGeometry(
            count: media.count,
            singlePixelSize: media.first?.pixelSize,
            width: CommentMediaMetrics.maxWidth,
            spacing: CommentMediaMetrics.gridSpacing
        )

        for (index, item) in media.prefix(9).enumerated() {
            let box = index < geometry.frames.count ? geometry.frames[index].size : .zero
            guard box.width > 1, box.height > 1 else { continue }
            if item.isGIF {
                requests.append(UIKitCoverPipeline.CoverRequest(
                    url: item.url,
                    requestBox: box,
                    scale: scale,
                    displayMode: .fill,
                    sourceURL: item.url.absoluteString
                ))
                continue
            }
            let cropped = media.count > 1 || geometry.singleCropsToBox
            let request = UIKitCoverPipeline.request(
                urlString: item.url.absoluteString,
                drawnBox: box,
                displayMode: cropped ? .fill : .entire,
                requestsServerCrop: cropped && !item.isLongImage,
                scale: scale
            )
            if request.url != nil {
                requests.append(request)
            }
        }
    }
}

@MainActor
final class UIKitCommentSkeletonCell: UICollectionViewCell {
    private let avatarShape = UIView()
    private let authorBar = UIView()
    private let bodyBar1 = UIView()
    private let bodyBar2 = UIView()
    private let actionBarStub = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(accessibilityLabel: String? = nil) {
        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
    }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isUserInteractionEnabled = false

        avatarShape.translatesAutoresizingMaskIntoConstraints = false
        avatarShape.backgroundColor = .secondarySystemFill
        avatarShape.layer.cornerRadius = 18
        avatarShape.layer.cornerCurve = .continuous

        for shape in [authorBar, bodyBar1, bodyBar2, actionBarStub] {
            shape.translatesAutoresizingMaskIntoConstraints = false
            shape.backgroundColor = .secondarySystemFill
            shape.layer.cornerRadius = AppRadius.badge
            shape.layer.cornerCurve = .continuous
        }
        actionBarStub.alpha = 0.65

        [avatarShape, authorBar, bodyBar1, bodyBar2, actionBarStub].forEach {
            contentView.addSubview($0)
        }
        activateConstraints()
    }

    private func activateConstraints() {
        let body2Trailing = bodyBar2.trailingAnchor.constraint(
            lessThanOrEqualTo: contentView.trailingAnchor, constant: -48
        )
        let body2Width = bodyBar2.widthAnchor.constraint(equalToConstant: 200)
        body2Width.priority = .defaultHigh

        NSLayoutConstraint.activate([
            avatarShape.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            avatarShape.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            avatarShape.widthAnchor.constraint(equalToConstant: 36),
            avatarShape.heightAnchor.constraint(equalToConstant: 36),

            authorBar.topAnchor.constraint(equalTo: avatarShape.topAnchor, constant: 2),
            authorBar.leadingAnchor.constraint(equalTo: avatarShape.trailingAnchor, constant: 12),
            authorBar.widthAnchor.constraint(equalToConstant: 112),
            authorBar.heightAnchor.constraint(equalToConstant: 14),

            bodyBar1.topAnchor.constraint(equalTo: authorBar.bottomAnchor, constant: 8),
            bodyBar1.leadingAnchor.constraint(equalTo: authorBar.leadingAnchor),
            bodyBar1.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            bodyBar1.heightAnchor.constraint(equalToConstant: 14),

            bodyBar2.topAnchor.constraint(equalTo: bodyBar1.bottomAnchor, constant: 6),
            bodyBar2.leadingAnchor.constraint(equalTo: authorBar.leadingAnchor),
            body2Trailing,
            body2Width,
            bodyBar2.heightAnchor.constraint(equalToConstant: 14),

            actionBarStub.topAnchor.constraint(equalTo: bodyBar2.bottomAnchor, constant: 10),
            actionBarStub.leadingAnchor.constraint(equalTo: authorBar.leadingAnchor),
            actionBarStub.widthAnchor.constraint(equalToConstant: 76),
            actionBarStub.heightAnchor.constraint(equalToConstant: 12),
            actionBarStub.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }
}
