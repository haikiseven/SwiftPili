import Foundation

/// Why the App holds speculative helper requests. The two reasons differ in
/// what happens to pieces already on the wire.
enum MultiConnectionQuiet: Sendable, Equatable {
    /// Helpers are admitted.
    case admitted
    /// A Smart CDN sweep / per-video probe is measuring: no NEW request may
    /// start; pieces already in flight finish (they are allowed traffic).
    case measurement
    /// The setting or the current path forbids helper traffic (feature off,
    /// cellular not opted in, constrained, expensive under a Wi-Fi open):
    /// in-flight pieces are cancelled as well, like a seek.
    case policy

    var isQuiet: Bool { self != .admitted }
}

/// The synchronous App probe boundary and the final URLSession resume share this
/// gate. Scheduling before a probe cannot launch a transfer after the quiet edge.
final class MultiConnectionQuietGate: @unchecked Sendable {
    private let lock = NSLock()
    private var state: MultiConnectionQuiet
    private var parked = false

    init(quiet: Bool = false) { state = quiet ? .measurement : .admitted }

    var isParked: Bool { lock.withLock { parked } }

    var isQuiet: Bool { lock.withLock { state.isQuiet || parked } }

    /// The App's current reason; `.policy` also retires in-flight helper pieces.
    var quietReason: MultiConnectionQuiet { lock.withLock { state } }

    /// Measurement-window form: `true` is `.measurement`.
    func setQuiet(_ value: Bool) { setQuiet(value ? MultiConnectionQuiet.measurement : .admitted) }

    func setQuiet(_ value: MultiConnectionQuiet) { lock.withLock { state = value } }

    /// Session lifecycle authority is independent of measurement windows.
    /// Only an accepted explicit play/open may restore request admission.
    func setParked(_ value: Bool) { lock.withLock { parked = value } }

    @discardableResult
    func withNotQuiet(_ operation: () -> Void) -> Bool {
        lock.withLock {
            guard !state.isQuiet, !parked else { return false }
            operation()
            return true
        }
    }
}

enum MultiConnectionTransportError: Error, Equatable {
    case quiet
    /// The refusal class (design §3.6): 403/412/429, or a JSON body where a
    /// 206 range was requested (Bilibili risk control). Hard-rests the ladder.
    case refused(status: Int)
    /// The session's network policy forbade the interface (expensive /
    /// constrained). A policy outcome: neither a refusal nor a host failure.
    case policyUnavailable(reason: String)

    static let refusalStatuses: Set<Int> = [403, 412, 429]

    /// Header-time refusal classification; `nil` leaves ordinary range validation in charge.
    static func refusal(status: Int, contentType: String?) -> Self? {
        if refusalStatuses.contains(status) { return .refused(status: status) }
        if (200..<300).contains(status), status != 206,
           contentType?.lowercased().contains("json") == true {
            return .refused(status: status)
        }
        return nil
    }

    /// URLSession reports a forbidden interface through `networkUnavailableReason`.
    static func policy(from error: any Error) -> Self? {
        guard let error = error as? URLError, let reason = error.networkUnavailableReason else { return nil }
        switch reason {
        case .expensive: return .policyUnavailable(reason: "expensive")
        case .constrained: return .policyUnavailable(reason: "constrained")
        case .cellular: return .policyUnavailable(reason: "cellular")
        default: return .policyUnavailable(reason: "other")
        }
    }

    /// Connection-level failures that count toward a reset storm.
    static func isConnectionReset(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed].contains(error.code)
    }
}
