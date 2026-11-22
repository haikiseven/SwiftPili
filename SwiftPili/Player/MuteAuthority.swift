import Foundation

/// Why the transport is silent — and the only state that decides it.
///
/// Two independent subsystems mute, for unrelated reasons and on different
/// schedules: SponsorBlock silences a `.mute` segment under the playhead
/// (state-driven, re-asserted every tick), and a seek silences the run-up audio
/// libVLC keeps playing while it travels to the target (edge-driven, armed and
/// restored). Both used to write `PlayerBackend.isMuted` directly, and the seek
/// half restored it by remembering the value it found — a save/restore that is
/// only correct while nothing else owns the flag.
///
/// Three failures came out of that, all the same shape:
///
///   * Backends are cached for the life of the PROCESS (`backendInstances`) and
///     `isMuted` is a pure passthrough to libVLC's player, which neither
///     `load()` nor `stop()` resets. Leaving a video from inside a mute segment
///     cleared SponsorBlock's tracking UUID and left the audio muted, so the
///     NEXT video played silent with nothing anywhere recording why — and the
///     user's only remedy was an app restart (backlog CB-18).
///   * A stop mid-seek never restored the seek's own mute at all: the restore
///     lived on the arrival tick, on `pause()`, and on the load path, and an
///     owner exit is none of those.
///   * A seek that began inside a mute segment captured `true` and restored
///     `true` after the segment had gone behind the playhead.
///
/// A reason set fixes all three by construction. The flag is DERIVED, never
/// remembered, so no writer can restore a value another writer owns, and a
/// teardown that releases the reasons releases the audio with them.
///
/// Deliberately a value with no reference to the backend: the ViewModel owns
/// the one write, which is what makes "who muted this?" answerable at all.
struct MuteAuthority: Equatable {
    /// One case per subsystem that has a reason to silence the transport.
    ///
    /// Not a pair of `Bool`s: adding a third reason must not mean auditing the
    /// other two's restore paths, which is exactly how the second failure above
    /// stayed invisible.
    enum Reason: String, CaseIterable, Sendable {
        /// A SponsorBlock `.mute` segment is under the playhead.
        case sponsorSegment
        /// A seek is travelling, and the audio still coming out is the run-up
        /// the user did not ask for.
        case seekTravel
    }

    private(set) var reasons: Set<Reason> = []

    /// What the backend must carry. Derived, so there is no second copy to
    /// drift from this one.
    var isMuted: Bool { !reasons.isEmpty }

    func holds(_ reason: Reason) -> Bool { reasons.contains(reason) }

    /// Adds or removes one reason, answering with the flag to write when the
    /// derived state CHANGED and `nil` when it did not.
    ///
    /// The optional is the point. Both callers sit on per-tick paths, and the
    /// old code guarded its writes with an `if` per subsystem for the same
    /// reason: a property set that crosses into libVLC on every tick is cost
    /// for nothing, and a log line per tick buries the edges that matter.
    mutating func set(_ reason: Reason, active: Bool) -> Bool? {
        let before = isMuted
        if active {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        return isMuted == before ? nil : isMuted
    }

    /// A teardown holds no reasons. Same answer shape as `set`, so the caller
    /// that writes the flag stays the only one.
    mutating func releaseAll() -> Bool? {
        let before = isMuted
        reasons.removeAll()
        return isMuted == before ? nil : isMuted
    }

    /// For the log line at the one write site: which reasons are standing,
    /// in a stable order.
    var reasonsDescription: String {
        reasons.isEmpty
            ? "none"
            : Reason.allCases.filter(reasons.contains).map(\.rawValue).joined(separator: "+")
    }
}
