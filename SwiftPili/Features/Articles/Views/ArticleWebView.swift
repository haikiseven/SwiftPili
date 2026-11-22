import SwiftUI
import WebKit

struct ArticleWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
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
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        // The async form, NOT the decisionHandler one: the SDK annotates
        // the completion closure @MainActor @Sendable, so an unannotated
        // signature only "nearly matches" the optional requirement —
        // WebKit then never calls it and the scheme filter is dead.
        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if let scheme = navigationAction.request.url?.scheme?.lowercased(),
               scheme != "http", scheme != "https", scheme != "about" {
                return .cancel
            }
            return .allow
        }
    }
}
