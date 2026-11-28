import SwiftUI
import UIKit

struct RouteActivationPlaceholderView: View {
    let still: UIImage?
    let coverURL: String?
    let height: CGFloat
    var cornerRadius: CGFloat = 0

    var body: some View {
        Group {
            if let still {
                OutgoingRouteStillView(image: still, height: height)
            } else {
                Color.black
                    .overlay {
                        if let coverURL, !coverURL.isEmpty {
                            GeometryReader { proxy in
                                CoverImage(
                                    urlString: coverURL,
                                    displaySize: resolvedDisplaySize(for: proxy.size),
                                    contentMode: .fit,
                                    groundColor: .black,
                                    isDecorative: true
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @MainActor
    private func resolvedDisplaySize(for proxySize: CGSize) -> CGSize {
        let fallback = WindowMetricsFallback.currentSize
        let resolvedWidth = (proxySize.width.isFinite && proxySize.width > 1)
            ? proxySize.width
            : max(fallback.width, 2)
        let resolvedHeight: CGFloat = if proxySize.height.isFinite, proxySize.height > 1 {
            proxySize.height
        } else if height.isFinite, height > 1 {
            height
        } else {
            max(fallback.height, 2)
        }
        return CGSize(width: resolvedWidth, height: resolvedHeight)
    }
}
