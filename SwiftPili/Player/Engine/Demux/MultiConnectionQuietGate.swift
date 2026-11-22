import Foundation

enum MultiConnectionQuiet: Sendable, Equatable {
    case admitted
    case measurement
    case policy

    var isQuiet: Bool { self != .admitted }
}

final class MultiConnectionQuietGate: @unchecked Sendable {
    private let lock = NSLock()
    private var state: MultiConnectionQuiet
    private var parked = false

    init(quiet: Bool = false) { state = quiet ? .measurement : .admitted }

    var isParked: Bool { lock.withLock { parked } }

    var isQuiet: Bool { lock.withLock { state.isQuiet || parked } }

    var quietReason: MultiConnectionQuiet { lock.withLock { state } }

    func setQuiet(_ value: Bool) { setQuiet(value ? MultiConnectionQuiet.measurement : .admitted) }

    func setQuiet(_ value: MultiConnectionQuiet) { lock.withLock { state = value } }

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
    case refused(status: Int)
    case policyUnavailable(reason: String)

    static let refusalStatuses: Set<Int> = [403, 412, 429]

    static func refusal(status: Int, contentType: String?) -> Self? {
        if refusalStatuses.contains(status) { return .refused(status: status) }
        if (200..<300).contains(status), status != 206,
           contentType?.lowercased().contains("json") == true {
            return .refused(status: status)
        }
        return nil
    }

    static func policy(from error: any Error) -> Self? {
        guard let error = error as? URLError, let reason = error.networkUnavailableReason else { return nil }
        switch reason {
        case .expensive: return .policyUnavailable(reason: "expensive")
        case .constrained: return .policyUnavailable(reason: "constrained")
        case .cellular: return .policyUnavailable(reason: "cellular")
        default: return .policyUnavailable(reason: "other")
        }
    }

    static func isConnectionReset(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed].contains(error.code)
    }
}
