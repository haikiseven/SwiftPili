import Foundation

extension BiliURLParser {
    enum InteractiveResult {
        case native(Route)
        case unsupported(URL)
        case failed(String)
        case cancelled
    }

    static func handlesContent(_ url: URL) -> Bool {
        url.scheme == "bilibili" || (BiliLinkHostPolicy.isSupportedScheme(url.scheme)
            && (BiliLinkHostPolicy.isBilibiliHost(url.host) || BiliLinkHostPolicy.isShortener(url.host)))
    }

    static func localResult(_ url: URL) -> InteractiveResult? {
        if url.scheme == "bilibili" {
            guard let route = parse(url) else { return .unsupported(url) }
            if case .videoDetail(let target) = route, hasUnrepresentedVideoQuery(url, videoID: target.videoID) {
                return .unsupported(url)
            }
            return .native(route)
        }
        switch BiliLinkResolver.resolve(url: url) {
        case .resolved(let target, let sanitized):
            let destination = sanitized ?? url
            if case .video(let id) = target, hasUnrepresentedVideoQuery(destination, videoID: id) {
                return .unsupported(destination)
            }
            return .native(target.route)
        case .needsRedirect:
            return nil
        case .none:
            return .unsupported(BiliLinkSanitizer.sanitize(url))
        }
    }

    @MainActor
    static func resolveInteractive(_ url: URL) async -> InteractiveResult {
        if let result = localResult(url) { return result }
        do {
            let final = try await BiliShortLinkTransport.shared.resolvedURL(for: url)
            guard !Task.isCancelled else { return .cancelled }
            guard BiliLinkHostPolicy.isSupportedScheme(final.scheme),
                  BiliLinkHostPolicy.isBilibiliHost(final.host) else { return .unsupported(url) }
            return localResult(final) ?? .unsupported(BiliLinkSanitizer.sanitize(final))
        } catch {
            if Task.isCancelled || error.isCancellation { return .cancelled }
            return .failed(error.localizedDescription)
        }
    }

    private static func hasUnrepresentedVideoQuery(_ url: URL, videoID: VideoID) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Route.videoDetail names only the video. Other surviving parameters
        // belong to the original page until a typed native intent supports them.
        return items.contains { item in
            switch (item.name, videoID) {
            case ("aid", .aid(let aid)): return item.value.flatMap(Int.init) != aid
            case ("bvid", .bvid(let bvid)): return item.value != bvid
            default: return true
            }
        }
    }
}
