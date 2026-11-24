import Kingfisher
import SwiftUI

struct CoverImage: View {
    let urlString: String
    var displaySize: CGSize?
    var contentMode: SwiftUI.ContentMode = .fit
    var requestsServerCrop: Bool = false
    var fillAlignment: Alignment = .center
    var requestHeadroom: CoverRequestHeadroom = .none
    var requestSize: CGSize?
    var groundColor: Color = .imagePlaceholderOpaque
    var isDecorative: Bool = false
    var sourceRelation: CoverSourceFrameRelation?
    var fillsOfferedBox: Bool = false
    var onLoadedImage: ((UIImage) -> Void)?

    @State private var measuredBox: CGSize = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    init(
        urlString: String,
        displaySize: CGSize? = nil,
        contentMode: SwiftUI.ContentMode = .fit,
        requestsServerCrop: Bool = false,
        fillAlignment: Alignment = .center,
        requestHeadroom: CoverRequestHeadroom = .none,
        requestSize: CGSize? = nil,
        groundColor: Color = .imagePlaceholderOpaque,
        isDecorative: Bool = false,
        sourceRelation: CoverSourceFrameRelation? = nil,
        fillsOfferedBox: Bool = false,
        onLoadedImage: ((UIImage) -> Void)? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        self.urlString = urlString
        self.displaySize = displaySize
        self.contentMode = contentMode
        self.requestsServerCrop = requestsServerCrop
        self.fillAlignment = fillAlignment
        self.requestHeadroom = requestHeadroom
        self.requestSize = requestSize
        self.groundColor = groundColor
        self.isDecorative = isDecorative
        self.sourceRelation = sourceRelation
        self.fillsOfferedBox = fillsOfferedBox
        self.onLoadedImage = onLoadedImage
        _ = (file, line)
    }

    var body: some View {
        let drawn = displayBox
        let box = requestBox(drawnBox: drawn)
        inOfferedBox(
            image(box: box, drawn: drawn)
                .background(groundColor)
        )
        .frame(width: fixedSide(drawn.width), height: fixedSide(drawn.height))
    }

    private var displayBox: CGSize {
        let pt = displaySize ?? measuredBox
        return CGSize(width: pt.width.rounded(), height: pt.height.rounded())
    }

    private func requestBox(drawnBox drawn: CGSize) -> CGSize {
        let usable = requestSize.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
        let pt = usable ?? displaySize ?? measuredBox
        let whole = CGSize(width: pt.width.rounded(), height: pt.height.rounded())
        let quantized = ImagePipelinePolicy.quantizedRequestBox(whole)
        guard cropsOnServer(drawnBox: drawn) else {
            return headroomBox(quantized, drawnBox: drawn)
        }
        return Self.serverCropBox(quantized, drawnBox: drawn)
    }

    private func headroomBox(_ requested: CGSize, drawnBox drawn: CGSize) -> CGSize {
        guard contentMode == .fill else { return requested }
        return requestHeadroom.box(requested, drawnBox: drawn)
    }

    private func cropsOnServer(drawnBox drawn: CGSize) -> Bool {
        requestsServerCrop && drawn.width > 1 && drawn.height > 1
    }

    static func serverCropBox(_ requested: CGSize, drawnBox drawn: CGSize) -> CGSize {
        guard drawn.width > 1, drawn.height > 1,
              requested.width > 1, requested.height > 1,
              drawn.width.isFinite, drawn.height.isFinite,
              requested.width.isFinite, requested.height.isFinite
        else { return requested }
        let scale = max(1, requested.width / drawn.width, requested.height / drawn.height)
        return CGSize(
            width: (drawn.width * scale).rounded(),
            height: (drawn.height * scale).rounded()
        )
    }

    @ViewBuilder
    private func image(box: CGSize, drawn: CGSize) -> some View {
        if box.width > 1, box.height > 1 {
            let serverCrops = cropsOnServer(drawnBox: drawn)
            let scale = displayScale > 0 ? displayScale : 1
            let chromeSide = min(drawn.width, drawn.height) > 1
                ? min(drawn.width, drawn.height)
                : min(box.width, box.height)
            let kf = RequestedCoverImage(
                sourceURL: urlString,
                requestBox: box,
                scale: scale,
                serverCrops: serverCrops,
                reduceMotion: reduceMotion,
                isDecorative: isDecorative,
                chromeSide: chromeSide,
                onLoadedImage: onLoadedImage
            )
            .equatable()

            if contentMode == .fill {
                kf.scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fillAlignment)
                    .clipped()
            } else {
                kf.scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if isDecorative {
            Color.clear
        } else {
            LoadingCover(shape: .rect, ground: .clear, showsIndicator: false)
        }
    }

    @ViewBuilder
    private func inOfferedBox<V: View>(_ content: V) -> some View {
        if displaySize == nil {
            sizeProbe.overlay { content }
        } else if fillsOfferedBox {
            Color.clear.overlay { content }.clipped()
        } else {
            content
        }
    }

    private var sizeProbe: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { updateMeasured(geo.size) }
                .onChange(of: geo.size) { _, size in updateMeasured(size) }
        }
    }

    private func updateMeasured(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return }
        guard abs(size.width - measuredBox.width) > 0.5 || abs(size.height - measuredBox.height) > 0.5 else {
            return
        }
        measuredBox = size
    }

    private func fixedSide(_ side: CGFloat) -> CGFloat? {
        displaySize == nil || fillsOfferedBox ? nil : side
    }
}

private struct RequestedCoverImage: View, Equatable {
    let requestedURL: String
    let requestBox: CGSize
    let scale: CGFloat
    let reduceMotion: Bool
    let isDecorative: Bool
    let chromeSide: CGFloat
    let hasLoadedCallback: Bool
    let onLoadedImage: ((UIImage) -> Void)?

    init(
        sourceURL: String,
        requestBox: CGSize,
        scale: CGFloat,
        serverCrops: Bool,
        reduceMotion: Bool,
        isDecorative: Bool,
        chromeSide: CGFloat,
        onLoadedImage: ((UIImage) -> Void)?
    ) {
        self.requestBox = requestBox
        self.scale = scale
        self.reduceMotion = reduceMotion
        self.isDecorative = isDecorative
        self.chromeSide = chromeSide
        self.hasLoadedCallback = onLoadedImage != nil
        self.onLoadedImage = onLoadedImage
        requestedURL = sourceURL.biliResized(
            toPixel: CGSize(width: requestBox.width * scale, height: requestBox.height * scale),
            crop: serverCrops
        )
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestedURL == rhs.requestedURL
            && lhs.requestBox == rhs.requestBox
            && lhs.scale == rhs.scale
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.isDecorative == rhs.isDecorative
            && lhs.chromeSide == rhs.chromeSide
            && lhs.hasLoadedCallback == rhs.hasLoadedCallback
    }

    var body: some View {
        var kf = KFImage(URL(string: requestedURL))
            .setProcessor(DownsamplingImageProcessor(size: requestBox))
            .backgroundDecode()
            .scaleFactor(scale)
            .cancelOnDisappear(true)
            .imageFadePolicy(reduceMotion: reduceMotion)
        if let onLoadedImage {
            kf = kf.onSuccess { onLoadedImage($0.image) }
        }
        return covered(kf.resizable(), shorterSide: chromeSide)
    }

    @ViewBuilder
    private func covered<Img: KFImageProtocol>(_ kf: Img, shorterSide: CGFloat) -> some View {
        if isDecorative {
            kf
        } else {
            kf.imageLoadingCover(ground: .clear, shorterSide: shorterSide)
        }
    }
}
