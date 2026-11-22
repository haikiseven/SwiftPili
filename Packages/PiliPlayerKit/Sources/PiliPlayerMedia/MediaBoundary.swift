import Foundation
import PiliPlayerCore

/// Package-only marker proving that Media depends inward on Core.
package enum PiliPlayerMediaBoundary {
    package static let targetName = "\(PiliPlayerCoreBoundary.targetName)->PiliPlayerMedia"
}
