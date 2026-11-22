import Foundation

/// Coalesces native-output invalidations. Availability is still owned by the
/// renderer; stored state here only suppresses redundant notification work.
@MainActor
final class AudioOutputStateNotifier {
    private let sample: @MainActor () -> MediaAudioOutputAvailability
    private var handler: (@MainActor @Sendable () -> Void)?
    private var registration: UInt64 = 0
    private var revision: UInt64 = 0
    private var deliveredRevision: UInt64 = 0
    private var knownState: MediaAudioOutputAvailability?
    private var scheduledRegistration: UInt64?

    init(sample: @escaping @MainActor () -> MediaAudioOutputAvailability) {
        self.sample = sample
    }

    func setHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
        registration &+= 1
        self.handler = handler
        scheduledRegistration = nil
        revision &+= 1
        scheduleDelivery()
    }

    func note(_ state: MediaAudioOutputAvailability) {
        guard knownState != state else { return }
        knownState = state
        revision &+= 1
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        guard handler != nil, scheduledRegistration == nil else { return }
        let currentRegistration = registration
        scheduledRegistration = currentRegistration
        Task { @MainActor [weak self] in
            self?.deliver(registration: currentRegistration)
        }
    }

    private func deliver(registration expected: UInt64) {
        guard registration == expected, scheduledRegistration == expected else { return }
        // Sampling may discover native loss. Keep the delivery marked scheduled
        // so it can update the revision without recursing into the consumer.
        note(sample())
        if deliveredRevision != revision {
            deliveredRevision = revision
            handler?()
        }
        guard registration == expected else { return }
        scheduledRegistration = nil
        if deliveredRevision != revision { scheduleDelivery() }
    }
}
