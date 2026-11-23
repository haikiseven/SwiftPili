import Foundation

extension BiliURLParser {
    enum InteractiveResult: Equatable {
        case native(Route)
        case unsupported(URL)
        case failed(String)
        case cancelled
    }

    static func handlesContent(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "bilibili" || (BiliLinkHostPolicy.isSupportedScheme(url.scheme)
            && (BiliLinkHostPolicy.isBilibiliHost(url.host) || BiliLinkHostPolicy.isShortener(url.host)))
    }

    static func localResult(_ url: URL) -> InteractiveResult? {
        if url.scheme?.lowercased() == "bilibili" {
            if let inner = unwrappedBrowserURL(from: url) {
                return localResult(inner)
            }
            guard let route = parse(url) else { return .unsupported(url) }
            return .native(route)
        }
        switch BiliLinkResolver.resolve(url: url) {
        case .resolved(let target, _):
            return .native(target.route)
        case .needsRedirect:
            return nil
        case .none:
            guard BiliLinkHostPolicy.isSupportedScheme(url.scheme) else {
                return .unsupported(url)
            }
            return .native(.inAppWeb(BiliLinkSanitizer.sanitize(url)))
        }
    }

    @MainActor
    static func resolveInteractive(_ url: URL) async -> InteractiveResult {
        if let result = localResult(url) { return result }
        let redirectTarget = unwrappedBrowserURL(from: url) ?? url
        do {
            let final = try await BiliShortLinkTransport.shared.resolvedURL(for: redirectTarget)
            guard !Task.isCancelled else { return .cancelled }
            if final.scheme?.lowercased() == "bilibili" {
                return localResult(final) ?? .unsupported(final)
            }
            guard BiliLinkHostPolicy.isSupportedScheme(final.scheme) else {
                return .unsupported(url)
            }
            return localResult(final) ?? .native(.inAppWeb(BiliLinkSanitizer.sanitize(final)))
        } catch {
            if Task.isCancelled || error.isCancellation { return .cancelled }
            return .failed(error.localizedDescription)
        }
    }
}
