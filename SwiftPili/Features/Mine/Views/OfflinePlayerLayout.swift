import SwiftUI

struct OfflinePlayerLayout {
    let isSplit: Bool
    let playerSize: CGSize
    let primaryColumnWidth: CGFloat
    let metadataWidth: CGFloat

    init(
        containerSize: CGSize,
        layoutContainerSize: CGSize,
        isRegularWidth: Bool,
        supportsPadSplit: Bool,
        isPortraitContent: Bool,
        isCondensed: Bool
    ) {
        let safeWidth = containerSize.width.isFinite ? max(0, containerSize.width) : 0
        let safeHeight = containerSize.height.isFinite ? max(0, containerSize.height) : 0
        let splitReferenceSize = (layoutContainerSize.width > 0 && layoutContainerSize.height > 0)
            ? layoutContainerSize
            : CGSize(width: safeWidth, height: safeHeight)
        let split = DetailSplitPolicy.usesSplit(
            isRegularWidth: isRegularWidth,
            supportsPadSplit: supportsPadSplit,
            containerSize: splitReferenceSize
        )
        isSplit = split
        if split {
            let panelWidth = floor(DetailStageLayout.panelWidth(containerWidth: safeWidth))
            let columnWidth = floor(max(
                0,
                safeWidth - 2 * DetailStageLayout.outerMargin - DetailStageLayout.columnGap - panelWidth
            ))
            let columnHeight = max(0, safeHeight - 2 * DetailStageLayout.outerMargin)
            primaryColumnWidth = columnWidth
            playerSize = DetailStageLayout.videoBox(
                availableWidth: columnWidth,
                heightCap: columnHeight
            )
            metadataWidth = panelWidth
        } else {
            let height = DetailPlayerGeometry.videoHeight(
                containerWidth: safeWidth,
                primaryColumnWidth: nil,
                isPortraitContent: isPortraitContent,
                isCondensed: isCondensed
            )
            primaryColumnWidth = safeWidth
            playerSize = CGSize(width: safeWidth, height: height)
            metadataWidth = safeWidth
        }
    }
}

struct OfflinePlayerMetadataView: View {
    let title: String
    let ownerName: String
    let qualityLabel: String
    let fileSizeBytes: Int64
    var isSplit = false
    var onOpenOriginal: (() -> Void)? = nil

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isSplit ? AppSpacing.m : 12) {
            VStack(alignment: .leading, spacing: AppSpacing.s) {
                Text(title)
                    .appFont(.screenTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !ownerName.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(ownerName)
                            .appFont(.screenOwner)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            if isSplit {
                Divider()
                    .opacity(0.24)
            }

            metadataBadges

            if let onOpenOriginal {
                Button(action: onOpenOriginal) {
                    Label("View Original Video", systemImage: "arrow.up.forward.app")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.primary)
                .padding(.top, AppSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isSplit ? 20 : AppSpacing.l)
        .padding(.vertical, isSplit ? 20 : AppSpacing.l)
    }

    private var metadataBadges: some View {
        FlowLayout(spacing: AppSpacing.s) {
            Label("Offline", systemImage: "arrow.down.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.biliAccent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.biliAccent.opacity(0.16), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.biliAccent.opacity(0.28), lineWidth: AppStroke.hairlineWidth)
                )

            if !qualityLabel.isEmpty {
                Text(qualityLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: AppStroke.hairlineWidth)
                    )
            }

            if fileSizeBytes > 0 {
                Label(formattedSize, systemImage: "internaldrive")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.09), lineWidth: AppStroke.hairlineWidth)
                    )
            }
        }
    }
}

struct OfflinePlayerPage<Player: View, Metadata: View>: View {
    let layout: OfflinePlayerLayout
    let viewportHeight: CGFloat
    private let player: () -> Player
    private let metadata: () -> Metadata

    init(
        layout: OfflinePlayerLayout,
        viewportHeight: CGFloat,
        @ViewBuilder player: @escaping () -> Player,
        @ViewBuilder metadata: @escaping () -> Metadata
    ) {
        self.layout = layout
        self.viewportHeight = viewportHeight
        self.player = player
        self.metadata = metadata
    }

    var body: some View {
        let stageInset = layout.isSplit ? DetailStageLayout.outerMargin : 0
        let columnHeight = max(0, viewportHeight - 2 * stageInset)
        let columns = layout.isSplit
            ? AnyLayout(HStackLayout(alignment: .top, spacing: DetailStageLayout.columnGap))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        let panelShape = RoundedRectangle(
            cornerRadius: layout.isSplit ? DetailStageLayout.panelCornerRadius : 0,
            style: .continuous
        )

        columns {
            player()
                .frame(
                    width: layout.playerSize.width,
                    height: layout.playerSize.height,
                    alignment: .topLeading
                )
                .frame(
                    width: layout.primaryColumnWidth,
                    height: layout.isSplit ? columnHeight : layout.playerSize.height,
                    alignment: .top
                )

            ScrollView(.vertical) {
                metadata()
                    .frame(width: layout.metadataWidth, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(
                width: layout.metadataWidth,
                height: layout.isSplit ? columnHeight : nil,
                alignment: .topLeading
            )
            .frame(maxHeight: layout.isSplit ? nil : .infinity, alignment: .topLeading)
            .clipShape(panelShape)
            .background {
                if layout.isSplit {
                    Color.clear
                        .appCardSurface(in: panelShape)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(stageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
