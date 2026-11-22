@MainActor
protocol MediaEngineDiagnostics: AnyObject {
    var isCapturing: Bool { get }
    func log(_ message: @autoclosure () -> String)
    func diagnostic(_ message: @autoclosure () -> String)
}
