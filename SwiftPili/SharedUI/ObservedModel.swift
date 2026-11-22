import SwiftUI

struct ObservedModel<Model: AnyObject, Content: View>: View {
    let model: Model
    let content: (Model) -> Content

    init(_ model: Model, @ViewBuilder content: @escaping (Model) -> Content) {
        self.model = model
        self.content = content
    }

    var body: some View { content(model) }
}
