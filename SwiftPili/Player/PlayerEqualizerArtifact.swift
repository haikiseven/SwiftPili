import Foundation

/// Compile-time equalizer support and gain calibration for the linked local libVLC slice.
nonisolated enum PlayerEqualizerArtifact {
    static let nativePreampCompensation: Float = 20 * log10(4)

    static var isLinkedSliceSupported: Bool {
        #if targetEnvironment(simulator) && (arch(arm64) || arch(x86_64))
        true
        #elseif os(iOS) && arch(arm64)
        true
        #else
        false
        #endif
    }
}
