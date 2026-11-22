import Foundation

enum VideoScaleMode: String, CaseIterable, Sendable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String { rawValue }
}
