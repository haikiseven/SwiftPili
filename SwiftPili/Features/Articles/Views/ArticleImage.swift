import Kingfisher
import SwiftUI

/// Last-resort renderer when the page layout defeats the native parser —
/// bilibili chrome stripped via injected CSS.
/// An inline article image in a fixed, reserved box.
///
/// Article payloads carry only a URL — no intrinsic dimensions — so the box
/// cannot be derived from the image. Reserving a constant aspect for BOTH states
/// is therefore the only way to satisfy "placeholder and loaded image use
/// exactly the same geometry": there is nothing else to size the placeholder
/// from. The image fits inside the reserved box against the same neutral
/// token, so a cover of any aspect is shown complete and nothing is cropped —
/// and nothing moves when it lands. Tapping opens the full-screen previewer,
/// which is where a tall screenshot is meant to be read.
struct ArticleImage: View {
    let url: URL
    var availableWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// Reserved aspect. Wider than tall because most article images are
    /// screenshots or banners in that neighbourhood, and a box the reader
    /// scrolls past should not be a full screen tall for every image.
    private static let reservedAspect: CGFloat = 4 / 3

    var body: some View {
        // A single gray rectangle over the WHOLE reserved area, under both
        // states — the placeholder is this background, not a shape inside
        // KFImage, so it cannot have a different size from the image.
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
            // Same conventions as CoverImage: cap the decode to
            // the box, off the main thread.
            .setProcessor(DownsamplingImageProcessor(size: box))
            .scaleFactor(scale)
            .cancelOnDisappear(true)
            // `.backgroundDecode` and the retry strategy come
            // from `CacheManager.apply()`'s app-wide defaults,
            // which every `KFImage.Context` seeds itself from;
            // restating them here was two `propertyQueue.sync`
            // round-trips and a `DelayRetryStrategy` allocation
            // per body to reach the value already in hand.
            .imageFadePolicy(reduceMotion: reduceMotion)
            .resizable()
            // The reserved background above stays the ground
            // and the letterbox, hence `ground: .clear` — a
            // second fill would stack alpha on it and darken
            // the image rectangle inside its own reservation.
            // What that background could NOT do is say whether
            // the load is still in flight or terminally failed;
            // that is all the cover adds here.
            .imageLoadingCover(
                ground: .clear,
                shorterSide: min(box.width, box.height),
                showsIndicator: false
            )
            .scaledToFit()
            .frame(width: box.width, height: box.height)
    }
}
