import Foundation

/// A live rendition menu, supplied by the room screen for the player's own
/// control bar.
///
/// **Why the player is given this instead of building it.** Two things make a
/// live quality switch the room's business, not the player's:
///
///  - `LiveRoomViewModel.switchQuality` is the only correct entry point. It
///    checks the player owner lease before reloading and appends the
///    "Switched to X" system line to the room chat. A player-side reload would
///    bypass both and leave the room's own `currentQuality` stale.
///  - The rendition list is the room's `g_qn_desc`, already localized upstream,
///    on a qn scale that is not VOD's (`LiveQualityDescription`).
///
/// **Why it is needed at all.** The room screen's two quality pickers are
/// mounted behind `!player.isFullscreen && !usesImmersivePortraitLayout` and
/// the immersive-portrait overlay respectively. On iPhone landscape IS
/// fullscreen, so in landscape live neither mounted and the only remaining
/// chrome was the player's own bars — whose Resolution menu sits under
/// `mode.supportsPlaybackRate`, which is `false` for `.live`. The result was a
/// live stream whose quality could not be changed in landscape at all.
///
/// It is a plain value rebuilt on every host body evaluation, deliberately: an
/// installed-callback channel (`onPlaybackEnded`) needs a clear-on-stop
/// lifecycle and can go stale against the room it describes, whereas this
/// cannot be older than the frame it is drawn in.
struct LiveQualityControl {
    struct Option: Identifiable, Sendable {
        let qn: Int
        let label: String
        var id: Int { qn }
    }

    let options: [Option]
    /// The qn currently playing, as the room understands it.
    let current: Int
    let select: @MainActor (Int) -> Void

    /// `nil` when the playing qn is not one the room advertised — the label
    /// then falls back to the caller's own wording rather than inventing a
    /// name on the wrong scale.
    var currentLabel: String? {
        options.first { $0.qn == current }?.label
    }
}
