import UIKit

@MainActor
enum AppWindowMetrics {
    static var current: UIWindow? {
        let candidates = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .filter { $0.windowLevel == .normal && !$0.isHidden && $0.rootViewController != nil }
        return candidates.first(where: \.isKeyWindow) ?? candidates.first
    }

    static var safeAreaInsets: UIEdgeInsets { current?.safeAreaInsets ?? .zero }

    static var frameInScreen: CGRect? {
        guard let window = current else { return nil }
        return window.convert(window.bounds, to: nil)
    }

    static func bottomInset(orAtLeast layoutOwned: CGFloat) -> CGFloat {
        max(safeAreaInsets.bottom, max(0, layoutOwned))
    }
}
