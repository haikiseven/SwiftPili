import SwiftUI

// Moved out of `VideoDetailView` so the bangumi page uses the same boundary —
// most importantly around content hosted by UIKit (the comment Zoom
// destinations), which only updates from observation registered inside it.

/// An observation boundary with no layout of its own.
///
/// `content` runs in THIS view's body, so every `@Observable` property it reads
/// is registered against this node and not against the view that built it. The
/// detail root used to build `detailsPage`, `commentsPage` and `wideContent`
/// inline, which tied it to everything those pages show — related videos, tags,
/// the online count, the comment source, follow/like/coin state — and every one
/// of those arriving re-evaluated the whole root (the player area, both pages,
/// the composer and every sheet) for a change only one page displays. The
/// closure is not `Equatable`, so the boundary still re-runs whenever the root
/// does; it only stops the reverse: a model write reaching the root.
///
/// Returning `content(model)` unchanged adds no stack, frame or modifier, so
/// layout, identity of the content and accessibility are the same as inlining.
struct ObservedModel<Model: AnyObject, Content: View>: View {
    let model: Model
    let content: (Model) -> Content

    init(_ model: Model, @ViewBuilder content: @escaping (Model) -> Content) {
        self.model = model
        self.content = content
    }

    var body: some View { content(model) }
}
