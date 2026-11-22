import Foundation

enum LiveQualityDescription {
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

    static func text(for qn: Int, advertised: [(qn: Int, desc: String)]) -> String {
        if let match = advertised.first(where: { $0.qn == qn }),
           !match.desc.isEmpty {
            return match.desc
        }
        return fallbackText(for: qn) ?? "\(qn)"
    }
}
