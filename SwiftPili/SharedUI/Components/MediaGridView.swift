import Kingfisher
import SwiftUI

/// Standard nine-grid image layout for moments and comments.
///
/// Two layouts, chosen by `layout`: `.moment` fits ordinary single images within
/// a bounded rectangle (2/4 images in two flexible columns, else three); `.comment` sizes
/// every box from `CommentMediaMetrics.gridGeometry` — PiliPlus's rule, so a
/// single image is NOT always full width and four images are a 2×2 of third
/// cells.
///
/// Cells OWN their geometry: each is a fixed-aspect `Color.clear` box and
/// the image fills it via `.overlay` + clipping. Applying `scaledToFill`
/// directly to an image in a flexible grid cell lets its layout box grow
/// past the cell (`.clipped()` only trims drawing, not layout), which
/// overlaps rows and shifts the whole grid whenever an image loads.
struct MediaGridView: View {
    struct Media {
        let url: URL
        var pixelSize: CGSize?

        var isGIF: Bool { url.pathExtension.lowercased() == "gif" }
        /// 长图 threshold (matches PiliPlus): taller than 2.6× its width.
        /// Stills render top-cropped; GIF rendering and badge take precedence.
        var isLongImage: Bool {
            guard let size = pixelSize, size.width > 0 else { return false }
            return size.height / size.width > 2.6
        }
    }

    enum Layout {
        /// Bounded natural-aspect singles and row-filling multi-image grids.
        case moment
        /// Sized by `CommentMediaMetrics.gridGeometry` inside `maxWidth`.
        case comment
    }

    @Environment(\.imageDiagnosticsScreen) private var diagnosticsScreen
    @Environment(\.rowCardColumnWidth) private var envColumnWidth

    let media: [Media]
    var layout: Layout = .moment
    /// Upper bound on the whole grid's width, leading-aligned; `nil` = the
    /// row's width. Moment singles may narrow further to preserve their aspect
    /// within the single-image height cap. Under `.comment` it is PiliPlus's
    /// `W`, the width the grid rule divides.
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
        case 2, 4: 2 // 2 and 4 images look balanced as a 2-wide grid
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

    /// Deterministic tile size when width is known, skipping `CoverImage`'s `GeometryReader` probe.
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
            // Both layouts can be narrower than the offered row: keep the
            // unused alignment space transparent and the actual boxes leading.
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

    /// Every box placed by `CommentMediaMetrics.gridGeometry` at the width this
    /// view is actually offered, so a narrow phone and an iPad's capped 360pt
    /// both get PiliPlus's proportions.
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

    /// A comment's single image. The layout hands it a box already at the
    /// image's own aspect (up to the 2.6 long-image cap), so `Color.clear`
    /// simply takes that box; only a capped or dimensionless source is cropped,
    /// top-anchored like the moment single.
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

    /// The proposal-derived rectangle owns placeholder, image, badge and hit
    /// target. Ordinary images keep their complete source aspect; long or
    /// dimensionless stills fill a stable preview from the top. The unused row
    /// beside a narrowed image remains transparent.
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
                // Square tile ⇒ crop to it, and ask the CDN for that crop:
                // letterboxing a 4:3 photo inside a square tile wastes a
                // third of the cell and downloads pixels nobody sees. Safe
                // for the layout because the cell owns its geometry (the
                // rule at the top of this file) — the image is an overlay on
                // a fixed-aspect box and CoverImage clips inside itself, so
                // nothing here can reflow.
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

    /// `cropped` fills the box on the client. Square tiles also allow the CDN's
    /// center crop; moment singles keep the original framing in the request.
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
            // Top-anchored fill so tall screenshots show their readable start without grey letterboxing.
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

/// A moment single's box is fixed by metadata and the local proposal, never by
/// a decoded image or a geometry-state round trip. The enclosing row supplies
/// transparent leading alignment without enlarging the image's own rectangle.
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

/// Places a `.comment` grid's subviews at `CommentMediaMetrics.gridGeometry`'s
/// frames, at W = min(offered width, `maxWidth`). A `Layout` rather than a
/// `GeometryReader` because the grid's height depends on its width and a
/// reader cannot report a height back to the list row.
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

/// Animated GIF cell.
///
/// **Frame decode size is already handled by Kingfisher, and an earlier version
/// of this file claimed otherwise.** `AnimatedImageView.needsPrescaling`
/// defaults to `true` and does apply here. The retracted reasoning was that the
/// representer assigns `view.image` inside `makeUIView()`, on a view with no
/// bounds yet, so the animator would be built with `targetSize == .zero` and
/// skip its resize. Traced through the pinned checkout, that is not the order:
/// `KFImageRenderer.body` materialises `renderedImage()` unconditionally (at
/// opacity 0) while `binder.loadedImage` is still nil, so `makeUIView` receives
/// nil, `AnimatedImageView.image`'s didSet takes its `image != oldValue` early
/// out, and NO animator is built. The animator is built later, in
/// `updateUIView` when the loaded image lands — by which point the view has a
/// real frame from the earlier layout pass, and prescaling targets the tile.
/// (The zero-bounds path is real only when the representable is materialised
/// after the load, i.e. under a SwiftUI `loadTransition`. Neither GIF site sets
/// one, so seeding a frame here would have guarded a path this app never takes.)
///
/// What is NOT handled, and is the honest remaining cost: the GIF is downloaded
/// at its source resolution. `biliResized` is not applied because it rewrites
/// the URL to `.webp`, and whether BiliBili's CDN answers an animated webp or a
/// static one for a `.gif` source is unverified — a static answer would kill the
/// animation, which is worse than the bytes. That needs a device check, not a
/// guess.
///
/// So the only real change here is `purgeFramesOnBackground()`:
/// `framePreloadCount` (10) decoded frames per visible GIF stay resident for as
/// long as the view lives, and backgrounding is the one moment they are
/// certainly not being drawn.
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
            // This branch bypasses CoverImage, so GIF cells would otherwise be
            // invisible to every img.* counter — and they are still the most
            // expensive cells in the grid.
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
                    // No rendered box: this view does not measure one, and
                    // inventing a value here would put a fabricated number in
                    // the variant-churn table.
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
            // Opaque ground, not `imagePlaceholder`: a GIF tile is an overlay
            // on a `Color.clear` aspect box with the feed behind it, so a
            // translucent fill let the card read through. Corners come from the
            // cell's own clip, hence `.rect`; the box is unstated because this
            // view genuinely does not measure one (see `rendered: nil` above),
            // and an unknown box never gates the spinner out.
            .imageLoadingCover()
    }
}

/// "GIF" / "长图" marker in a media cell's corner.
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
