import SwiftUI

// MARK: - Categories

/// SponsorBlock (BilibiliSponsorBlock) segment categories. The API keys
/// segments by these strings; the bar colors and default actions mirror
/// the upstream extension's `config.ts` defaults so the on-bar coloring a
/// user sees here matches the browser extension.
///
/// See https://github.com/hanydd/BilibiliSponsorBlock/wiki/API — new
/// server-side categories (e.g. `chapter`) that this enum doesn't list are
/// dropped at decode time, never crash the fetch.
enum SponsorCategory: String, CaseIterable, Codable, Identifiable {
    case sponsor
    case selfpromo
    case interaction
    case intro
    case outro
    case preview
    case musicOfftopic = "music_offtopic"
    case filler
    case poiHighlight = "poi_highlight"
    case exclusiveAccess = "exclusive_access"

    var id: String { rawValue }

    /// Wire value sent to / received from the API (identical to rawValue).
    var apiValue: String { rawValue }

    /// Bar color, taken verbatim from the extension's default `barTypes`.
    /// This is the "Color required by the API" the segment is drawn with.
    var color: Color {
        switch self {
        case .sponsor: Color(sponsorHex: "#00d400")
        case .selfpromo: Color(sponsorHex: "#ffff00")
        case .interaction: Color(sponsorHex: "#cc00ff")
        case .intro: Color(sponsorHex: "#00ffff")
        case .outro: Color(sponsorHex: "#0202ed")
        case .preview: Color(sponsorHex: "#008fd6")
        case .musicOfftopic: Color(sponsorHex: "#ff9900")
        case .filler: Color(sponsorHex: "#7300ff")
        case .poiHighlight: Color(sponsorHex: "#ff1684")
        case .exclusiveAccess: Color(sponsorHex: "#008a5c")
        }
    }

    /// Localized name shown in settings, the segment list, and skip toasts.
    var displayName: String {
        switch self {
        case .sponsor: String(localized: "Sponsor")
        case .selfpromo: String(localized: "Unpaid/Self Promotion")
        case .interaction: String(localized: "Interaction Reminder")
        case .intro: String(localized: "Intro/Intermission")
        case .outro: String(localized: "Endcards/Credits")
        case .preview: String(localized: "Preview/Recap")
        case .musicOfftopic: String(localized: "Non-Music Section")
        case .filler: String(localized: "Filler Tangent")
        case .poiHighlight: String(localized: "Highlight")
        case .exclusiveAccess: String(localized: "Exclusive Access")
        }
    }

    /// The action a fresh install applies. Mirrors the extension's sane
    /// defaults: promotional content auto-skips; softer categories only
    /// offer a manual button; filler / exclusive-access start off.
    var defaultAction: SponsorAction {
        switch self {
        case .sponsor, .selfpromo, .interaction, .musicOfftopic: .skip
        case .intro, .outro, .preview, .poiHighlight: .manual
        case .filler, .exclusiveAccess: .disabled
        }
    }

    /// Categories offered in the submit picker (a whole-video label like
    /// exclusive-access is submitted as a full-video action elsewhere in
    /// the extension; here we only submit time ranges + the POI highlight).
    static var submittable: [SponsorCategory] {
        [.sponsor, .selfpromo, .interaction, .intro, .outro, .preview, .musicOfftopic, .filler, .poiHighlight]
    }
}

// MARK: - Actions

/// What the client does when playback reaches a segment of a category.
/// Mirrors the extension's per-category dropdown (Skip / Mute / Show / Off).
enum SponsorAction: String, CaseIterable, Codable, Identifiable {
    /// Ignore the category entirely (not fetched, not drawn).
    case disabled
    /// Seek past the segment automatically with a toast.
    case skip
    /// Keep playing but silence the audio for the segment's duration,
    /// auto-restoring on exit — never seeks (matches SponsorBlock `mute`).
    case mute
    /// Draw it on the bar and offer a tap-to-skip button, never auto-seek.
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: String(localized: "Disabled")
        case .skip: String(localized: "Skip Automatically")
        case .mute: String(localized: "Mute Audio")
        case .manual: String(localized: "Show Skip Button")
        }
    }
}

/// API `actionType`. A segment is a skip/mute time range, a `poi` single
/// point of interest, or a whole-video `full` / `chapter` label. Only the
/// first three are meaningful to this client; unknown values decode to
/// `.skip` so a new server action never drops a whole fetch.
enum SponsorActionType: String, Codable, Identifiable {
    case skip
    case mute
    case poi
    case full
    case chapter

    var id: String { rawValue }

    init(apiValue: String) {
        self = SponsorActionType(rawValue: apiValue) ?? .skip
    }

    /// The action types a user can pick when submitting a time range.
    /// (poi is implied by the highlight category; full/chapter aren't
    /// submitted as ranges here.)
    static var submittable: [SponsorActionType] { [.skip, .mute] }

    var submitLabel: String {
        switch self {
        case .skip: String(localized: "Skip")
        case .mute: String(localized: "Mute")
        case .poi: String(localized: "Highlight")
        case .full: String(localized: "Full Video")
        case .chapter: String(localized: "Chapter")
        }
    }
}

// MARK: - Segment

/// One SponsorBlock segment for the playing video.
struct SponsorSegment: Identifiable, Equatable {
    let uuid: String
    let category: SponsorCategory
    let actionType: SponsorActionType
    /// Start / end in seconds. For a POI both are the same instant.
    let start: Double
    let end: Double
    let videoDuration: Double
    let locked: Bool
    let votes: Int
    /// The BiliBili `cid` the segment was submitted against, if the server
    /// scoped it to a part (multi-P videos share a BVID).
    let cid: String?

    var id: String { uuid }

    /// A single-instant marker rather than a range to skip over.
    var isPOI: Bool { actionType == .poi || category == .poiHighlight }

    var duration: Double { max(0, end - start) }
}

// MARK: - Errors

enum SponsorBlockError: LocalizedError {
    case notConfigured
    case badResponse
    case http(Int)
    case rejected(String)
    case duplicate
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "Set a User ID in SponsorBlock settings first.")
        case .badResponse:
            String(localized: "The SponsorBlock server returned an unexpected response.")
        case let .http(code):
            String(format: String(localized: "SponsorBlock server error (%lld)."), code)
        case let .rejected(message):
            message.isEmpty
                ? String(localized: "The submission was rejected.")
                : message
        case .duplicate:
            String(localized: "This segment has already been submitted.")
        case .rateLimited:
            String(localized: "Too many submissions — please slow down.")
        }
    }
}

// MARK: - Color(hex:)

extension Color {
    /// Minimal `#rrggbb` parser for the extension's fixed bar palette.
    /// Named distinctly to avoid clashing with any future general helper.
    init(sponsorHex hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
