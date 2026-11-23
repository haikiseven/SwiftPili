import SwiftUI
import WebKit

struct AuthedBiliWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context _: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)

        let cookies: [(name: String, value: String?)] = [
            ("SESSDATA", AuthManager.shared.sessData),
            ("bili_jct", AuthManager.shared.biliJct),
            ("DedeUserID", AuthManager.shared.dedeUserID),
        ]
        let store = config.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for (name, value) in cookies {
            guard let value,
                  let cookie = HTTPCookie(properties: [
                      .domain: ".bilibili.com",
                      .path: "/",
                      .name: name,
                      .value: value,
                      .secure: true,
                  ])
            else { continue }
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}
}
