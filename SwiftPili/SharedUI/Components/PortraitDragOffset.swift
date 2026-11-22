import Observation
import QuartzCore
import SwiftUI

@Observable
@MainActor
final class PortraitDragOffsetBox {
    var y: CGFloat = 0

    @ObservationIgnored var sampleCount = 0
    @ObservationIgnored var bodiesAtBegin: [String: Int] = [:]
    @ObservationIgnored var beganAt: CFTimeInterval = 0
}

struct PortraitDragOffset: ViewModifier {
    let box: PortraitDragOffsetBox
    var base: CGFloat = 0

    func body(content: Content) -> some View {
        content.offset(y: base + box.y)
    }
}
