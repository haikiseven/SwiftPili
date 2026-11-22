import Foundation

@MainActor
final class VLCRetainedLivenessObservation {
    enum Reason: String {
        case clockAdvanced = "clock advanced"
        case picturePresented = "picture presented"
        case deadline = "no delivery in window"
        case superseded
        case generationChanged = "generation changed"
        case load = "load()"
        case stop = "stop()"
    }

    typealias CancelDeadline = @MainActor () -> Void
    typealias ScheduleDeadline = @MainActor (
        TimeInterval, @escaping @MainActor () -> Void
    ) -> CancelDeadline

    private struct Probe {
        let id: UUID
        let generation: UInt64
        let baselineTick: TimeInterval
        let baselinePictures: UInt64
        let completion: @MainActor (Bool, Reason) -> Void
        var cancelDeadline: CancelDeadline?
    }

    private var probe: Probe?
    var isObserving: Bool { probe != nil }
    private let scheduleDeadline: ScheduleDeadline
    private static let tickEpsilon: TimeInterval = 0.05

    init(scheduleDeadline: @escaping ScheduleDeadline = VLCRetainedLivenessObservation.scheduleTask) {
        self.scheduleDeadline = scheduleDeadline
    }

    func begin(
        generation: UInt64,
        baselineTick: TimeInterval,
        baselinePictures: UInt64,
        timeout: TimeInterval,
        completion: @escaping @MainActor (Bool, Reason) -> Void
    ) {
        cancel(reason: .superseded)
        let id = UUID()
        probe = Probe(
            id: id, generation: generation, baselineTick: baselineTick,
            baselinePictures: baselinePictures, completion: completion
        )
        let cancelDeadline = scheduleDeadline(timeout) { [weak self] in
            self?.resolve(id: id, alive: false, reason: .deadline)
        }
        if probe?.id == id {
            probe?.cancelDeadline = cancelDeadline
        } else {
            cancelDeadline()
        }
    }

    func observe(generation: UInt64, tick: TimeInterval, pictures: UInt64?) {
        guard let probe else { return }
        guard probe.generation == generation else {
            resolve(id: probe.id, alive: false, reason: .generationChanged)
            return
        }
        if tick > probe.baselineTick + Self.tickEpsilon {
            resolve(id: probe.id, alive: true, reason: .clockAdvanced)
        } else if let pictures, pictures > probe.baselinePictures {
            resolve(id: probe.id, alive: true, reason: .picturePresented)
        }
    }

    func cancel(reason: Reason) {
        guard let probe else { return }
        resolve(id: probe.id, alive: false, reason: reason)
    }

    private func resolve(id: UUID, alive: Bool, reason: Reason) {
        guard let current = probe, current.id == id else { return }
        probe = nil
        current.cancelDeadline?()
        current.completion(alive, reason)
    }

    private static func scheduleTask(
        timeout: TimeInterval,
        delivery: @escaping @MainActor () -> Void
    ) -> CancelDeadline {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            delivery()
        }
        return { task.cancel() }
    }
}
