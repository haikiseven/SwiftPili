import Foundation

/// Names a live rendition for the stats overlay.
///
/// Live and VOD number their qualities on **different scales** — live uses
/// 10000/400/250/150/80, VOD uses 127/120/116/80/64/32/16 — so
/// `PlayerViewModel.qualityMap` cannot describe a live stream. Feeding a live
/// qn through it produced either a wrong name (80 reads as "1080P" on the VOD
/// scale, "SD" on the live one) or a bare number. Playback Info showed neither,
/// because nothing on the live path ever wrote the field at all.
///
/// The room's own `g_qn_desc` is the authority: it is what the server calls
/// these renditions for this room, and it is already localized upstream. The
/// static table is only for a payload that omits it.
enum LiveQualityDescription {
    /// Standard live rendition names, used only when the room advertised none.
    static func fallbackText(for qn: Int) -> String? {
        switch qn {
        case 10000: String(localized: "Original")
        case 400: String(localized: "Blu-ray")
        case 250: String(localized: "Ultra HD")
        case 150: String(localized: "HD")
        case 80: String(localized: "SD")
        default: nil
        }
    }

    /// `advertised` is the room's `g_qn_desc` as (qn, desc) pairs.
    ///
    /// The last resort is the number itself rather than an empty string: the
    /// stats overlay omits rows it has no value for, and silently dropping the
    /// Quality row is indistinguishable from the bug this replaced.
    static func text(for qn: Int, advertised: [(qn: Int, desc: String)]) -> String {
        if let match = advertised.first(where: { $0.qn == qn }),
           !match.desc.isEmpty {
            return match.desc
        }
        return fallbackText(for: qn) ?? "\(qn)"
    }
}
