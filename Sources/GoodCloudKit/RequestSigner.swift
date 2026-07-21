import Foundation
import Security

/// Reproduces GoodCloud's `signature` header:
/// base64( RSA/PKCS1v1.5-encrypt( pubkey, String(currentEpochMillis) ) ).
public struct RequestSigner: Sendable {
    private let publicKeyPKCS1DER: Data
    private let now: @Sendable () -> Date

    public init(publicKeyPKCS1DER: Data, now: @escaping @Sendable () -> Date = { Date() }) {
        self.publicKeyPKCS1DER = publicKeyPKCS1DER
        self.now = now
    }

    /// The embedded GoodCloud web-client RSA public key (PKCS#1 RSAPublicKey DER, base64).
    /// 512-bit, e=65537 — a public client key, safe to embed. See docs/signature-re.md.
    public static func goodCloud(now: @escaping @Sendable () -> Date = { Date() }) -> RequestSigner {
        let der = Data(base64Encoded:
            "MEgCQQCLaEfJawWf2WiWd1774D/CN9SJmk8GxD8zxJZiGQGrFqAM8NyJ6jFcni+605RUt0xc9xzCgZ6xZa+OtwbtfU89AgMBAAE="
        )!
        return RequestSigner(publicKeyPKCS1DER: der, now: now)
    }

    public func signature() throws -> String {
        let millis = Int64((now().timeIntervalSince1970 * 1000).rounded())
        return try encrypt(String(millis))
    }

    /// RSA/PKCS1v1.5-encrypts `plaintext` with the embedded public key, base64-encoded.
    /// Throws `GoodCloudError.signing` if `plaintext` exceeds the key's max block size (keyBlockSize - 11).
    public func encrypt(_ plaintext: String) throws -> String {
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(publicKeyPKCS1DER as CFData, attrs as CFDictionary, &error) else {
            throw GoodCloudError.signing("invalid public key: \(errString(error))")
        }
        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1) else {
            throw GoodCloudError.signing("PKCS1 encryption unsupported for key")
        }
        let data = Data(plaintext.utf8)
        let maxLen = SecKeyGetBlockSize(key) - 11 // PKCS#1 v1.5 overhead
        guard data.count <= maxLen else {
            throw GoodCloudError.signing("plaintext too long (\(data.count) > \(maxLen))")
        }
        guard let ct = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data as CFData, &error) else {
            throw GoodCloudError.signing("encrypt failed: \(errString(error))")
        }
        return (ct as Data).base64EncodedString()
    }

    private func errString(_ e: Unmanaged<CFError>?) -> String {
        guard let e else { return "unknown" }
        return CFErrorCopyDescription(e.takeRetainedValue()) as String? ?? "unknown"
    }
}
