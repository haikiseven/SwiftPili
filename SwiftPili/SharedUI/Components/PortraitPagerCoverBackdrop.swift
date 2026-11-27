import SwiftUI

struct PortraitPagerCoverBackdrop: View {
    let coverSource: PortraitPagingCoverSource
    let title: String
    let ownerName: String
    let pageSize: CGSize
    let resolutionBudget: CGSize

    private var coverURL: String { coverSource.url(preferring: .mobileVariant) }

    var body: some View {
        let bottomSafe = AppWindowMetrics.safeAreaInsets.bottom
        let dockBottom = PlayerPortraitChromePolicy.bottomDockBottomPadding(bottomSafeArea: bottomSafe)
            + PlayerPortraitChromePolicy.bottomDockHeight
            + 36
        ZStack(alignment: .bottomLeading) {
            Color.black
            if !coverURL.isEmpty,
               resolutionBudget.width > 1,
               resolutionBudget.height > 1,
               pageSize.width > 1,
               pageSize.height > 1 {
                PortraitPagerCoverLayers(
                    coverURL: coverURL,
                    pageSize: pageSize,
                    resolutionBudget: resolutionBudget
                )
            }
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.32), location: 0.55),
                    .init(color: .black.opacity(0.58), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: PlayerPortraitChromePolicy.bottomGradientBaseHeight + max(0, bottomSafe - 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 8) {
                if !ownerName.isEmpty {
                    Text(verbatim: ownerName.hasPrefix("@") ? ownerName : "@\(ownerName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                }
                if !title.isEmpty {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 76)
            .padding(.bottom, dockBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PortraitPagerCoverLayers: View {
    let coverURL: String
    let pageSize: CGSize
    let resolutionBudget: CGSize

    var body: some View {
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
        .blur(radius: PagerBackdropDecoration.blurRadius, opaque: true)
        .scaleEffect(scale)
        .frame(width: pageSize.width, height: pageSize.height)
        .clipped()
        .accessibilityHidden(true)
    }

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
