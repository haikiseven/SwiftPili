import Foundation

struct LiveQualityControl {
    struct Option: Identifiable, Sendable {
        let qn: Int
        let label: String
        var id: Int { qn }
    }

    let options: [Option]
    let current: Int
    let select: @MainActor (Int) -> Void

    var currentLabel: String? {
        options.first { $0.qn == current }?.label
    }
}
