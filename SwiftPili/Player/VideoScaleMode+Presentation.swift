import UIKit

extension VideoScaleMode {
    var label: String {
        switch self {
        case .fit: String(localized: "Fit")
        case .fill: String(localized: "Zoom to Fill")
        case .stretch: String(localized: "Stretch")
        }
    }

    var contentMode: UIView.ContentMode {
        switch self {
        case .fit: .scaleAspectFit
        case .fill: .scaleAspectFill
        case .stretch: .scaleToFill
        }
    }
}
