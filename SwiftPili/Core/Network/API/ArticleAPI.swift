import Foundation

/// Column articles (专栏).
enum ArticleAPI {
    static func getViewInfo(cvid: Int) async throws(BiliError) -> ArticleViewInfo {
        try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/article/viewinfo",
                params: ["id": String(cvid)]
            ),
            type: ArticleViewInfo.self
        )
    }

    static func setLike(cvid: Int, like: Bool) async throws(BiliError) -> EmptyResult {
        guard let csrf = AuthManager.shared.biliJct else { throw .authRequired }
        return try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/article/like",
                method: .post,
                params: ["id": String(cvid), "type": like ? "1" : "2", "csrf": csrf]
            ),
            type: EmptyResult.self
        )
    }

    /// There is no JSON endpoint for article bodies — the content is
    /// server-rendered HTML on the read page (desktop layout carries it
    /// in #read-article-holder).
    static func fetchReadPageHTML(cvid: Int) async throws -> String {
        guard let url = URL(string: "https://www.bilibili.com/read/cv\(cvid)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(BiliAPIClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(BiliAPIClient.defaultReferer, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
