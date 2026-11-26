import Foundation
import SwiftUI

@MainActor
struct PlayerNoticeBanner: Equatable, Identifiable {
    let id: UUID
    let text: String
    let actionTitle: String?
    let duration: TimeInterval
    let isResumeNotice: Bool
    let onAction: (@MainActor () -> Void)?

    init(
        id: UUID = UUID(),
        text: String,
        actionTitle: String? = nil,
        duration: TimeInterval = 2.5,
        isResumeNotice: Bool = false,
        onAction: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.text = text
        self.actionTitle = actionTitle
        self.duration = duration
        self.isResumeNotice = isResumeNotice
        self.onAction = onAction
    }

    var isInteractive: Bool {
        actionTitle != nil && onAction != nil
    }

    nonisolated static func == (lhs: PlayerNoticeBanner, rhs: PlayerNoticeBanner) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.actionTitle == rhs.actionTitle
            && lhs.duration == rhs.duration
            && lhs.isResumeNotice == rhs.isResumeNotice
    }
}

@MainActor
struct PendingHistoryResumeNotice: Equatable, Sendable {
    let resumedSeconds: TimeInterval
    let partNumber: Int?

    nonisolated static func == (lhs: PendingHistoryResumeNotice, rhs: PendingHistoryResumeNotice) -> Bool {
        lhs.resumedSeconds == rhs.resumedSeconds
            && lhs.partNumber == rhs.partNumber
    }

    func formattedNoticeText() -> String {
        let clampedSeconds = resumedSeconds.isFinite ? max(0, Int(resumedSeconds)) : 0
        let timeText = FormatUtils.duration(clampedSeconds)
        if let partNumber {
            return String(
                format: String(localized: "Resumed P%lld at %@"),
                Int64(partNumber),
                timeText
            )
        }
        return String(
            format: String(localized: "Resumed at %@"),
            timeText
        )
    }
}

struct PlayerNoticeBannerView: View {
    let banner: PlayerNoticeBanner
    let onTriggerAction: () -> Void

    var body: some View {
        Group {
            if let actionTitle = banner.actionTitle, banner.onAction != nil {
                HStack(spacing: 10) {
                    Text(banner.text)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Button(action: onTriggerAction) {
                        Text(actionTitle)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(AccentStore.shared.badgeFill, in: Capsule())
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.noticeBanner.action")
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 3)
            } else {
                Text(banner.text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("player.noticeBanner")
    }
}
