import SwiftUI

struct ArticleReaderHeader: View {
    let info: ArticleViewInfo?
    var availableWidth: CGFloat?
    let onAuthor: () -> Void

    @ViewBuilder
    var body: some View {
        if let banner = info?.bannerUrl, !banner.isEmpty {
            let bannerSize: CGSize? = if let width = availableWidth, width > 1 {
                CGSize(width: width.rounded(), height: (width / 2.5).rounded())
            } else {
                nil
            }
            Color.clear
                .aspectRatio(2.5, contentMode: .fit)
                .overlay {
                    CoverImage(urlString: banner, displaySize: bannerSize)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.control))
        }

        if let title = info?.title, !title.isEmpty {
            Text(title)
                .font(.title2.weight(.bold))
                .textSelection(.enabled)
        }

        HStack(spacing: 8) {
            if let author = info?.authorName {
                Button(action: onAuthor) {
                    Label(author, systemImage: "person.circle")
                        .font(.subheadline)
                        .foregroundStyle(.biliAccent)
                }
                .buttonStyle(.appControl)
            }
            Spacer()
            if let views = info?.stats?.view {
                Text("\(FormatUtils.viewCount(views)) reads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()
    }

}
