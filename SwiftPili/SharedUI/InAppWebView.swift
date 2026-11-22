import SwiftUI
import WebKit

struct InAppWebView: View {
    let url: URL
    let close: @MainActor () -> Void

    var body: some View {
        InAppWebContent(url: url, close: close).id(url)
    }
}

private struct InAppWebContent: View {
    let url: URL
    let close: @MainActor () -> Void
    @State private var page = InAppWebState()

    var body: some View {
        InAppWebSurface(url: url, page: page)
            .overlay(alignment: .top) {
                if page.isLoading { ProgressView().padding(8).background(.regularMaterial, in: Capsule()) }
            }
            .overlay {
                if let failure = page.failure {
                    ContentUnavailableView {
                        Label("Page Unavailable", systemImage: "globe")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Retry") { page.reload() }.buttonStyle(.borderedProminent)
                    }
                    .background(.background)
                }
            }
            .navigationTitle("Web Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { page.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(!page.canGoBack)
                    Spacer()
                    Button { page.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Spacer()
                    Button("Close") { close() }
                }
            }
    }
}

@MainActor
@Observable
private final class InAppWebState {
    var isLoading = true
    var canGoBack = false
    var failure: String?
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var navigation: WKNavigation?
    @ObservationIgnored var request: URLRequest?

    func reload() {
        guard let webView else { return }
        let retryingFailure = failure != nil
        failure = nil
        if retryingFailure, let request {
            navigation = webView.load(request)
        } else {
            navigation = webView.reload() ?? request.flatMap { webView.load($0) }
        }
        isLoading = navigation != nil
        if !isLoading { failure = String(localized: "Page Unavailable") }
    }

    func goBack() {
        guard let webView, webView.canGoBack else { return }
        failure = nil
        isLoading = true
        navigation = webView.goBack()
    }
}

private struct InAppWebSurface: UIViewRepresentable {
    let url: URL
    let page: InAppWebState

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        page.webView = view
        if BiliLinkHostPolicy.isSupportedScheme(url.scheme) {
            let request = URLRequest(url: url)
            page.request = request
            page.navigation = view.load(request)
        } else {
            page.isLoading = false
            page.failure = String(localized: "Link Unavailable")
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.page.webView = nil
        coordinator.page.navigation = nil
        coordinator.page.request = nil
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let page: InAppWebState

        init(page: InAppWebState) { self.page = page }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy {
            guard webView === page.webView,
                  BiliLinkHostPolicy.isSupportedScheme(navigationAction.request.url?.scheme) else { return .cancel }
            if navigationAction.targetFrame?.isMainFrame == true {
                page.request = navigationAction.request
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            guard webView === page.webView else { return }
            page.navigation = navigation
            page.failure = nil
            page.isLoading = true
            page.canGoBack = webView.canGoBack
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard webView === page.webView, navigation === page.navigation else { return }
            page.isLoading = false
            page.canGoBack = webView.canGoBack
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error
        ) {
            finishFailure(webView, navigation: navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
            finishFailure(webView, navigation: navigation, error: error)
        }

        private func finishFailure(_ view: WKWebView, navigation: WKNavigation?, error: any Error) {
            guard view === page.webView, navigation === page.navigation else { return }
            page.isLoading = false
            page.canGoBack = view.canGoBack
            let failure = error as NSError
            guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
            page.failure = error.localizedDescription
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === page.webView else { return }
            page.isLoading = false
            page.navigation = nil
            page.failure = String(localized: "Page Unavailable")
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard webView === page.webView, navigationAction.targetFrame == nil,
                  BiliLinkHostPolicy.isSupportedScheme(navigationAction.request.url?.scheme) else { return nil }
            page.request = navigationAction.request
            page.navigation = webView.load(navigationAction.request)
            return nil
        }
    }
}
