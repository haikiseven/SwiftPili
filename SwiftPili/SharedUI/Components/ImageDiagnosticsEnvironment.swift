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
    func imageDiagnosticsScreen(_ name: String) -> some View {
        environment(\.imageDiagnosticsScreen, name)
    }

    func imageDiagnosticsScrollTracking() -> some View {
        onScrollPhaseChange { _, newPhase in
            guard ImageDiagnostics.isEnabled else { return }
            ImageDiagnostics.isScrolling = newPhase != .idle
        }
    }
}
