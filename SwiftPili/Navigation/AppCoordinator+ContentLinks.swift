import SwiftUI

extension AppCoordinator {
    @ViewBuilder
    func contentLinkDestination(for route: Route) -> some View {
        switch route {
        case .musicInfo(let destination): MusicDetailView(destination: destination)
        case .inAppWeb(let url):
            InAppWebView(url: url) { [weak self] in
                guard let self, self.activeDetailRoute == route else { return }
                self.goBack()
            }
        default: EmptyView()
        }
    }

    func contentLinkOrigin(_ context: ContentLinkContext? = nil) -> ContentLinkContext? {
        guard let origin = context ?? activeCoverLinkContext ?? rootLinkContext else { return nil }
        let navigation = contentLinkNavigationRevision
        let account = AccountManager.shared.identityRevision
        return origin.guarded { [weak self] in
            self?.contentLinkNavigationRevision == navigation
                && AccountManager.shared.identityRevision == account
        }
    }

    func noteContentLinkNavigationChange() {
        contentLinkNavigationRevision &+= 1
        contentLinks.cancel()
    }

    @discardableResult
    func openContentURL(
        _ url: URL,
        context: ContentLinkContext? = nil,
        beforeNavigate: @escaping @MainActor () -> Void = {}
    ) -> OpenURLAction.Result {
        contentLinks.cancel()
        guard BiliURLParser.handlesContent(url) else { return .systemAction }
        guard let captured = contentLinkOrigin(context) else { return .discarded }
        contentLinks.open(url, context: captured) { [weak self] route in
            captured.beforeNavigate()
            beforeNavigate()
            self?.navigate(to: route)
        }
        return .handled
    }
}
