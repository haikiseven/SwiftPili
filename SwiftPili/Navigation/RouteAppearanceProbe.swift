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
                            CoverImage(
                                urlString: coverURL,
                                contentMode: .fit,
                                groundColor: .black,
                                isDecorative: true
                            )
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
}
