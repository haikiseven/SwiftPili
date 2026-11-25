import Foundation
import os

enum AudioHardwareStartMode: String, Sendable, Equatable {
    case async
    case sync

    static let environmentKey = "PATHA_AUDIO_ASYNC_START"

    static func resolve(environment: [String: String]) -> AudioHardwareStartMode {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return .async }
        return environment[environmentKey] == "0" ? .sync : .async
    }
}

enum AudioDrainTickAction: Sendable, Equatable {
    case holdClock
    case simulateConsumer
    case reportHardwareDrain
}

struct AudioHardwareStartAdmission: Sendable, Equatable {
    struct Token: Hashable, Sendable {
        let value: UInt64
    }

    enum Completion: Sendable, Equatable {
        case accept
        case softFail
        case unavailable
        case discard(stopStaleEngine: Bool)
    }

    private(set) var pendingToken: Token?
    private(set) var outstandingOperations = 0
    private var lastIssuedValue: UInt64 = 0
    private var nativeOperationSerial: UInt64 = 0
    private var nativeOperationIDs: Set<UInt64> = []

    var isPending: Bool { pendingToken != nil }

    var mayReuseEngine: Bool { outstandingOperations == 0 }

    var maySampleNativeStateForCompletingStart: Bool { outstandingOperations == 1 }

    mutating func beginStart() -> Token {
        lastIssuedValue &+= 1
        if lastIssuedValue == 0 { lastIssuedValue = 1 }
        let token = Token(value: lastIssuedValue)
        pendingToken = token
        outstandingOperations += 1
        return token
    }

    mutating func invalidate() {
        pendingToken = nil
    }

    mutating func noteOperationSubmitted() {
        outstandingOperations += 1
    }

    mutating func beginNativeOperation() -> UInt64 {
        nativeOperationSerial &+= 1
        nativeOperationIDs.insert(nativeOperationSerial)
        noteOperationSubmitted()
        return nativeOperationSerial
    }

    mutating func completeNativeOperation(_ id: UInt64) {
        guard nativeOperationIDs.remove(id) != nil else { return }
        acknowledgeOperation()
    }

    mutating func acknowledgeOperation() {
        outstandingOperations = max(0, outstandingOperations - 1)
    }

    mutating func complete(
        token: Token,
        succeeded: Bool,
        rendererRunning: Bool,
        engineIsCurrent: Bool,
        engineReportsRunning: Bool,
        configurationCurrent: Bool = true
    ) -> Completion {
        acknowledgeOperation()
        guard pendingToken == token else {
            return .discard(stopStaleEngine: engineReportsRunning)
        }
        pendingToken = nil
        guard rendererRunning, engineIsCurrent else {
            return .discard(stopStaleEngine: engineReportsRunning)
        }
        guard configurationCurrent else { return .unavailable }
        guard succeeded else { return .softFail }
        return engineReportsRunning ? .accept : .unavailable
    }

    func renderRate(requested: Float, nativeOutputUnavailable: Bool = false) -> Float {
        outstandingOperations > 0 || nativeOutputUnavailable ? 0 : requested
    }

    static func hasRealtimeConsumer(
        isRunning: Bool,
        engineStarted: Bool,
        fillOnlyMode: Bool,
        startPending: Bool,
        nativeOutputUnavailable: Bool = false,
        queueOutstanding: Bool = false
    ) -> Bool {
        isRunning && engineStarted && !fillOnlyMode && !startPending
            && !nativeOutputUnavailable && !queueOutstanding
    }

    static func drainTickAction(
        startPending: Bool,
        engineStarted: Bool,
        fillOnlyMode: Bool,
        nativeOutputUnavailable: Bool = false,
        queueOutstanding: Bool = false
    ) -> AudioDrainTickAction {
        if startPending || nativeOutputUnavailable || queueOutstanding { return .holdClock }
        if !engineStarted || fillOnlyMode { return .simulateConsumer }
        return .reportHardwareDrain
    }
}

@MainActor
final class AudioNativeOutputBinding {
    final class Revision: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: UInt64(0))
        var current: UInt64 { value.withLock { $0 } }
        func invalidate() -> UInt64 {
            value.withLock { revision in
                revision &+= 1
                return revision
            }
        }
    }

    struct Stamp: Sendable {
        let binding: UInt64
        let revision: UInt64
    }

    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private var binding: UInt64 = 0
    private var revision: Revision?
    private var preparedStamp: Stamp?
    private var nativeIsRunning: (@MainActor () -> Bool)?
    private var onInvalidation: (@MainActor () -> Void)?
    var reportsRunning: Bool {
        nativeIsRunning?() ?? false
    }
    var hasUnresolvedConfiguration: Bool {
        (revision?.current ?? 0) != (preparedStamp?.revision ?? 0)
    }
    var stamp: Stamp { Stamp(binding: binding, revision: revision?.current ?? 0) }

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func bind(
        object: AnyObject,
        notification: Notification.Name,
        nativeIsRunning: @escaping @MainActor () -> Bool,
        onInvalidation: @escaping @MainActor () -> Void
    ) {
        retire()
        let currentBinding = binding
        let revision = Revision()
        self.revision = revision
        self.nativeIsRunning = nativeIsRunning
        self.onInvalidation = onInvalidation
        observer = notificationCenter.addObserver(forName: notification, object: object, queue: nil) { [weak self] _ in
            let observedRevision = revision.invalidate()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.deliver(binding: currentBinding, revision: observedRevision)
                }
            }
        }
    }

    func markPrepared(_ validated: Stamp) -> Bool {
        guard isCurrent(validated) else { return false }
        preparedStamp = validated
        return true
    }

    func isCurrent(_ stamp: Stamp) -> Bool {
        stamp.binding == binding && stamp.revision == revision?.current
    }

    private func deliver(binding: UInt64, revision: UInt64) {
        guard self.binding == binding, self.revision?.current == revision,
              preparedStamp?.revision != revision else { return }
        onInvalidation?()
    }

    func retire() {
        if let observer { notificationCenter.removeObserver(observer) }
        observer = nil
        binding &+= 1
        revision = nil
        preparedStamp = nil
        nativeIsRunning = nil
        onInvalidation = nil
    }

    isolated deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }
}
