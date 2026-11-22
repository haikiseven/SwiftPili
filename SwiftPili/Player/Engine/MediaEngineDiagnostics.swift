/// Synchronous text diagnostics supplied by the App for one engine session.
/// Capture is queried at each original call site; messages remain lazy.
@MainActor
protocol MediaEngineDiagnostics: AnyObject {
    var isCapturing: Bool { get }
    func log(_ message: @autoclosure () -> String)
    func diagnostic(_ message: @autoclosure () -> String)
}
