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

    private struct Measurement: Equatable {
        var box: CGSize = .zero
        var url: String = ""
    }

    @State private var measurement = Measurement()

    private var measuredBox: CGSize { measurement.url == urlString ? measurement.box : .zero }

    @Environment(\.imageDiagnosticsScreen) private var diagnosticsScreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let componentFile: String
    private let componentLine: Int

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
        componentFile = file
        componentLine = line
    }

    private var site: ImageSite {
        guard ImageDiagnostics.isRecordingImageEvents || PlayerLog.isCapturing else {
            return ImageSite(screen: "", component: "")
        }
        return ImageSite(
            screen: diagnosticsScreen,
            component: "\((componentFile as NSString).lastPathComponent):\(componentLine)"
        )
    }

    var body: some View {
        UIHitchMonitor.count("img.body")
        ImageDiagnostics.noteBody()
        let drawn = displayBox
        let box = requestBox(drawnBox: drawn)
        return inOfferedBox(image(box: box, drawn: drawn)
            .onAppear {
                UIHitchMonitor.count("img.appear")
                ImageDiagnostics.noteAppear(url: urlString, rendered: box, at: site)
            }
            .onDisappear {
                UIHitchMonitor.count("img.gone")
                ImageDiagnostics.noteDisappear(url: urlString, at: site)
            }
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

    private func requestBoxDriftNote(drawn: CGSize, requested: CGSize) -> String {
        guard contentMode == .fill, drawn.width > 0, drawn.height > 0,
              requested.width > 0, requested.height > 0
        else { return "" }
        let intended = cropsOnServer(drawnBox: drawn)
            ? drawn
            : headroomBox(drawn, drawnBox: drawn)
        guard intended.width > 0, intended.height > 0 else { return "" }
        let intendedRatio = intended.height / intended.width
        let requestedRatio = requested.height / requested.width
        let drift = abs(requestedRatio - intendedRatio) / intendedRatio
        guard drift > 0.01 else { return "" }
        return String(format: " ⚠️ REQUEST-BOX-DRIFT %.0f%%", drift * 100)
    }

    private func claimVersusBitmapNote(
        agreement: CoverFrameAgreement,
        bitmap: CGSize,
        frame: CGSize
    ) -> String {
        guard sourceRelation == .authored, agreement == .mismatch,
              bitmap.height > 0, frame.height > 0
        else { return "" }
        return String(
            format: " ⚠️ AUTHORED-CLAIM-UNMET bitmap %.2f vs frame %.2f",
            bitmap.width / bitmap.height,
            frame.width / frame.height
        )
    }

    private func fillCropNote(bitmap: CGSize, frame: CGSize) -> String {
        guard contentMode == .fill, bitmap.width > 0, bitmap.height > 0,
              frame.width > 0, frame.height > 0
        else { return "" }
        let bitmapRatio = bitmap.width / bitmap.height
        let frameRatio = frame.width / frame.height
        let (axis, kept) = bitmapRatio > frameRatio
            ? ("w", frameRatio / bitmapRatio)
            : ("h", bitmapRatio / frameRatio)
        guard kept < 0.99 else { return "" }
        return String(format: " crop=%@%.0f%%", axis, kept * 100)
    }

    private func contentScaleNote(bitmapPoints: CGSize, frame: CGSize) -> String {
        guard bitmapPoints.width > 0, bitmapPoints.height > 0,
              frame.width > 0, frame.height > 0
        else { return "" }
        let byWidth = frame.width / bitmapPoints.width
        let byHeight = frame.height / bitmapPoints.height
        let scale = contentMode == .fill ? max(byWidth, byHeight) : min(byWidth, byHeight)
        return String(format: " scale=x%.2f", scale)
            + (scale > 1.01 ? " ⚠️ CONTENT-UPSCALE" : "")
    }

    @ViewBuilder
    private func image(box: CGSize, drawn: CGSize) -> some View {
        if box.width > 1, box.height > 1 {
            let serverCrops = cropsOnServer(drawnBox: drawn)
            let scale = UIScreen.main.scale
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
                site: site,
                onSuccess: { result in
                    let source: ImageDiagnosticsSource
                    switch result.cacheType {
                    case .memory:
                        UIHitchMonitor.count("img.hit.mem")
                        source = .memory
                    case .disk:
                        UIHitchMonitor.count("img.hit.disk")
                        source = .disk
                    case .none:
                        UIHitchMonitor.count("img.miss")
                        source = .network
                    }
                    let image = result.image
                    onLoadedImage?(image)
                    let px = CGSize(
                        width: image.size.width * image.scale,
                        height: image.size.height * image.scale
                    )
                    if PlayerLog.isCapturing, ImagePipelinePolicy.emitsImageDiagnostics {
                        let ratio = { (s: CGSize) in
                            s.width > 0 ? String(format: "%.2f", s.height / s.width) : "-"
                        }
                        let shown = drawn
                        let agreement = CoverFrameAgreement.measured(
                            bitmap: px, frame: shown, serverCropped: serverCrops
                        )
                        PlayerLog.log(
                            "[cover] \(site.component) display=\(Int(shown.width))x\(Int(shown.height))"
                            + "(\(ratio(shown))) request=\(Int(box.width))x\(Int(box.height))"
                            + "(\(ratio(box))) returned=\(Int(px.width))x\(Int(px.height))"
                            + "(\(ratio(px))) mode=\(contentMode == .fill ? "fill" : "fit")"
                            + " serverCrop=\(serverCrops ? "1c" : "none")"
                            + " src=\(source)"
                            + (sourceRelation.map { " rel=\($0.rawValue)" } ?? "")
                            + " measured=\(agreement.rawValue)"
                            + (isDecorative ? " role=decorative" : "")
                            + requestBoxDriftNote(drawn: shown, requested: box)
                            + fillCropNote(bitmap: px, frame: shown)
                            + contentScaleNote(bitmapPoints: image.size, frame: shown)
                            + claimVersusBitmapNote(agreement: agreement, bitmap: px, frame: shown)
                        )
                    }
                    ImageDiagnostics.noteCompletion(
                        url: urlString,
                        source: source,
                        pixels: px,
                        rendered: box,
                        at: site
                    )
                },
                onFailure: { _ in
                    UIHitchMonitor.count("img.fail")
                    ImageDiagnostics.noteFailure(url: urlString, rendered: box, at: site)
                }
            )
            .equatable()

            if contentMode == .fill {
                geometryProbed(
                    geometryProbed(
                        kf.scaledToFill(),
                        layer: "art",
                        drawn: drawn
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fillAlignment),
                    layer: "clip",
                    drawn: drawn
                )
                .clipped()
            } else {
                geometryProbed(
                    geometryProbed(
                        kf.scaledToFit(),
                        layer: "art",
                        drawn: drawn
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity),
                    layer: "clip",
                    drawn: drawn
                )
            }
        } else {
            if isDecorative {
                Color.clear
            } else {
                LoadingCover(shape: .rect, ground: .clear, showsIndicator: false)
            }
        }
    }

    @ViewBuilder
    private func geometryProbed<V: View>(_ view: V, layer: String, drawn: CGSize) -> some View {
        if ImagePipelinePolicy.installsCoverGeometryProbes {
            view.background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { noteGeometry(layer: layer, laidOut: geo.size, drawn: drawn) }
                        .onChange(of: geo.size) { _, size in
                            noteGeometry(layer: layer, laidOut: size, drawn: drawn)
                        }
                }
            }
        } else {
            view
        }
    }

    private func noteGeometry(layer: String, laidOut: CGSize, drawn: CGSize) {
        guard PlayerLog.isCapturing, laidOut.width > 1, laidOut.height > 1 else { return }
        var verdict = ""
        if layer == "clip" {
            if drawn.width > 1, drawn.height > 1,
               laidOut.width > drawn.width + 1 || laidOut.height > drawn.height + 1 {
                verdict = " ⚠️ CLIP-EXCEEDS-FRAME"
            }
        } else if drawn.width > 1, drawn.height > 1 {
            let overWidth = laidOut.width > drawn.width + 1
            let overHeight = laidOut.height > drawn.height + 1
            if contentMode == .fit, overWidth || overHeight {
                verdict = " ⚠️ FIT-OVERFLOWS-FRAME"
            } else if contentMode == .fill, overWidth, overHeight {
                verdict = " ⚠️ FILL-OVERFLOWS-BOTH-AXES"
            }
        }
        PlayerLog.log(
            "[cover-geo] \(site.component) layer=\(layer)"
            + " laidOut=\(Int(laidOut.width))x\(Int(laidOut.height))"
            + " drawn=\(Int(drawn.width))x\(Int(drawn.height))"
            + " mode=\(contentMode == .fill ? "fill" : "fit")"
            + (isDecorative ? " role=decorative" : "")
            + verdict
        )
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
                .onAppear { if geo.size != measuredBox { noteMeasured(geo.size) } }
                .onChange(of: geo.size) { _, s in if s != measuredBox { noteMeasured(s) } }
        }
        .id(urlString)
    }

    private func noteMeasured(_ size: CGSize) {
        UIHitchMonitor.count("img.probe")
        ImageDiagnostics.noteProbe(url: urlString, rendered: size, at: site)
        measurement = Measurement(box: size, url: urlString)
    }

    private func fixedSide(_ side: CGFloat) -> CGFloat? {
        displaySize == nil || fillsOfferedBox ? nil : side
    }
}

private struct RequestedCoverImage: View, Equatable {
    let sourceURL: String
    let requestedURL: String
    let requestBox: CGSize
    let scale: CGFloat
    let reduceMotion: Bool
    let isDecorative: Bool
    let chromeSide: CGFloat
    let site: ImageSite
    let onSuccess: (RetrieveImageResult) -> Void
    let onFailure: (KingfisherError) -> Void

    init(
        sourceURL: String,
        requestBox: CGSize,
        scale: CGFloat,
        serverCrops: Bool,
        reduceMotion: Bool,
        isDecorative: Bool,
        chromeSide: CGFloat,
        site: ImageSite,
        onSuccess: @escaping (RetrieveImageResult) -> Void,
        onFailure: @escaping (KingfisherError) -> Void
    ) {
        self.sourceURL = sourceURL
        self.requestBox = requestBox
        self.scale = scale
        self.reduceMotion = reduceMotion
        self.isDecorative = isDecorative
        self.chromeSide = chromeSide
        self.site = site
        self.onSuccess = onSuccess
        self.onFailure = onFailure
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
    }

    var body: some View {
        let processor = DownsamplingImageProcessor(size: requestBox)
        let kf = ImageDiagnostics.measuringSetup(url: sourceURL, rendered: requestBox, at: site) {
            UIHitchMonitor.measure("img.kf") {
                KFImage(URL(string: requestedURL))
                    .setProcessor(processor)
                    .scaleFactor(scale)
                    .cancelOnDisappear(true)
                    .onSuccess(onSuccess)
                    .onFailure(onFailure)
                    .imageFadePolicy(reduceMotion: reduceMotion)
                    .resizable()
            }
        }
        covered(kf, shorterSide: chromeSide)
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
