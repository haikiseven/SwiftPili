import SwiftUI
import WebKit

struct GeetestView: UIViewRepresentable {
    let gt: String
    let challenge: String
    let token: String
    let onSuccess: (CaptchaValidation) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSuccess: onSuccess, onFailure: onFailure, token: token)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "geetest")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        let html = geetestHTML(gt: gt, challenge: challenge)
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.bilibili.com"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private func geetestHTML(gt: String, challenge: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body { margin: 0; padding: 20px; background: transparent; display: flex; justify-content: center; }
                #captcha { width: 100%; }
            </style>
        </head>
        <body>
            <div id="captcha"></div>
            <script src="https://static.geetest.com/static/js/gt.0.5.0.js"></script>
            <script>
                initGeetest({
                    gt: "\(gt)",
                    challenge: "\(challenge)",
                    offline: false,
                    new_captcha: true,
                    product: "bind",
                    width: "100%"
                }, function(captchaObj) {
                    captchaObj.onReady(function() {
                        captchaObj.verify();
                    });
                    captchaObj.onSuccess(function() {
                        var result = captchaObj.getValidate();
                        window.webkit.messageHandlers.geetest.postMessage(JSON.stringify({
                            "type": "success",
                            "challenge": result.geetest_challenge,
                            "validate": result.geetest_validate,
                            "seccode": result.geetest_seccode
                        }));
                    });
                    captchaObj.onError(function() {
                        window.webkit.messageHandlers.geetest.postMessage(JSON.stringify({"type": "error"}));
                    });
                    captchaObj.onClose(function() {
                        window.webkit.messageHandlers.geetest.postMessage(JSON.stringify({"type": "close"}));
                    });
                });
            </script>
        </body>
        </html>
        """
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        let onSuccess: (CaptchaValidation) -> Void
        let onFailure: () -> Void
        let token: String

        init(onSuccess: @escaping (CaptchaValidation) -> Void, onFailure: @escaping () -> Void, token: String) {
            self.onSuccess = onSuccess
            self.onFailure = onFailure
            self.token = token
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return
            }

            if json["type"] == "success",
               let challenge = json["challenge"],
               let validate = json["validate"] {
                let validation = CaptchaValidation(
                    token: token,
                    challenge: challenge,
                    validate: validate
                )
                Task { @MainActor in onSuccess(validation) }
            } else {
                Task { @MainActor in onFailure() }
            }
        }
    }
}
