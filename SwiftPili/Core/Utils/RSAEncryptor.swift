import Foundation
import Security

enum RSAEncryptor {
    static func encrypt(password: String, salt: String, publicKeyPEM: String) -> String? {
        let plaintext = salt + password
        guard let plaintextData = plaintext.data(using: .utf8),
              let publicKey = loadPublicKey(from: publicKeyPEM) else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionPKCS1,
            plaintextData as CFData,
            &error
        ) else {
            return nil
        }

        return (encrypted as Data).base64EncodedString()
    }

    private static func loadPublicKey(from pem: String) -> SecKey? {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let data = Data(base64Encoded: stripped) else { return nil }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]

        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }
}
