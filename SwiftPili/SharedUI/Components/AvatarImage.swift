import Kingfisher
import SwiftUI

/// Avatar loader — Kingfisher counterpart of CoverImage. AsyncImage
/// left a permanently blank circle whenever the request failed or a
/// fast scroll cancelled it (no cache, no retry, failure phase renders
/// the placeholder forever). KFImage retries, caches, normalizes the
/// URL, and the placeholder carries a person glyph so even a final
/// failure reads as an avatar slot instead of an empty hole.
///
/// Sized like CoverImage: the CDN is asked for the circle's own pixel
/// box (`biliResized`, `_1c` crop — faces are square, so the crop is a
/// no-op that still licenses the smaller variant) and the decode is
/// capped to it. Uncapped, every comment row decoded the full-res face
/// original into the shared 120 MB memory cache — pure eviction
/// pressure for pixels a 36pt circle never shows.
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
        // The chain itself is `RequestedAvatarImage`. This pass still reads
        // scale and the environment; it does not build a `KFImage.Context`
        // unless the CDN URL, the downsample box, or the scale changed.
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

/// The Kingfisher request for one avatar.
///
/// `AvatarImage.body` runs again on every parent refresh — a comment row,
/// Bangumi's ~4 Hz clock — even when this face's URL and point size did not.
/// `KFImage`'s initializer builds a `Context`: a new `DispatchQueue`, then a
/// sync copy of `KingfisherParsedOptionsInfo` on every option setter.
/// Kingfisher's view identity is the hash of source + downsampling size, so
/// that work does not change the bitmap.
///
/// `.equatable()` compares the exact CDN URL, the exact downsample box
/// (`width: size, height: size`, not re-quantized) and the scale that box was
/// multiplied by for the CDN pixel size. SwiftUI then skips `body`, so the
/// context is not rebuilt. Fill, frame, and the circle clip stay on the parent.
/// Reduce Motion is part of the identity for the same reason as
/// `RequestedCoverImage`: it selects the fade, and an environment read inside
/// this view would be invisible to `==`.
private struct RequestedAvatarImage: View, Equatable {
    /// Original avatar URL. Diagnostics digest this, not the CDN variant.
    let sourceURL: String
    /// `sourceURL.biliResized(...)` — the exact string passed to `KFImage`.
    let requestedURL: String
    /// The same box `DownsamplingImageProcessor` is given. Not re-quantized.
    let downsampleSize: CGSize
    let scale: CGFloat
    /// Passed IN rather than read from `@Environment` here. This view is
    /// `.equatable()` so its body can be skipped; an environment read inside
    /// it would not participate in `==`.
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
        // Same CDN variant as the inline chain this replaced: point box ×
        // screen scale, crop flag unchanged, no extra rounding.
        requestedURL = sourceURL.biliResized(
            toPixel: CGSize(width: pointSize * scale, height: pointSize * scale),
            crop: true
        )
        downsampleSize = CGSize(width: pointSize, height: pointSize)
    }

    /// Identity of the request, not of the parent refresh.
    ///
    /// `sourceURL` and `site` are absent on purpose. Diagnostics close over
    /// them when `body` runs; comparing either would not change the bitmap,
    /// and the closure is re-created on every parent pass.
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
            // Avatars carried no instrumentation at all, which made a
            // comment-list scroll look cheaper than it is: every row has one.
            // Completion only — an avatar is not the scroll cell, so appear /
            // disappear liveness belongs to the row, not here.
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
            // No `.retry(...)` here: `CacheManager.apply()` already puts an
            // identically-parameterised `DelayRetryStrategy` in
            // `KingfisherManager.shared.defaultOptions`, which every
            // `KFImage.Context` seeds itself from — and every comment row in the
            // app builds one of these, so restating it cost an allocation and two
            // `propertyQueue.sync` round-trips per row per body to reach the value
            // it already had.
            // Was a hand-picked 0.15s while `CoverImage` used 0.2s for the same
            // event; both now come from `ImagePipelinePolicy`, and Reduce Motion
            // removes the transition rather than shortening it to zero.
            .imageFadePolicy(reduceMotion: reduceMotion)
            .resizable()
            // The old `.placeholder` was a `.quaternary` circle with a person
            // glyph, shown for BOTH "loading" and "gave up" — so an avatar
            // still in flight and one that will never arrive were the same
            // pixels forever. That glyph is now the FAILED state only
            // (`FailedCover` keeps the same `person.fill` idiom for a circular
            // slot), and loading is an opaque ground plus, above the size
            // gate, a spinner. `shorterSide` is what drives that gate:
            // a ~20pt indicator inside a 22pt comment avatar is noise, not an
            // indicator, so small circles stay ground-only.
            .imageLoadingCover(shape: .circle, shorterSide: downsampleSize.width)
    }
}
