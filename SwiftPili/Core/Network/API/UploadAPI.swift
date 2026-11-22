import Foundation

/// Multipart image upload endpoints (avatar update and BFS comment attachments).
///
/// `BiliAPIClient` only speaks form-urlencoded, so these build multipart
/// requests directly while sharing `HTTPCookieStorage.shared` for auth.
enum UploadAPI {
    /// Update the account avatar (multipart `"face"` JPEG + csrf). BiliBili
    /// reviews avatars asynchronously: `nav`/`myinfo` continue serving the old
    /// face URL until review passes, so callers echo the picked image locally.
    static func updateAvatar(_ imageData: Data) async throws {
        guard let csrf = AuthManager.shared.biliJct else { throw BiliError.authRequired }
        _ = try await uploadMultipart(
            url: URL(string: "https://api.bilibili.com/x/member/web/face/update")!,
            referer: "https://space.bilibili.com",
            fields: [
                ("csrf", csrf),
                ("dopost", "save"),
                ("Displayrank", "1000"),
            ],
            fileField: "face",
            filename: "face.jpg",
            fileData: imageData,
            payloadType: EmptyResult.self,
            defaultErrorMessage: "avatar update failed",
            logTag: "[Avatar] face/update"
        )
    }

    static func uploadImage(_ imageData: Data, filename: String = "image.jpg") async throws -> BFSUploadResult {
        guard let csrf = AuthManager.shared.biliJct else { throw BiliError.authRequired }
        var comps = URLComponents(string: "https://api.bilibili.com/x/dynamic/feed/draw/upload_bfs")!
        comps.queryItems = [URLQueryItem(name: "csrf", value: csrf)]
        let result = try await uploadMultipart(
            url: comps.url!,
            referer: "https://t.bilibili.com",
            fields: [
                ("biz", "new_dyn"),
                ("category", "daily"),
                ("csrf", csrf),
            ],
            fileField: "file_up",
            filename: filename,
            fileData: imageData,
            payloadType: BFSUploadResult.self,
            defaultErrorMessage: "upload failed"
        )
        guard let result else {
            throw BiliError.apiError(code: -1, message: "upload failed")
        }
        return result
    }

    private struct MultipartEnvelope<Payload: Decodable>: Decodable {
        let code: Int
        let message: String?
        let data: Payload?
    }

    private static func uploadMultipart<Payload: Decodable>(
        url: URL,
        referer: String,
        fields: [(String, String)],
        fileField: String,
        filename: String,
        fileData: Data,
        payloadType: Payload.Type,
        defaultErrorMessage: String,
        logTag: String? = nil
    ) async throws -> Payload? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let boundary = "----SwiftPili\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        if let logTag {
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            PlayerLog.log("\(logTag) HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(preview)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BiliError.network(URLError(.badServerResponse))
        }
        let envelope = try JSONDecoder().decode(MultipartEnvelope<Payload>.self, from: data)
        guard envelope.code == 0 else {
            throw BiliError.apiError(code: envelope.code, message: envelope.message ?? defaultErrorMessage)
        }
        return envelope.data
    }
}
