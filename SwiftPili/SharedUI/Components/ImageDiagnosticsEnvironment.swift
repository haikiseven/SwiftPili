import SwiftUI

private struct ImageDiagnosticsScreenKey: EnvironmentKey {
    static let defaultValue = "-"
}

extension EnvironmentValues {
    var imageDiagnosticsScreen: String {
        get { self[ImageDiagnosticsScreenKey.self] }
        set { self[ImageDiagnosticsScreenKey.self] = newValue }
    }
}

extension View {
    @inline(__always)
    func imageDiagnosticsScreen(_ name: String) -> some View {
        self
    }

    @inline(__always)
    func imageDiagnosticsScrollTracking() -> some View {
        self
    }
}
