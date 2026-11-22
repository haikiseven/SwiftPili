import SwiftUI

struct OfflinePlayerLayout {
    let isSplit: Bool
    let playerSize: CGSize
    let metadataWidth: CGFloat

    init(
        containerSize: CGSize, layoutContainerSize: CGSize,
        isPad: Bool, isPortraitContent: Bool, isCondensed: Bool
    ) {
        isSplit = DetailSplitPolicy.usesSplit(
            isPad: isPad,
            containerSize: layoutContainerSize
        )
        let stageContentWidth = max(
            0, containerSize.width - 2 * DetailStageLayout.outerMargin - DetailStageLayout.columnGap
        )
        let panelWidth = DetailStageLayout.panelWidth(containerWidth: containerSize.width)
        let width = isSplit
            ? floor(max(0, stageContentWidth - panelWidth))
            : max(0, containerSize.width)
        let height = DetailPlayerGeometry.videoHeight(
            containerWidth: containerSize.width,
            primaryColumnWidth: isSplit ? width : nil,
            isPortraitContent: isPortraitContent,
            isCondensed: isCondensed
        )
        playerSize = CGSize(width: width, height: height)
        metadataWidth = isSplit
            ? floor(panelWidth)
            : max(0, containerSize.width)
    }
}

struct OfflinePlayerMetadataView: View {
    let title: String
    let ownerName: String
    let qualityLabel: String
    let fileSizeBytes: Int64
    var isSplit = false

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isSplit ? AppSpacing.m : 10) {
            if isSplit {
                Label("Offline", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.biliAccent)
            }

            Text(title)
                .appFont(isSplit ? .screenTitle : .rowTitle)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if isSplit {
                Divider()
                    .opacity(0.28)
                splitMetaSection
            } else {
                compactMetaRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isSplit ? 20 : AppSpacing.l)
        .padding(.vertical, isSplit ? 20 : 14)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var splitMetaSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            if !ownerName.isEmpty {
                Label(ownerName, systemImage: "person.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            HStack(spacing: AppSpacing.s) {
                if !qualityLabel.isEmpty {
                    Text(qualityLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.88))
                        .padding(.horizontal, AppSpacing.s)
                        .padding(.vertical, 3)
                        .background(AppFill.inset, in: Capsule())
                }
                Text(formattedSize)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compactMetaRow: some View {
        HStack(spacing: AppSpacing.s) {
            if !ownerName.isEmpty {
                Text(ownerName)
            }
            if !qualityLabel.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(qualityLabel)
            }
            Text("·")
                .foregroundStyle(.tertiary)
            Text(formattedSize)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct OfflinePlayerPage<Player: View, Metadata: View>: View {
    let layout: OfflinePlayerLayout
    let viewportHeight: CGFloat
    private let player: () -> Player
    private let metadata: () -> Metadata
    @State private var metadataHeight: CGFloat?

    init(
        layout: OfflinePlayerLayout, viewportHeight: CGFloat,
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
        let needsOuterScroll = !layout.isSplit
            && layout.playerSize.height + (metadataHeight ?? 0) > viewportHeight
        let columns = layout.isSplit
            ? AnyLayout(HStackLayout(alignment: .top, spacing: DetailStageLayout.columnGap))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        let panelShape = RoundedRectangle(
            cornerRadius: layout.isSplit ? DetailStageLayout.panelCornerRadius : 0,
            style: .continuous
        )
        ScrollView(needsOuterScroll ? .vertical : []) {
            columns {
                ScrollView(layout.isSplit && layout.playerSize.height > columnHeight ? .vertical : []) {
                    player()
                }
                .scrollClipDisabled()
                .frame(
                    width: layout.playerSize.width,
                    height: layout.isSplit ? columnHeight : layout.playerSize.height,
                    alignment: .topLeading
                )

                ScrollView(layout.isSplit && (metadataHeight ?? 0) > columnHeight ? .vertical : []) {
                    metadata()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if metadataHeight == nil || abs((metadataHeight ?? 0) - height) > 0.5 {
                                metadataHeight = height
                            }
                        }
                }
                .frame(
                    width: layout.metadataWidth,
                    height: layout.isSplit ? columnHeight : metadataHeight,
                    alignment: .topLeading
                )
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
