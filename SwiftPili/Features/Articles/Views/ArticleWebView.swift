import SwiftUI
import WebKit

struct ArticleWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(initialURL: url)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let readerCSS = """
        .m-navbar, .navbar, .international-header, .bili-header, \
        .openapp-dialog, .openapp-t, .m-open-app, .launch-app-btn, \
        .open-app, .fixed-openapp, .float-openapp, .agree-panel, \
        .up-card, .read-recommend, .recommend-list, .m-footer, \
        .comment-box, .b-cmt, .bottom-bar, .toolbar, .banner-link \
        { display: none !important; }
        """
        let script = """
        (function() {
            var style = document.createElement('style');
            style.innerHTML = `\(readerCSS)`;
            document.head.appendChild(style);
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        let openURL = context.environment.openURL
        context.coordinator.onOpenNativeLink = { openURL($0) }

        let store = config.websiteDataStore.httpCookieStore
        let targetURL = url
        let coordinator = context.coordinator
        Task { @MainActor in
            for cookie in InAppWebView.bilibiliAuthCookies() {
                await store.setCookie(cookie)
            }
            guard coordinator.webView === webView else { return }
            webView.load(URLRequest(url: targetURL))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let openURL = context.environment.openURL
        context.coordinator.onOpenNativeLink = { openURL($0) }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.webView = nil
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let initialURL: URL
        var onOpenNativeLink: (@MainActor (URL) -> Void)?
        weak var webView: WKWebView?

        init(initialURL: URL) {
            self.initialURL = initialURL
        }

        private func shouldInterceptNativeLink(_ targetURL: URL) -> Bool {
            if targetURL.scheme?.lowercased() == "bilibili" {
                return BiliURLParser.parse(targetURL) != nil
            }
            guard BiliLinkHostPolicy.isSupportedScheme(targetURL.scheme),
                  BiliLinkSanitizer.sanitize(targetURL) != BiliLinkSanitizer.sanitize(initialURL) else {
                return false
            }
            if BiliLinkHostPolicy.isShortener(targetURL.host) { return true }
            guard let route = BiliURLParser.parse(targetURL) else { return false }
            if case .inAppWeb = route { return false }
            return true
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let targetURL = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated,
               shouldInterceptNativeLink(targetURL) {
                onOpenNativeLink?(targetURL)
                return .cancel
            }
            if let scheme = targetURL.scheme?.lowercased(),
               scheme != "http", scheme != "https", scheme != "about" {
                return .cancel
            }
            return .allow
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let targetURL = navigationAction.request.url else { return nil }
            if navigationAction.navigationType == .linkActivated,
               shouldInterceptNativeLink(targetURL) {
                onOpenNativeLink?(targetURL)
                return nil
            }
            guard BiliLinkHostPolicy.isSupportedScheme(targetURL.scheme) else { return nil }
            webView.load(navigationAction.request)
            return nil
        }
    }
}
