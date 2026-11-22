import Kingfisher
import SwiftUI

struct ArticleImage: View {
    let url: URL
    var availableWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    private static let reservedAspect: CGFloat = 4 / 3

    var body: some View {
        if let width = availableWidth, width > 1 {
            let box = CGSize(
                width: width.rounded(),
                height: (width / Self.reservedAspect).rounded()
            )
            Color.imagePlaceholder
                .frame(width: box.width, height: box.height)
                .overlay {
                    loadedImage(box: box)
                }
        } else {
            Color.imagePlaceholder
                .aspectRatio(Self.reservedAspect, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        let box = CGSize(
                            width: proxy.size.width.rounded(),
                            height: proxy.size.height.rounded()
                        )
                        if box.width > 1, box.height > 1 {
                            loadedImage(box: box)
                        }
                    }
                }
        }
    }

    private func loadedImage(box: CGSize) -> some View {
        let scale = displayScale
        return KFImage(URL(string: url.absoluteString.biliResized(
            toPixel: CGSize(
                width: box.width * scale,
                height: box.height * scale
            )
        )) ?? url)
            .setProcessor(DownsamplingImageProcessor(size: box))
            .scaleFactor(scale)
            .cancelOnDisappear(true)
            .imageFadePolicy(reduceMotion: reduceMotion)
            .resizable()
            .imageLoadingCover(
                ground: .clear,
                shorterSide: min(box.width, box.height),
                showsIndicator: false
            )
            .scaledToFit()
            .frame(width: box.width, height: box.height)
    }
}
