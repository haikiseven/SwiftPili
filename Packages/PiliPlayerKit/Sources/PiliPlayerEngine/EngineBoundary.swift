import PiliPlayerApple
import PiliPlayerCore
import PiliPlayerMedia

package enum PiliPlayerEngineBoundary {
    package static let targetName = "\(PiliPlayerCoreBoundary.targetName)->\(PiliPlayerMediaBoundary.targetName)->\(PiliPlayerAppleBoundary.targetName)->PiliPlayerEngine"
}
