import Kingfisher
import SwiftUI

struct AvatarImage: View {
    let urlString: String?
    var size: CGFloat = 40

    @Environment(\.imageDiagnosticsScreen) private var diagnosticsScreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var site: ImageSite {
        ImageSite(screen: diagnosticsScreen, component: "AvatarImage")
    }

    var body: some View {
        let scale = UIScreen.main.scale
        RequestedAvatarImage(
            sourceURL: urlString ?? "",
            pointSize: size,
            scale: scale,
            reduceMotion: reduceMotion,
            site: site
        )
        .equatable()
        .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct RequestedAvatarImage: View, Equatable {
    let sourceURL: String
    let requestedURL: String
    let downsampleSize: CGSize
    let scale: CGFloat
    let reduceMotion: Bool
    let site: ImageSite

    init(
        sourceURL: String,
        pointSize: CGFloat,
        scale: CGFloat,
        reduceMotion: Bool,
        site: ImageSite
    ) {
        self.sourceURL = sourceURL
        self.scale = scale
        self.reduceMotion = reduceMotion
        self.site = site
        requestedURL = sourceURL.biliResized(
            toPixel: CGSize(width: pointSize * scale, height: pointSize * scale),
            crop: true
        )
        downsampleSize = CGSize(width: pointSize, height: pointSize)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestedURL == rhs.requestedURL
            && lhs.downsampleSize == rhs.downsampleSize
            && lhs.scale == rhs.scale
            && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        KFImage(URL(string: requestedURL))
            .setProcessor(DownsamplingImageProcessor(size: downsampleSize))
            .scaleFactor(scale)
            .cancelOnDisappear(true)
            .onSuccess { result in
                let source: ImageDiagnosticsSource = switch result.cacheType {
                case .memory: .memory
                case .disk: .disk
                case .none: .network
                }
                let image = result.image
                ImageDiagnostics.noteCompletion(
                    url: sourceURL,
                    source: source,
                    pixels: CGSize(
                        width: image.size.width * image.scale,
                        height: image.size.height * image.scale
                    ),
                    rendered: downsampleSize,
                    at: site
                )
            }
            .onFailure { _ in
                ImageDiagnostics.noteFailure(
                    url: sourceURL,
                    rendered: downsampleSize,
                    at: site
                )
            }
            .imageFadePolicy(reduceMotion: reduceMotion)
            .resizable()
            .imageLoadingCover(shape: .circle, shorterSide: downsampleSize.width)
    }
}
