import Foundation

extension UserAPI {
    struct RelationMutationAuthentication: Sendable {
        fileprivate let csrf: String
        fileprivate let cookie: String

        @MainActor
        static func capture(mid: String) -> Self? {
            let auth = AuthManager.shared
            guard auth.isLoggedIn, auth.dedeUserID == mid,
                  let sessData = auth.sessData, let csrf = auth.biliJct else { return nil }
            var cookies = [
                "SESSDATA=\(sessData)", "bili_jct=\(csrf)", "DedeUserID=\(mid)",
            ]
            if let ckMd5 = auth.ckMd5 { cookies.append("DedeUserID__ckMd5=\(ckMd5)") }
            return Self(csrf: csrf, cookie: cookies.joined(separator: "; "))
        }
    }

    static func setBlocked(
        _ blocked: Bool, mid: Int, authentication: RelationMutationAuthentication
    ) async throws(BiliError) {
        _ = try await BiliAPIClient.shared.request(
            BiliEndpoint(
                path: "/x/relation/modify",
                method: .post,
                params: [
                    "fid": String(mid), "act": blocked ? "5" : "6", "csrf": authentication.csrf,
                ],
                headers: ["Cookie": authentication.cookie]
            ),
            type: EmptyResult.self
        )
    }
}
