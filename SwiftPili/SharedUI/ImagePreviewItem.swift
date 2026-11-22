import Foundation

/// Created once by the image action and forwarded unchanged to its modal owner.
struct ImagePreviewItem: Identifiable, Equatable {
    let id: UUID
    let urls: [URL]
    let index: Int
    let origin: ImagePreviewOrigin?

    init(urls: [URL], index: Int, origin: ImagePreviewOrigin? = nil) {
        id = UUID()
        self.urls = urls
        self.index = index
        self.origin = origin
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
