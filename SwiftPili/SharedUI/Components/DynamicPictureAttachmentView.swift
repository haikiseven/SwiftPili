import SwiftUI

struct DynamicPictureAttachmentView: View {
    let attachment: DynamicRichContent.Attachment
    let sourceID: String?
    var onImageTap: ((ImagePreviewItem) -> Void)?

    @State private var retry: UInt64 = 0
    @State private var activeRequest: Request?
    @State private var receipt: Receipt?

    private struct Request: Equatable {
        let sourceID: String?
        let nodeID: Int
        let node: DynamicRichContent.Node
        let retry: UInt64
    }

    private struct Receipt {
        let request: Request
        let pictures: [DynamicRichContent.Picture]
        let error: String?
    }

    private var previewSourceID: String? {
        guard let sourceID, !sourceID.isEmpty else { return nil }
        return "\(sourceID):picture:\(attachment.id):\(attachment.node.rid ?? ""):\(retry)"
    }

    var body: some View {
        let request = Request(sourceID: sourceID, nodeID: attachment.id, node: attachment.node, retry: retry)
        let supplied = media(from: attachment.node.pics ?? [])
        let current = receipt.flatMap { $0.request == request ? $0 : nil }
        let pictures = supplied.isEmpty ? media(from: current?.pictures ?? []) : supplied
        Group {
            if !pictures.isEmpty {
                MediaGridView(
                    media: pictures,
                    sourceID: previewSourceID
                ) { item in
                    onImageTap?(item)
                }
            } else if let current {
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.error ?? String(localized: "No images"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let rid = request.node.rid,
                       !rid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Retry") {
                            guard receipt?.request == request, activeRequest == request else { return }
                            retry &+= 1
                        }
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .task(id: request) { await resolve(request, supplied: supplied) }
    }

    private func media(from pictures: [DynamicRichContent.Picture]) -> [MediaGridView.Media] {
        pictures.compactMap { picture in
            guard let url = DynamicRichContent.imageURL(picture.source) else { return nil }
            let size: CGSize?
            if let width = picture.width, let height = picture.height, width > 0, height > 0 {
                size = CGSize(width: width, height: height)
            } else {
                size = nil
            }
            return MediaGridView.Media(url: url, pixelSize: size)
        }
    }

    private func resolve(_ request: Request, supplied: [MediaGridView.Media]) async {
        guard !Task.isCancelled else { return }
        activeRequest = request
        guard supplied.isEmpty else { return }
        if receipt?.request == request { return }
        guard let rid = request.node.rid,
              !rid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            receipt = Receipt(request: request, pictures: [], error: nil)
            return
        }
        do {
            let pictures = try await DynamicAPI.getPictures(attachmentID: rid)
            guard !Task.isCancelled, activeRequest == request else { return }
            receipt = Receipt(request: request, pictures: pictures, error: nil)
        } catch {
            guard !Task.isCancelled, activeRequest == request, !error.isCancellation else { return }
            receipt = Receipt(request: request, pictures: [], error: error.localizedDescription)
        }
    }
}
