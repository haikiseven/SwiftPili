import Foundation
import Synchronization

struct PlayerEqualizerConfiguration: Codable, Equatable, Sendable {
    struct Preset: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let bandGains: [Float]
    }

    static let currentSchemaVersion = 1
    static let frequencies: [Float] = [31.25, 62.5, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let presets: [Preset] = [
        Preset(id: "flat", name: "Flat", bandGains: Array(repeating: 0, count: 10)),
        Preset(id: "bass", name: "Bass", bandGains: [4, 4, 3, 2, 0, 0, 0, 0, 0, 0]),
        Preset(id: "vocal", name: "Vocal", bandGains: [-2, -2, -1, 0, 2, 3, 3, 2, 0, -1]),
        Preset(id: "treble", name: "Treble", bandGains: [0, 0, 0, 0, 0, 0, 1, 2, 3, 4])
    ]
    static let defaults = PlayerEqualizerConfiguration()

    var schemaVersion: Int = currentSchemaVersion
    var enabled = false
    var presetID = "flat"
    var bandGains: [Float] = Array(repeating: 0, count: 10)
    var userAttenuation: Float = 0

    var normalized: Self {
        guard schemaVersion == Self.currentSchemaVersion,
              bandGains.count == Self.frequencies.count,
              bandGains.allSatisfy({ $0.isFinite && (-12...12).contains($0) }),
              userAttenuation.isFinite, (-12...0).contains(userAttenuation) else { return .defaults }
        var result = self
        if presetID != "custom", !Self.presets.contains(where: { $0.id == presetID && $0.bandGains == bandGains }) {
            result.presetID = "custom"
        }
        return result
    }

    var autoHeadroom: Float { max(0, bandGains.max() ?? 0) }
    var effectivePreamp: Float { userAttenuation - autoHeadroom }
    var isBypassed: Bool { !enabled || (bandGains.allSatisfy { $0 == 0 } && effectivePreamp == 0) }

    func selectingPreset(_ id: String) -> Self {
        guard let preset = Self.presets.first(where: { $0.id == id }) else { return self }
        var result = normalized
        result.enabled = true
        result.presetID = preset.id
        result.bandGains = preset.bandGains
        return result
    }
}

enum PlayerEqualizerStatus: Equatable, Sendable {
    case retainedNoGraph
    case pendingNativeAccess
    case configuredCurrentGraph
    case bypassed
    case unsupported(String)
    case failed(String)
}

final class AudioMaintenancePermit: Sendable {
    struct Ticket: Equatable, Sendable { fileprivate let generation: UInt64 }
    private let revoked = Atomic<Bool>(false)

    func ticket() -> Ticket { Ticket(generation: 1) }
    var isValid: Bool { permits(ticket()) }
    func permits(_ ticket: Ticket) -> Bool {
        ticket.generation == 1 && !revoked.load(ordering: .acquiring)
    }
    func revoke() { revoked.store(true, ordering: .releasing) }
}

enum PlayerEqualizerPreferences {
    static let defaultsKey = "player_equalizer_configuration_v1"

    static var equalizerConfiguration: PlayerEqualizerConfiguration {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let value = try? JSONDecoder().decode(PlayerEqualizerConfiguration.self, from: data) else {
                return .defaults
            }
            return value.normalized
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue.normalized) else { return }
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
