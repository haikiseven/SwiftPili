import Foundation

/// Extracts attributed thread frames from MetricKit `MXCallStackTree.jsonRepresentation()`,
/// walking `subFrames` along the highest `sampledCount` branch from root to leaf.
enum HangCallStackParser {
    struct Frame: Equatable, Sendable {
        let binaryName: String
        let binaryUUID: String
        /// Offset into the binary's text segment (`atos -o <dSYM> --offset`).
        let offsetIntoBinaryTextSegment: Int
    }

    /// Outermost caller first, retaining the leaf-most `maxDepth` frames so deep SwiftUI
    /// stacks preserve the blocked leaf rather than run-loop boilerplate.
    static func attributedThreadFrames(fromJSON data: Data, maxDepth: Int = 40) -> [Frame] {
        guard maxDepth > 0,
              let tree = try? JSONDecoder().decode(RawTree.self, from: data),
              let stacks = tree.callStacks, !stacks.isEmpty
        else { return [] }
        let stack = stacks.first(where: { $0.threadAttributed == true }) ?? stacks[0]

        var frames: [Frame] = []
        var cursor = hottest(stack.callStackRootFrames)
        while let raw = cursor, frames.count < Self.walkCeiling {
            frames.append(Frame(
                binaryName: raw.binaryName ?? "<unknown>",
                binaryUUID: raw.binaryUUID ?? "",
                offsetIntoBinaryTextSegment: raw.offsetIntoBinaryTextSegment ?? 0
            ))
            cursor = hottest(raw.subFrames)
        }
        return Array(frames.suffix(maxDepth))
    }

    private static let walkCeiling = 1024

    private static func hottest(_ frames: [RawFrame]?) -> RawFrame? {
        guard let frames, !frames.isEmpty else { return nil }
        return frames.max { ($0.sampledCount ?? 0) < ($1.sampledCount ?? 0) }
    }

    private struct RawTree: Decodable {
        let callStacks: [RawStack]?
    }

    private struct RawStack: Decodable {
        let threadAttributed: Bool?
        let callStackRootFrames: [RawFrame]?
    }

    private struct RawFrame: Decodable {
        let binaryName: String?
        let binaryUUID: String?
        let offsetIntoBinaryTextSegment: Int?
        let sampledCount: Int?
        let subFrames: [RawFrame]?
    }
}
