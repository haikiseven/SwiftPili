import SwiftUI

/// A horizontal shelf of large video cards ("up next").
///
/// Cards are `VideoNavigationButton`s, so a tap keeps the native push zoom
/// from the card into the next detail page.
struct UpNextShelf: View {
    let title: LocalizedStringKey
    let videos: [VideoCard]
    let cardWidth: CGFloat
    let leadingInset: CGFloat
    let target: (VideoCard) -> VideoRouteTarget
    /// VOD bounds its shelf to the content column; other callers keep overflow.
    var clipsContent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionHeader(title)
                .padding(.horizontal, leadingInset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(videos) { video in
                        VideoNavigationButton(target: target(video)) {
                            GridVideoCardView(
                                title: video.title,
                                sources: VideoCoverSources(
                                    widescreen: video.pic,
                                    fourByThree: video.mobileCoverURL
                                ),
                                duration: video.duration,
                                ownerName: video.owner.name,
                                viewCount: video.stat.view,
                                explicitColumnWidth: cardWidth
                            )
                            .equatable()
                        }
                        .frame(width: cardWidth)
                    }
                }
                .rowCardColumnWidth(cardWidth)
                .padding(.horizontal, leadingInset)
            }
            .scrollClipDisabled(!clipsContent)
        }
    }
}
