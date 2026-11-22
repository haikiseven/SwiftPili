import SwiftUI

/// Neighbour-page backdrop for the portrait pager: fitted artwork over a small blurred decorative fill.
struct PortraitPagerCoverBackdrop: View {
    let coverSource: PortraitPagingCoverSource
    let title: String
    let ownerName: String
    let pageSize: CGSize
    /// Quantized page box (`PortraitPagingReducer.coverResolutionBudget`) so chrome height changes do not fragment cover cache keys.
    let resolutionBudget: CGSize

    /// Prefers the narrower 4:3 mobile variant when present so `.fit` covers more vertical height on a portrait page, independent of card `CoverAspect` settings.
    private var coverURL: String { coverSource.url(preferring: .mobileVariant) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if !coverURL.isEmpty,
               resolutionBudget.width > 1,
               resolutionBudget.height > 1,
               pageSize.width > 1,
               pageSize.height > 1 {
                coverLayers
            }
            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !ownerName.isEmpty {
                    Text(ownerName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var coverLayers: some View {
        ZStack {
            decorativeFill
            artwork
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var decorativeFill: some View {
        let box = PagerBackdropDecoration.box
        let scale = PagerBackdropDecoration.scale(from: box, toCover: pageSize)
        return CoverImage(
            urlString: coverURL,
            displaySize: box,
            contentMode: .fill,
            requestsServerCrop: false,
            requestSize: box,
            isDecorative: true
        )
        // Blur at the small layout box before scaling, framing, and clipping to page size.
        .blur(radius: PagerBackdropDecoration.blurRadius, opaque: true)
        .scaleEffect(scale)
        .frame(width: pageSize.width, height: pageSize.height)
        .clipped()
        .accessibilityHidden(true)
    }

    /// Always fits the complete cover over the blurred fill, independent of card `CoverDisplayMode`.
    private var artwork: some View {
        CoverImage(
            urlString: coverURL,
            displaySize: pageSize,
            contentMode: .fit,
            requestsServerCrop: false,
            requestSize: resolutionBudget,
            groundColor: .clear,
            isDecorative: true
        )
    }
}

/// Geometry for the low-cost decorative cover layer.
enum PagerBackdropDecoration {
    static let width: CGFloat = 64
    static let box = CGSize(width: width, height: 128)
    static let blurRadius: CGFloat = 2

    static func scale(from box: CGSize, toCover page: CGSize) -> CGFloat {
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0,
              page.width.isFinite, page.height.isFinite, page.width > 0, page.height > 0
        else { return 1 }
        return max(page.width / box.width, page.height / box.height)
    }
}
