import Foundation

/// How the video is scaled inside the player surface.
enum VideoScaleMode: String, CaseIterable, Sendable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String { rawValue }
}
