import Kingfisher
import SwiftUI

struct ChatMessageRow: View {
    let message: SessionMsgsResult.ChatMessage
    let previousTimestamp: Int?
    let talkerID: Int
    let face: String?
    let myUID: Int?
    var bubbleMaxWidth: CGFloat = 260
    @State private var payload = ChatMessagePayloadCache()
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.contentLinkContext) private var linkContext
    @Environment(\.displayScale) private var displayScale

    init(
        message: SessionMsgsResult.ChatMessage,
        previousTimestamp: Int?,
        talkerID: Int,
        face: String?,
        myUID: Int?,
        bubbleMaxWidth: CGFloat = 260
    ) {
        self.message = message
        self.previousTimestamp = previousTimestamp
        self.talkerID = talkerID
        self.face = face
        self.myUID = myUID
        self.bubbleMaxWidth = bubbleMaxWidth
    }

    init(
        message: SessionMsgsResult.ChatMessage,
        previous: SessionMsgsResult.ChatMessage?,
        talkerID: Int,
        face: String?,
        myUID: Int?,
        bubbleMaxWidth: CGFloat = 260
    ) {
        self.init(
            message: message,
            previousTimestamp: previous?.timestamp,
            talkerID: talkerID,
            face: face,
            myUID: myUID,
            bubbleMaxWidth: bubbleMaxWidth
        )
    }

    @ViewBuilder
    var body: some View {
        if let timestamp = message.timestamp,
           timestamp - (previousTimestamp ?? 0) > 300 {
            Text(payload.timestampText(for: timestamp, formatter: Self.chipFormatter))
                .appFont(.messageMeta)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, AppSpacing.xs)
                .background(AppFill.inset, in: Capsule())
                .padding(.vertical, 6)
        }

        rowContent
            .padding(.bottom, AppSpacing.s)
    }

    @ViewBuilder
    private var rowContent: some View {
        let content = payload.value(for: message)
        if case .systemNotice(let text, let url) = content {
            systemNoticeRow(text: text, url: url)
        } else {
            bubbleRow(content)
        }
    }

    private func bubbleRow(_ content: ChatMessagePayload) -> some View {
        let isMine = message.senderUid == myUID
        return HStack(alignment: .bottom, spacing: AppSpacing.s) {
            if isMine { Spacer(minLength: 48) }

            if !isMine {
                ChatAvatarView(face: face, size: 32)
                    .onTapGesture {
                        coordinator.navigate(to: .userSpace(talkerID))
                    }
            }

            bubbleContent(content, isMine: isMine)

            if !isMine { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }

    @ViewBuilder
    private func bubbleContent(_ content: ChatMessagePayload, isMine: Bool) -> some View {
        switch content {
        case .recalled:
            Text("[Message recalled]")
                .appFont(.messageBody)
                .italic()
                .foregroundStyle(.tertiary)
        case .image(let image):
            imageBubble(image)
        case .sticker(let url, let text):
            stickerBubble(url: url, text: text)
        case .card(let card):
            cardBubble(card)
        case .systemNotice(let text, let url):
            systemNoticeRow(text: text, url: url)
        case .text(let text):
            textBubble(text, isMine: isMine)
        }
    }

    private func imageBubble(_ image: String) -> some View {
        let resizedURL = image.httpsURL.biliResized(
            toPixel: CGSize(width: 200 * displayScale, height: 150 * displayScale)
        )
        return Color.imagePlaceholder
            .frame(width: 200, height: 150)
            .overlay {
                KFImage(URL(string: resizedURL))
                    .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 200, height: 150)))
                    .backgroundDecode()
                    .scaleFactor(displayScale > 0 ? displayScale : 1)
                    .cancelOnDisappear(true)
                    .resizable()
                    .imageLoadingCover(ground: .clear, shorterSide: 150)
                    .scaledToFit()
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    private func stickerBubble(url: String, text: String?) -> some View {
        let resizedURL = url.httpsURL.biliResized(
            toPixel: CGSize(width: 120 * displayScale, height: 120 * displayScale)
        )
        return Color.clear
            .frame(width: 120, height: 120)
            .overlay {
                KFImage(URL(string: resizedURL))
                    .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 120, height: 120)))
                    .backgroundDecode()
                    .scaleFactor(displayScale > 0 ? displayScale : 1)
                    .cancelOnDisappear(true)
                    .resizable()
                    .imageLoadingCover(ground: .clear, shorterSide: 120)
                    .scaledToFit()
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous))
            .accessibilityLabel(Text(text ?? String(localized: "[Sticker]")))
    }

    private func textBubble(_ text: String, isMine: Bool) -> some View {
        let bubbleShape = UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: isMine ? 18 : 4,
            bottomTrailingRadius: isMine ? 4 : 18,
            topTrailingRadius: 18,
            style: .continuous
        )
        return linkifiedBubbleText(text, isMine: isMine)
            .appFont(.messageBody)
            .foregroundStyle(isMine ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                if isMine {
                    bubbleShape.fill(Color.biliAccent.gradient)
                } else {
                    Color.clear.appCardSurface(in: bubbleShape)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: bubbleMaxWidth, alignment: isMine ? .trailing : .leading)
    }

    private func linkifiedBubbleText(_ text: String, isMine: Bool) -> Text {
        payload.bubbleText(for: text, isMine: isMine)
    }

    private func systemNoticeRow(text: String, url: String?) -> some View {
        let actionURL = url.flatMap(URL.init(string:))
        return Group {
            if let actionURL {
                Button {
                    coordinator.handle(url: actionURL, context: linkContext)
                } label: {
                    systemNoticeCapsule(text: text, hasLink: true)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            } else {
                systemNoticeCapsule(text: text, hasLink: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, AppSpacing.xs)
    }

    private func systemNoticeCapsule(text: String, hasLink: Bool) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Text(text)
                .appFont(.messageMeta)
                .foregroundStyle(hasLink ? Color.biliAccent : .secondary)
                .multilineTextAlignment(.center)
            if hasLink {
                Image(systemName: "chevron.right")
                    .appFont(.messageMeta)
                    .foregroundStyle(Color.biliAccent)
            }
        }
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, 6)
        .background(AppFill.inset, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .frame(maxWidth: bubbleMaxWidth + 60)
    }

    @ViewBuilder
    private func cardBubble(_ card: ChatMessageCard) -> some View {
        let actionURL = card.url.flatMap(URL.init(string:))
        if let actionURL {
            Button {
                coordinator.handle(url: actionURL, context: linkContext)
            } label: {
                cardBubbleSurface(card, isInteractive: true)
            }
            .buttonStyle(.plain)
        } else {
            cardBubbleSurface(card, isInteractive: false)
                .textSelection(.enabled)
        }
    }

    private func cardBubbleSurface(_ card: ChatMessageCard, isInteractive: Bool) -> some View {
        let cardWidth: CGFloat = bubbleMaxWidth > 300 ? min(bubbleMaxWidth - 60, 320) : 240
        let thumbWidth = cardWidth - AppSpacing.m * 2
        let thumbHeight = (thumbWidth * 9 / 16).rounded()

        return VStack(alignment: .leading, spacing: AppSpacing.s) {
            if let thumb = card.thumb, !thumb.isEmpty {
                cardThumbnail(thumb, width: thumbWidth, height: thumbHeight)
            }

            Text(card.title)
                .appFont(.messageTitle)
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .appFont(.messageBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }

            if !card.modules.isEmpty {
                cardModulesSection(card.modules)
            }

            if isInteractive {
                Divider().opacity(0.4)
                HStack(spacing: AppSpacing.xs) {
                    Text(card.jumpText ?? String(localized: "View Details"))
                        .appFont(.controlLabel)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.biliAccent)
                        .lineLimit(1)
                    Spacer(minLength: AppSpacing.xs)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.biliAccent)
                }
                .padding(.top, 2)
            }
        }
        .padding(AppSpacing.m)
        .frame(width: cardWidth, alignment: .leading)
        .frame(minHeight: 44, alignment: .leading)
        .appCardSurface(in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    private func cardThumbnail(_ thumb: String, width: CGFloat, height: CGFloat) -> some View {
        let resizedURL = thumb.httpsURL.biliResized(
            toPixel: CGSize(width: width * displayScale, height: height * displayScale)
        )
        return KFImage(URL(string: resizedURL))
            .setProcessor(DownsamplingImageProcessor(size: CGSize(width: width, height: height)))
            .scaleFactor(displayScale)
            .cancelOnDisappear(true)
            .resizable()
            .imageLoadingCover(shape: .roundedRect(AppRadius.control), shorterSide: height)
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
    }

    private func cardModulesSection(_ modules: [ChatMessageCardModule]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            ForEach(Array(modules.enumerated()), id: \.offset) { _, module in
                VStack(alignment: .leading, spacing: 2) {
                    if !module.title.isEmpty {
                        Text(module.title)
                            .appFont(.messageMeta)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !module.detail.isEmpty {
                        Text(module.detail)
                            .appFont(.messageBody)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(AppSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppFill.nested,
            in: RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous)
        )
    }

    private static let chipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

struct ChatAvatarView: View {
    let face: String?
    let size: CGFloat

    var body: some View {
        if let urlString = face, !urlString.isEmpty {
            AvatarImage(urlString: urlString, size: size)
        } else {
            Circle().fill(AppFill.inset)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
    }
}

@MainActor
private final class ChatMessagePayloadCache {
    private struct Key: Equatable {
        let type: Int?
        let content: String?
    }

    private struct TextKey: Equatable {
        let text: String
        let isMine: Bool
    }

    private var key: Key?
    private var prepared: ChatMessagePayload?
    private var cachedTimestamp: Int?
    private var cachedTimestampText: String?
    private var cachedTextKey: TextKey?
    private var cachedBubbleText: Text?

    func value(for message: SessionMsgsResult.ChatMessage) -> ChatMessagePayload {
        let requested = Key(type: message.msgType, content: message.content)
        if key == requested, let prepared { return prepared }
        let payload = BiliIMMessageParser.parse(msgType: requested.type, rawContent: requested.content)
        key = requested
        prepared = payload
        return payload
    }

    func timestampText(for timestamp: Int, formatter: DateFormatter) -> String {
        if cachedTimestamp == timestamp, let cachedTimestampText { return cachedTimestampText }
        let formatted = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        cachedTimestamp = timestamp
        cachedTimestampText = formatted
        return formatted
    }

    func bubbleText(for text: String, isMine: Bool) -> Text {
        let requested = TextKey(text: text, isMine: isMine)
        if cachedTextKey == requested, let cachedBubbleText { return cachedBubbleText }
        let built = buildBubbleText(text, isMine: isMine)
        cachedTextKey = requested
        cachedBubbleText = built
        return built
    }

    private func buildBubbleText(_ text: String, isMine: Bool) -> Text {
        guard !text.isEmpty else {
            return Text(verbatim: String(localized: "[Unsupported message]"))
        }
        let links = UIKitDynamicRichTextBuilder.inlineLinks(in: text)
        guard !links.isEmpty else { return Text(verbatim: text) }
        let runs = EmoteText.linkRuns(text, links: links)
        guard runs.contains(where: { $0.url != nil }) else { return Text(verbatim: text) }
        var result = Text(verbatim: "")
        for run in runs {
            guard let url = run.url else {
                result = result + Text(verbatim: run.text)
                continue
            }
            var attributed = AttributedString(run.text)
            attributed.link = url
            attributed.foregroundColor = isMine ? Color.white : Color.biliAccent
            if isMine {
                attributed.underlineStyle = Text.LineStyle.single
            }
            result = result + Text(attributed)
        }
        return result
    }
}
