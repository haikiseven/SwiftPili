import SwiftUI

// MARK: - Categories

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

    var apiValue: String { rawValue }

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

    var defaultAction: SponsorAction {
        switch self {
        case .sponsor, .selfpromo, .interaction, .musicOfftopic: .skip
        case .intro, .outro, .preview, .poiHighlight: .manual
        case .filler, .exclusiveAccess: .disabled
        }
    }

    static var submittable: [SponsorCategory] {
        [.sponsor, .selfpromo, .interaction, .intro, .outro, .preview, .musicOfftopic, .filler, .poiHighlight]
    }
}

// MARK: - Actions

enum SponsorAction: String, CaseIterable, Codable, Identifiable {
    case disabled
    case skip
    case mute
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

struct SponsorSegment: Identifiable, Equatable {
    let uuid: String
    let category: SponsorCategory
    let actionType: SponsorActionType
    let start: Double
    let end: Double
    let videoDuration: Double
    let locked: Bool
    let votes: Int
    let cid: String?

    var id: String { uuid }

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
