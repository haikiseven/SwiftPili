import PiliPlayerApple
import PiliPlayerCore
import PiliPlayerMedia

/// Package-only marker proving Engine reaches the three inward targets.
package enum PiliPlayerEngineBoundary {
    package static let targetName = "\(PiliPlayerCoreBoundary.targetName)->\(PiliPlayerMediaBoundary.targetName)->\(PiliPlayerAppleBoundary.targetName)->PiliPlayerEngine"
}
