import Foundation

@MainActor
enum MediaVideoRendererFactory {
    static func makeDemandRenderer() -> any MediaVideoPresentation {
        #if targetEnvironment(simulator)
        return SimulatorVisibleVideoRenderer()
        #else
        return SampleBufferVideoRenderer()
        #endif
    }
}
