import Foundation

struct AudioFeederAdmission: Sendable, Equatable {
    enum StandDown: Sendable, Equatable {
        case quiesced
        case mustJoin
    }

    struct Pass: Sendable, Equatable {
        let slot: Int
        let contentGeneration: UInt64
        let targetFrames: Int
    }

    enum WriteRefusal: Sendable, Equatable {
        case staleContentGeneration
        case standDownInProgress
        case retired
        case slotChanged
    }

    private(set) var isAdmitted = false
    private(set) var isRetired = false
    private(set) var isPassInFlight = false
    private(set) var admittedSlot = 0
    private(set) var targetFrames = 0
    private(set) var contentGeneration: UInt64 = 0
    private(set) var completedPassCount = 0

    // MARK: - MainActor side

    @discardableResult
    mutating func admit(slot: Int, targetFrames: Int) -> Bool {
        guard !isRetired, slot == 0 || slot == 1 else { return false }
        isAdmitted = true
        admittedSlot = slot
        self.targetFrames = max(0, targetFrames)
        return true
    }

    mutating func standDown() -> StandDown {
        isAdmitted = false
        return isPassInFlight ? .mustJoin : .quiesced
    }

    mutating func setTargetFrames(_ frames: Int) {
        targetFrames = max(0, frames)
    }

    mutating func invalidateContent() {
        contentGeneration &+= 1
    }

    mutating func retire() {
        isAdmitted = false
        isRetired = true
    }

    // MARK: - Feeder side

    mutating func beginPass() -> Pass? {
        guard isAdmitted, !isRetired, !isPassInFlight, targetFrames > 0 else { return nil }
        isPassInFlight = true
        return Pass(
            slot: admittedSlot,
            contentGeneration: contentGeneration,
            targetFrames: targetFrames
        )
    }

    func writeVerdict(for pass: Pass) -> WriteRefusal? {
        if isRetired { return .retired }
        if pass.contentGeneration != contentGeneration { return .staleContentGeneration }
        if !isAdmitted { return .standDownInProgress }
        if pass.slot != admittedSlot { return .slotChanged }
        return nil
    }

    mutating func endPass() {
        guard isPassInFlight else { return }
        isPassInFlight = false
        completedPassCount &+= 1
    }
}
