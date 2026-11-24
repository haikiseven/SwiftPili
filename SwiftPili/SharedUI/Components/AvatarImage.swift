import Kingfisher
import SwiftUI

struct AvatarImage: View {
    let urlString: String?
    var size: CGFloat = 40

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let scale = displayScale > 0 ? displayScale : 1
        RequestedAvatarImage(
            sourceURL: urlString ?? "",
            pointSize: size,
            scale: scale,
            reduceMotion: reduceMotion
        )
        .equatable()
        .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct RequestedAvatarImage: View, Equatable {
    let requestedURL: String
    let downsampleSize: CGSize
    let scale: CGFloat
    let reduceMotion: Bool

    init(
        sourceURL: String,
        pointSize: CGFloat,
        scale: CGFloat,
        reduceMotion: Bool
    ) {
        self.scale = scale
        self.reduceMotion = reduceMotion
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
            .backgroundDecode()
            .scaleFactor(scale)
            .cancelOnDisappear(true)
            .imageFadePolicy(reduceMotion: reduceMotion)
            .resizable()
            .imageLoadingCover(shape: .circle, shorterSide: downsampleSize.width)
    }
}
