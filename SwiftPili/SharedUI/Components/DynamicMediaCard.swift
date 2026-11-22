import SwiftUI

struct DynamicMediaCard: View {
    enum Kind {
        case video(duration: String?)
        case live(areaName: String?)
        case labeled(String?)
    }

    let title: String?
    let cover: String?
    let kind: Kind
    var subtitle: String?
    var quoted: Bool = false
    var titleLineLimit: Int? = 2
    var explicitWidth: CGFloat?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    private var maximumWidth: CGFloat {
        if quoted { return .infinity }
        switch kind {
        case .video: return .infinity
        case .live, .labeled: return 320
        }
    }

    var body: some View {
        Group {
            if let cover, !cover.isEmpty {
                if quoted {
                    quotedMediaRow(cover: cover)
                } else {
                    mainMediaUnit(cover: cover)
                }
            } else {
                fallbackTextCard
            }
        }
        .frame(maxWidth: maximumWidth, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var seededDisplaySize: CGSize {
        let insetCardWidth: CGFloat
        if let available = explicitWidth ?? envColumnWidth, available.isFinite, available > 0 {
            insetCardWidth = max(160, available)
        } else {
            let containerSeed = FeedWidth.fullContainerSeed(cappedTo: ReadableWidth.feed)
            insetCardWidth = max(160, containerSeed - 64)
        }
        let cardWidth: CGFloat = switch kind {
        case .video: insetCardWidth
        case .live, .labeled: min(320, insetCardWidth)
        }
        return CGSize(width: cardWidth.rounded(), height: (cardWidth * 76.0 / 136.0).rounded())
    }

    private func mainMediaUnit(cover: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(136.0 / 76.0, contentMode: .fit)
                .overlay {
                    CoverImage(
                        urlString: cover,
                        displaySize: seededDisplaySize,
                        contentMode: .fill,
                        fillsOfferedBox: true
                    )
                }
                .overlay(alignment: .topLeading) {
                    topLeadingBadge(padding: 8)
                }
                .overlay(alignment: .bottomTrailing) {
                    bottomTrailingBadge(padding: 8)
                }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 3) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(titleLineLimit)
                        .multilineTextAlignment(.leading)
                }
                if let sub = resolvedMainSubtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .zoomSourceAnchor(cornerRadius: AppRadius.card)
    }

    @ViewBuilder
    private func quotedMediaRow(cover: String) -> some View {
        let thumbWidth: CGFloat = 132
        let thumbHeight = (thumbWidth * 76.0 / 136.0).rounded()
        let thumbnail = Color.clear
            .frame(width: thumbWidth, height: thumbHeight)
            .overlay {
                CoverImage(
                    urlString: cover,
                    displaySize: CGSize(width: thumbWidth, height: thumbHeight),
                    contentMode: .fill,
                    fillsOfferedBox: true
                )
            }
            .overlay(alignment: .topLeading) {
                topLeadingBadge(padding: 6)
            }
            .overlay(alignment: .bottomTrailing) {
                bottomTrailingBadge(padding: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous))
            .zoomSourceAnchor(cornerRadius: AppRadius.thumbnail)

        let textColumn = VStack(alignment: .leading, spacing: 4) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(titleLineLimit)
                    .multilineTextAlignment(.leading)
            }
            if let sub = resolvedQuotedSubtitle, !sub.isEmpty {
                Text(sub)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail
                textColumn
            }
            .padding(.vertical, 4)
        } else {
            HStack(alignment: .center, spacing: 10) {
                thumbnail
                textColumn
            }
            .padding(.vertical, 4)
            .frame(minHeight: 84, alignment: .leading)
        }
    }

    @ViewBuilder
    private func topLeadingBadge(padding: CGFloat) -> some View {
        switch kind {
        case .video:
            EmptyView()
        case .live:
            HStack(spacing: 4) {
                Circle().fill(.white).frame(width: 5, height: 5)
                Text("LIVE")
                    .appFont(.overlayBadge)
                    .fontWeight(.bold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Color.red, in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous))
            .padding(padding)
        case let .labeled(badge):
            if let badge, !badge.isEmpty {
                Text(badge)
                    .appFont(.overlayBadge)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        .black.opacity(0.68),
                        in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                    )
                    .padding(padding)
            }
        }
    }

    @ViewBuilder
    private func bottomTrailingBadge(padding: CGFloat) -> some View {
        if case let .video(duration) = kind, let duration, !duration.isEmpty {
            Text(duration)
                .appFont(.overlayBadge, monospacedDigit: true)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    .black.opacity(0.68),
                    in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                )
                .padding(padding)
        }
    }

    private var resolvedMainSubtitle: String? {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        if case let .live(areaName) = kind, let areaName, !areaName.isEmpty { return areaName }
        return nil
    }

    private var resolvedQuotedSubtitle: String? {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        switch kind {
        case .video: return String(localized: "Video")
        case let .live(areaName): return areaName
        case let .labeled(badge): return badge
        }
    }

    private var fallbackTextCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(titleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            metadata
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppFill.inset, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .zoomSourceAnchor(cornerRadius: AppRadius.card)
    }

    @ViewBuilder
    private var metadata: some View {
        switch kind {
        case .video:
            EmptyView()
        case let .live(areaName):
            if let areaName, !areaName.isEmpty {
                Text(areaName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .labeled(badge):
            if let badge, !badge.isEmpty {
                Text(badge)
                    .font(.footnote)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
        }
    }
}
