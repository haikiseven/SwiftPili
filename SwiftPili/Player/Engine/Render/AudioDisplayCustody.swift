import Foundation

struct AudioSupplyPull: Sendable {
    let frames: Int
}

struct AudioRendererPull: Sendable {
    let frames: Int
    let contentSeconds: TimeInterval
}
