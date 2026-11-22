import Foundation

/// Package-only marker used by the dependency-graph tests and boundary gate.
/// No App-facing contract belongs in this target during the skeleton phase.
package enum PiliPlayerCoreBoundary {
    package static let targetName = "PiliPlayerCore"
}
