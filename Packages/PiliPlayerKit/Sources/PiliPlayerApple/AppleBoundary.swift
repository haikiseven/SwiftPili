import Foundation
import PiliPlayerCore
import PiliPlayerMedia

/// Package-only marker proving that Apple depends on Core and Media.
package enum PiliPlayerAppleBoundary {
    package static let targetName = "\(PiliPlayerCoreBoundary.targetName)->\(PiliPlayerMediaBoundary.targetName)->PiliPlayerApple"
}
