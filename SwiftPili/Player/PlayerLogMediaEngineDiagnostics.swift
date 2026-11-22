@MainActor
final class PlayerLogMediaEngineDiagnostics: MediaEngineDiagnostics {
    var isCapturing: Bool { PlayerLog.isCapturing }

    func log(_ message: @autoclosure () -> String) {
        PlayerLog.log(message())
    }

    func diagnostic(_ message: @autoclosure () -> String) {
        PlayerLog.diagnostic(message())
    }
}
