import SwiftUI
import UIKit

struct LiveStandardChatView: View {
    let viewModel: LiveRoomViewModel
    let isWide: Bool

    @Environment(AppCoordinator.self) private var coordinator
    @ScaledMetric(relativeTo: .callout) private var chatSenderNameMaxWidth: CGFloat = 130
    @State private var autoScroll = LiveChatAutoScrollPolicy<UUID>()

    var body: some View {
        ScrollViewReader { proxy in
            let renderedMessages = LiveChatRenderPolicy.standardVisibleMessages(
                from: viewModel.chatMessages
            )
            let horizontalInset: CGFloat = isWide ? 18 : 14
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: AppSpacing.s) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.biliAccent)
                    Text("Live Chat")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                    Spacer()
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, isWide ? AppSpacing.l : AppSpacing.m)
                .padding(.bottom, isWide ? AppSpacing.m : AppSpacing.s)

                Divider()
                    .opacity(0.24)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: isWide ? 10 : 8) {
                        ForEach(renderedMessages) { msg in
                            chatBubble(msg)
                                .id(msg.id)
                        }

                        if renderedMessages.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: AppSpacing.s) {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                        .font(.title2)
                                        .foregroundStyle(.tertiary)
                                    Text("Chat messages will appear here")
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 48)
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, isWide ? AppSpacing.m : AppSpacing.s)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: renderedMessages.last?.id) { _, latestID in
                guard let targetID = autoScroll.nextTarget(for: latestID) else {
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(targetID, anchor: .bottom)
                }
            }
            .onDisappear {
                autoScroll.reset()
            }
        }
    }

    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if msg.isSystem {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(msg.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                if let name = msg.medalName, let level = msg.medalLevel {
                    LiveChatMedalChip(name: name, level: level, color: msg.medalColor)
                        .alignmentGuide(.firstTextBaseline) {
                            LiveChatMedalChip.firstTextBaseline($0)
                        }
                }
                Button {
                    guard msg.uid > 0 else { return }
                    coordinator.navigate(to: .userSpace(msg.uid))
                } label: {
                    Text(msg.uname)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.biliAccent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: chatSenderNameMaxWidth, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .disabled(msg.uid <= 0)
                .accessibilityLabel(Text(
                    msg.uid > 0
                        ? "Open \(msg.uname)'s profile"
                        : msg.uname
                ))
                Text(msg.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            }
        }
    }
}

struct LiveImmersiveChatView: View {
    let viewModel: LiveRoomViewModel

    @Environment(AppCoordinator.self) private var coordinator
    @ScaledMetric(relativeTo: .callout) private var chatSenderNameMaxWidth: CGFloat = 130
    @State private var autoScroll = LiveChatAutoScrollPolicy<UUID>()

    var body: some View {
        ScrollViewReader { proxy in
            let renderedMessages = LiveChatRenderPolicy.immersiveVisibleMessages(
                from: viewModel.chatMessages
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(renderedMessages) { message in
                        immersiveChatBubble(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 24)
                    Color.black
                }
            }
            .onChange(of: renderedMessages.last?.id) { _, latestID in
                guard let targetID = autoScroll.nextTarget(for: latestID) else {
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(targetID, anchor: .bottom)
                }
            }
            .onDisappear {
                autoScroll.reset()
            }
        }
    }

    private func immersiveChatBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if message.isSystem {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.80))
                Text(message.text)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.88))
                    .italic()
            } else {
                if let name = message.medalName, let level = message.medalLevel {
                    LiveChatMedalChip(name: name, level: level, color: message.medalColor)
                        .alignmentGuide(.firstTextBaseline) {
                            LiveChatMedalChip.firstTextBaseline($0)
                        }
                }
                Button {
                    guard message.uid > 0 else { return }
                    coordinator.navigate(to: .userSpace(message.uid))
                } label: {
                    Text(message.uname)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.biliAccent.mix(with: .white, by: 0.25))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: chatSenderNameMaxWidth, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .disabled(message.uid <= 0)
                .accessibilityLabel(Text(
                    message.uid > 0
                        ? "Open \(message.uname)'s profile"
                        : message.uname
                ))
                Text(message.text)
                    .font(.callout)
                    .lineLimit(2)
                    .layoutPriority(1)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.82), radius: 1, x: 0, y: 0.5)
        .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1.5)
    }
}

private struct LiveChatMedalChip: View {
    let name: String
    let level: Int
    let color: Int?

    var body: some View {
        HStack(spacing: 2) {
            Text(name)
                .appFont(.overlayBadge)
                .fontWeight(.medium)
                .lineLimit(1)
            Text("\(level)")
                .appFont(.overlayBadge)
                .fontWeight(.bold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(medalColor)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.badge))
        .fixedSize()
    }

    private var medalColor: Color {
        guard let color else { return .secondary }
        return Color(
            red: Double((color >> 16) & 0xFF) / 255.0,
            green: Double((color >> 8) & 0xFF) / 255.0,
            blue: Double(color & 0xFF) / 255.0
        )
    }

    nonisolated static func firstTextBaseline(_ dimensions: ViewDimensions) -> CGFloat {
        let capHeight = UIFont.preferredFont(forTextStyle: .callout).capHeight
        return dimensions.height / 2 + capHeight / 2
    }
}
