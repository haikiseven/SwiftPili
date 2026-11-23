import Kingfisher
import SwiftUI
import UIKit

struct CommentAuthorHeader: View {
    let comment: CommentResult.CommentItem
    let upMid: Int?
    var showsPinned = false
    let actionState: CommentActionState
    var onDelete: (() -> Void)?
    var aiAssessment: CommentAIAssessment?
    var onInspectAI: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            accessibilityLayout
        } else {
            compactLayout
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                authorNameText
                if comment.mid == upMid {
                    UPBadge().fixedSize()
                }
                if showsPinned, comment.isPinned {
                    PinnedBadge().fixedSize()
                }
                if let aiAssessment, let onInspectAI {
                    CommentAIBadgeButton(score: aiAssessment.score, action: onInspectAI)
                        .fixedSize()
                }
                Spacer(minLength: 4)
                CommentDecorationBadge(member: comment.member)
                CommentMoreActionButton(comment: comment, state: actionState, onDelete: onDelete)
                    .fixedSize()
            }
            metaView
        }
    }

    private var accessibilityLayout: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    authorNameText
                    if comment.mid == upMid {
                        UPBadge().fixedSize()
                    }
                    if showsPinned, comment.isPinned {
                        PinnedBadge().fixedSize()
                    }
                }
                if let aiAssessment, let onInspectAI {
                    CommentAIBadgeButton(score: aiAssessment.score, action: onInspectAI)
                        .fixedSize()
                }
                metaView
            }
            Spacer(minLength: 6)
            CommentDecorationBadge(member: comment.member)
            CommentMoreActionButton(comment: comment, state: actionState, onDelete: onDelete)
                .fixedSize()
        }
    }

    private var authorNameText: some View {
        Text(comment.member.uname)
            .appFont(.commentAuthor)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var metaView: some View {
        HStack(spacing: 6) {
            Text(FormatUtils.timeAgo(from: comment.ctime))
            if let location = comment.ipLocation {
                Text(location)
            }
        }
        .appFont(.commentMeta)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct PinnedBadge: View {
    var body: some View {
        Text("Pinned")
            .appFont(.overlayBadge)
            .fontWeight(.bold)
            .foregroundStyle(Color.biliAccent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.badge)
                    .strokeBorder(Color.biliAccent.opacity(0.6), lineWidth: 0.5)
            )
    }
}

struct UPBadge: View {
    @MainActor
    private static var cachedInlineImage: (key: String, image: UIImage)?

    var body: some View {
        Text("UP")
            .appFont(.overlayBadge)
            .fontWeight(.heavy)
            .fontDesign(.rounded)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(AccentStore.shared.badgeFill, in: RoundedRectangle(cornerRadius: AppRadius.badge))
    }

    @MainActor
    static var inlineText: Text {
        let store = AccentStore.shared
        let cacheKey = "\(store.theme?.rawValue ?? "default"):\(store.scope.rawValue)"
        let image: UIImage
        if let cached = cachedInlineImage, cached.key == cacheKey {
            image = cached.image
        } else {
            let rendered = renderInlinePill(fill: UIColor(store.badgeFill))
            cachedInlineImage = (cacheKey, rendered)
            image = rendered
        }
        return Text(verbatim: " ")
            + Text(Image(uiImage: image))
                .font(EmoteTextFont.inlineAttachment)
                .baselineOffset(-1.5)
    }

    private static func renderInlinePill(fill: UIColor) -> UIImage {
        let baseFont = UIFont.systemFont(ofSize: 8.5, weight: .heavy)
        let font: UIFont = if let desc = baseFont.fontDescriptor.withDesign(.rounded) {
            UIFont(descriptor: desc, size: 8.5)
        } else {
            baseFont
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let label = "UP" as NSString
        let textSize = label.size(withAttributes: attrs)
        let size = CGSize(width: ceil(textSize.width) + 7, height: ceil(textSize.height) + 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            fill.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: AppRadius.badge).fill()
            let textOrigin = CGPoint(
                x: (size.width - textSize.width) * 0.5,
                y: (size.height - textSize.height) * 0.5
            )
            label.draw(at: textOrigin, withAttributes: attrs)
        }
    }
}

struct UPLikedTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hand.thumbsup.fill")
                .font(.caption2)
                .imageScale(.small)
            Text("Liked by UP")
                .appFont(.overlayBadge)
                .fontWeight(.semibold)
        }
        .foregroundStyle(Color.biliAccent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.biliAccent.opacity(0.12), in: Capsule())
    }
}

struct CommentDecorationBadge: View {
    let member: CommentResult.CommentItem.CommentMember
    @Environment(\.displayScale) private var displayScale
    @AppStorage("show_comment_ornaments") private var showOrnaments = false
    @State private var loadedURL: URL?

    var body: some View {
        let scale = max(1, displayScale)
        if showOrnaments, let cardbg = member.userSailing?.cardbg,
           let image = cardbg.image, !image.isEmpty,
           let url = URL(string: image.biliResized(
               toPixel: CGSize(width: 80 * scale, height: 24 * scale),
               crop: true
           )) {
            KFImage(url)
                .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 80, height: 24)))
                .scaleFactor(scale)
                .cancelOnDisappear(true)
                .onSuccess { _ in loadedURL = url }
                .onFailure { _ in loadedURL = nil }
                .placeholder { Color.clear }
                .resizable()
                .scaledToFill()
                .frame(width: 80, height: 24)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.badge))
                .overlay(alignment: .center) {
                    if let fan = cardbg.fan, fan.isFan == 1,
                       let numDesc = fan.numDesc, !numDesc.isEmpty {
                        let tint = Color(biliHex: fan.color) ?? .white
                        Text(verbatim: "NO.\(numDesc)")
                            .appFont(.overlayBadge)
                            .fontWeight(.bold)
                            .fontDesign(.rounded)
                            .italic()
                            .foregroundStyle(tint)
                    }
                }
                .opacity(loadedURL == url ? 1 : 0)
                .accessibilityHidden(loadedURL != url)
                .allowsHitTesting(false)
        }
    }
}

extension Color {
    init?(biliHex: String?) {
        guard var hex = biliHex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
