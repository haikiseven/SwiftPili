import SwiftUI

struct ArticleBlockView: View {
    let block: ArticleBlock
    var availableWidth: CGFloat?
    let openImage: () -> Void

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title3.weight(.semibold))
                .padding(.top, 8)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .lineSpacing(6)
                .textSelection(.enabled)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.biliAccent.opacity(0.5))
                    .frame(width: 3)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        case .listItem(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
        case .caption(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .image(let url):
            Button(action: openImage) {
                ArticleImage(url: url, availableWidth: availableWidth)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.control))
            }
            .buttonStyle(.plain)
        }
    }
}
