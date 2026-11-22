import Kingfisher
import SwiftUI

struct MediaGridView: View {
    struct Media {
        let url: URL
        var pixelSize: CGSize?

        var isGIF: Bool { url.pathExtension.lowercased() == "gif" }
        var isLongImage: Bool {
            guard let size = pixelSize, size.width > 0 else { return false }
            return size.height / size.width > 2.6
        }
    }

    enum Layout {
        case moment
        case comment
    }

    @Environment(\.imageDiagnosticsScreen) private var diagnosticsScreen
    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    let media: [Media]
    var layout: Layout = .moment
    var maxWidth: CGFloat?
    var sourceID: String?
    var onTap: ((ImagePreviewItem) -> Void)?

    @State private var previewSourceGroup = ImagePreviewSourceGroup()

    init(media: [Media], layout: Layout = .moment, maxWidth: CGFloat? = nil,
         sourceID: String? = nil, onTap: ((ImagePreviewItem) -> Void)? = nil) {
        self.media = media
        self.layout = layout
        self.maxWidth = maxWidth
        self.sourceID = sourceID
        self.onTap = onTap
    }

    private var columns: Int {
        switch media.count {
        case 1: 1
        case 2, 4: 2
        default: 3
        }
    }

    private static let spacing: CGFloat = CommentMediaMetrics.gridSpacing

    private var availableWidth: CGFloat? {
        let env = envColumnWidth.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
        let cap = maxWidth.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
        if let env, let cap { return min(env, cap) }
        return env ?? cap
    }

    private var resolvedTileSize: CGSize? {
        guard !media.isEmpty, let width = availableWidth, width > 1 else { return nil }
        switch layout {
        case .comment:
            let geo = CommentMediaMetrics.gridGeometry(
                count: media.count, singlePixelSize: media[0].pixelSize, width: width, spacing: Self.spacing
            )
            guard let size = geo.frames.first?.size, size.width > 1, size.height > 1 else { return nil }
            return size
        case .moment:
            if media.count == 1 {
                let size = MomentSingleImageLayout(
                    pixelSize: media[0].pixelSize, maxWidth: maxWidth
                ).frameSize(forWidth: width)
                return size.width > 1 && size.height > 1 ? size : nil
            }
            let cols: CGFloat = (media.count == 2 || media.count == 4) ? 2 : 3
            let side = ((width - Self.spacing * (cols - 1)) / cols).rounded(.down)
            return side > 1 ? CGSize(width: side, height: side) : nil
        }
    }

    var body: some View {
        grid
            .frame(maxWidth: maxWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var grid: some View {
        let tileSize = resolvedTileSize
        let previewURLs = (!media.isEmpty && sourceID?.isEmpty == false) ? media.map(\.url) : []
        switch layout {
        case .moment: momentGrid(tileSize: tileSize, previewURLs: previewURLs)
        case .comment: commentGrid(tileSize: tileSize, previewURLs: previewURLs)
        }
    }

    @ViewBuilder
    private func commentGrid(tileSize: CGSize?, previewURLs: [URL]) -> some View {
        if !media.isEmpty {
            let gridLayout = CommentGridLayout(
                count: media.count,
                singlePixelSize: media[0].pixelSize,
                maxWidth: maxWidth ?? CommentMediaMetrics.maxWidth,
                spacing: Self.spacing
            )
            gridLayout {
                if media.count == 1 {
                    commentSingleImage(
                        cropsToBox: CommentMediaMetrics.singleCropsToBox(media[0].pixelSize),
                        tileSize: tileSize,
                        previewURLs: previewURLs
                    )
                } else {
                    ForEach(Array(media.prefix(9).enumerated()), id: \.offset) { index, item in
                        cell(item, index: index, tileSize: tileSize, previewURLs: previewURLs)
                    }
                }
            }
        }
    }

    private func commentSingleImage(cropsToBox: Bool, tileSize: CGSize?, previewURLs: [URL]) -> some View {
        Button {
            let urls = previewURLs.isEmpty ? media.map(\.url) : previewURLs
            onTap?(previewSourceGroup.makeItem(urls: urls, index: 0, sourceID: sourceID))
        } label: {
            Color.clear
                .overlay {
                    imageView(media[0], index: 0, tileSize: tileSize, cropped: cropsToBox, cropAlignment: .top)
                }
                .overlay(alignment: .bottomTrailing) { badge(media[0]) }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.control))
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.control))
                .imagePreviewSource(
                    group: previewSourceGroup, sourceID: sourceID, urls: previewURLs, index: 0,
                    pixelSize: media[0].pixelSize, cornerRadius: AppRadius.control,
                    cropped: cropsToBox || media[0].isGIF,
                    alignment: media[0].isGIF ? .center : .top
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func momentGrid(tileSize: CGSize?, previewURLs: [URL]) -> some View {
        if media.count == 1 {
            singleImage(tileSize: tileSize, previewURLs: previewURLs)
        } else if !media.isEmpty {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                spacing: Self.spacing
            ) {
                ForEach(Array(media.prefix(9).enumerated()), id: \.offset) { index, item in
                    cell(item, index: index, tileSize: tileSize, previewURLs: previewURLs)
                }
            }
        }
    }

    private func singleImage(tileSize: CGSize?, previewURLs: [URL]) -> some View {
        let item = media[0]
        let imageLayout = MomentSingleImageLayout(pixelSize: item.pixelSize, maxWidth: maxWidth)
        return imageLayout {
            Button {
                let urls = previewURLs.isEmpty ? media.map(\.url) : previewURLs
                onTap?(previewSourceGroup.makeItem(urls: urls, index: 0, sourceID: sourceID))
            } label: {
                Color.clear
                    .overlay {
                        imageView(
                            item,
                            index: 0,
                            tileSize: tileSize,
                            cropped: imageLayout.cropsToBox,
                            cropAlignment: .top,
                            allowsServerCrop: false
                        )
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if item.isGIF || imageLayout.isLongImage { badge(item) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.control))
                    .contentShape(RoundedRectangle(cornerRadius: AppRadius.control))
                    .imagePreviewSource(
                        group: previewSourceGroup, sourceID: sourceID, urls: previewURLs, index: 0,
                        pixelSize: item.pixelSize, cornerRadius: AppRadius.control,
                        cropped: imageLayout.cropsToBox || item.isGIF,
                        alignment: item.isGIF ? .center : .top
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func cell(_ item: Media, index: Int, tileSize: CGSize?, previewURLs: [URL]) -> some View {
        Button {
            let urls = previewURLs.isEmpty ? media.map(\.url) : previewURLs
            onTap?(previewSourceGroup.makeItem(urls: urls, index: index, sourceID: sourceID))
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { imageView(item, index: index, tileSize: tileSize, cropped: true) }
                .overlay(alignment: .bottomTrailing) { badge(item) }
                .overlay {
                    if index == 8, media.count > 9 {
                        ZStack {
                            Rectangle().fill(.black.opacity(0.45))
                            Text("+\(media.count - 9)")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail))
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail))
                .imagePreviewSource(
                    group: previewSourceGroup, sourceID: sourceID, urls: previewURLs, index: index,
                    pixelSize: item.pixelSize, cornerRadius: AppRadius.thumbnail, cropped: true,
                    alignment: item.isLongImage && !item.isGIF ? .top : .center
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func imageView(
        _ item: Media, index: Int, tileSize: CGSize?, cropped: Bool,
        cropAlignment: Alignment = .center, allowsServerCrop: Bool = true
    ) -> some View {
        let onLoaded: (UIImage) -> Void = { previewSourceGroup.recordThumbnail($0, for: item.url, index: index) }
        if item.isGIF {
            AnimatedMediaImage(
                urlString: item.url.absoluteString, contentMode: .scaleAspectFill,
                screen: diagnosticsScreen, onLoadedImage: onLoaded
            )
        } else if item.isLongImage {
            CoverImage(
                urlString: item.url.absoluteString, displaySize: tileSize,
                contentMode: .fill, fillAlignment: .top, fillsOfferedBox: true, onLoadedImage: onLoaded
            )
        } else {
            CoverImage(
                urlString: item.url.absoluteString, displaySize: tileSize,
                contentMode: cropped ? .fill : .fit, requestsServerCrop: cropped && allowsServerCrop,
                fillAlignment: cropAlignment, fillsOfferedBox: true, onLoadedImage: onLoaded
            )
        }
    }

    @ViewBuilder
    private func badge(_ item: Media) -> some View {
        if item.isGIF {
            MediaCornerBadge(text: "GIF")
        } else if item.isLongImage {
            MediaCornerBadge(text: String(localized: "Long Image"))
        }
    }
}

private struct MomentSingleImageLayout: Layout {
    let pixelSize: CGSize?
    let maxWidth: CGFloat?

    private var heightRatio: CGFloat? {
        guard let pixelSize, pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return pixelSize.height / pixelSize.width
    }

    var isLongImage: Bool { (heightRatio ?? 0) > 2.6 }
    var cropsToBox: Bool { heightRatio == nil || isLongImage }

    func frameSize(forWidth proposedWidth: CGFloat?) -> CGSize {
        let limit = min(maxWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 320, 320)
        let offered = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? limit
        let width = max(0, min(offered, limit))
        guard let heightRatio else {
            return CGSize(width: width, height: width * 3 / 4)
        }
        if isLongImage {
            return CGSize(width: width, height: min(width * 1.5, 360))
        }
        let fittedWidth = min(width, 360 / heightRatio)
        return CGSize(width: fittedWidth, height: fittedWidth * heightRatio)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        frameSize(forWidth: proposal.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let imageSize = frameSize(forWidth: proposal.width)
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(imageSize))
        }
    }
}

private struct CommentGridLayout: Layout {
    let count: Int
    let singlePixelSize: CGSize?
    let maxWidth: CGFloat
    let spacing: CGFloat

    private func geometry(for proposal: ProposedViewSize) -> CommentMediaMetrics.GridGeometry {
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? maxWidth
        return CommentMediaMetrics.gridGeometry(
            count: count,
            singlePixelSize: singlePixelSize,
            width: min(offered, maxWidth),
            spacing: spacing
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        geometry(for: proposal).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let frames = geometry(for: proposal).frames
        for (index, subview) in subviews.enumerated() {
            let frame = index < frames.count ? frames[index] : .zero
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

private struct AnimatedMediaImage: View {
    let urlString: String
    let contentMode: UIView.ContentMode
    let screen: String
    var onLoadedImage: ((UIImage) -> Void)?

    var body: some View {
        KFAnimatedImage(URL(string: urlString.httpsURL))
            .configure { view in
                view.contentMode = contentMode
                view.clipsToBounds = true
            }
            .purgeFramesOnBackground()
            .cancelOnDisappear(true)
            .onSuccess { result in
                let source: ImageDiagnosticsSource = switch result.cacheType {
                case .memory: .memory
                case .disk: .disk
                case .none: .network
                }
                let image = result.image
                onLoadedImage?(image)
                ImageDiagnostics.noteCompletion(
                    url: urlString,
                    source: source,
                    pixels: CGSize(
                        width: image.size.width * image.scale,
                        height: image.size.height * image.scale
                    ),
                    rendered: nil,
                    at: ImageSite(screen: screen, component: "MediaGridView.gif")
                )
            }
            .onFailure { _ in
                ImageDiagnostics.noteFailure(
                    url: urlString, rendered: nil,
                    at: ImageSite(screen: screen, component: "MediaGridView.gif")
                )
            }
            .imageLoadingCover()
    }
}

struct MediaCornerBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .appFont(.overlayBadge)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: AppRadius.badge))
            .padding(5)
    }
}
