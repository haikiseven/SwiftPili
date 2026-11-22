import Observation
import QuartzCore
import SwiftUI

/// The one value that changes per touch sample, held where a write to it
/// cannot invalidate the detail view.
///
/// `PortraitPagingReducer` lives in `@State`. Every other offset write it makes
/// happens once per gesture — begin, settle, cancel, commit — and re-rendering
/// for those is correct and cheap. The drag samples are the exception: at
/// 60–120Hz a `@State` write re-evaluated `VideoDetailView` in full, which is
/// the player, the pager, the comment list and the composer, and THAT is what
/// the finger felt as twitching. Nothing here lowers the gesture's rate; the
/// value still updates on every sample. It just stopped taking the page with it.
@Observable
@MainActor
final class PortraitDragOffsetBox {
    var y: CGFloat = 0

    /// Per-gesture diagnostics. `@ObservationIgnored` is load-bearing, not
    /// tidiness: an observed write here would invalidate any view that read it
    /// and could reintroduce the very per-sample re-render this box exists to
    /// remove. Nothing reads these from a body — they are logged at gesture end.
    @ObservationIgnored var sampleCount = 0
    @ObservationIgnored var bodiesAtBegin: [String: Int] = [:]
    @ObservationIgnored var beganAt: CFTimeInterval = 0
}

/// Applies the live drag offset from inside its OWN view body.
///
/// That isolation is the entire fix. A `ViewModifier`'s `body(content:)` is a
/// separate node in SwiftUI's graph: reading `box.y` here registers the
/// observation against this modifier, and `content` arrives already built. So a
/// touch sample re-runs these two lines and re-positions a finished subtree,
/// instead of re-evaluating `VideoDetailView` and everything it contains.
///
/// Reading the box in the parent — `.offset(y: box.y)` written at the call
/// site — would put the dependency back on the parent and restore the bug
/// exactly, which is why the offset is not applied there.
struct PortraitDragOffset: ViewModifier {
    let box: PortraitDragOffsetBox
    /// Fixed displacement this subtree sits at before the drag is added — 0 for
    /// the page itself, ∓containerHeight for the neighbour previews. It is a
    /// parameter rather than a second `.offset` at the call site because
    /// reading `box.y` there would put the per-sample dependency back on the
    /// parent, which is the bug.
    var base: CGFloat = 0

    func body(content: Content) -> some View {
        content.offset(y: base + box.y)
    }
}
