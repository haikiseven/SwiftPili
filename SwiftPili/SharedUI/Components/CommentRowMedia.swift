import SwiftUI

struct NoteLinkChip: View {
    let note: CommentResult.CommentItem.CommentContent.RichTextInfo.Note

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let clickUrl = note.clickUrl, let url = URL(string: clickUrl) {
            Button {
                openURL(url)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "note.text")
                    Text("View Full Note")
                    if let mtime = note.lastMtimeText, !mtime.isEmpty {
                        Text(mtime)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .imageScale(.small)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.biliAccent)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
        }
    }
}

struct BlockedCollapsible<Content: View>: View {
    @AppMotion private var motion
    let mid: Int
    let uname: String
    @ViewBuilder var content: () -> Content

    @State private var revealed = false

    var body: some View {
        if BlocklistManager.shared.isBlocked(mid), !revealed {
            Button {
                withAnimation(motion.animation(normal: .easeInOut(duration: 0.2))) { revealed = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                    Text("Blocked user @\(uname) — comment hidden")
                        .lineLimit(1)
                    Spacer()
                    Text("Show Anyway")
                        .foregroundStyle(.biliAccent)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

@MainActor
private enum CommentVideoTitleChipMemo {
    struct Entry {
        let videoID: VideoID?
        let title: String?
    }

    private static let maxEntries = 256
    private static var entries: [String: Entry] = [:]
    private static var order: [String] = []

    static func entry(for message: String) -> Entry? { entries[message] }

    static func record(_ entry: Entry, for message: String) {
        if entries.updateValue(entry, forKey: message) == nil {
            order.append(message)
            if order.count > maxEntries { entries.removeValue(forKey: order.removeFirst()) }
        }
    }
}

struct CommentVideoTitleChip: View {
    let message: String

    @State private var videoID: VideoID?
    @State private var title: String?
    @State private var resolvedMessage: String?

    init(message: String) {
        self.message = message
        if let memo = CommentVideoTitleChipMemo.entry(for: message), memo.title != nil || memo.videoID == nil {
            _videoID = State(initialValue: memo.videoID)
            _title = State(initialValue: memo.title)
            _resolvedMessage = State(initialValue: message)
        }
    }

    var body: some View {
        Group {
            if let videoID, let title, let url = Self.canonicalURL(for: videoID) {
                let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.biliAccent)
                        Text(title)
                            .font(.footnote.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(AppFill.nested.opacity(0.6), in: shape)
                    .overlay(
                        shape
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    )
                    .contentShape(shape)
                }
                .buttonStyle(.appControl)
            }
        }
        .task(id: message) {
            if resolvedMessage == message { return }
            if videoID != nil { videoID = nil }
            if title != nil { title = nil }
            if resolvedMessage != nil { resolvedMessage = nil }
            guard case .resolved(let target, _) = BiliLinkResolver.resolve(text: message),
                  case .video(let id) = target
            else {
                CommentVideoTitleChipMemo.record(.init(videoID: nil, title: nil), for: message)
                resolvedMessage = message
                return
            }
            videoID = id
            let resolved = await BiliVideoTitleCache.shared.title(for: id)
            guard !Task.isCancelled else { return }
            title = resolved
            if let resolved {
                CommentVideoTitleChipMemo.record(.init(videoID: id, title: resolved), for: message)
                resolvedMessage = message
            }
        }
    }

    private static func canonicalURL(for id: VideoID) -> URL? {
        switch id {
        case .bvid(let bvid): URL(string: "https://www.bilibili.com/video/\(bvid)")
        case .aid(let aid): URL(string: "https://www.bilibili.com/video/av\(aid)")
        }
    }
}

extension View {
    func dismissingSheetOnBiliLink(
        coordinator: AppCoordinator,
        dismiss: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        contentLinks(beforeNavigate: dismiss)
    }
}
