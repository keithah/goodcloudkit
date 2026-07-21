import XCTest
import Security
@testable import GoodCloudKit

final class RequestSignerTests: XCTestCase {
    // Generate a throwaway RSA keypair; sign with its public key; decrypt with the
    // private key to prove the PKCS#1 v1.5 encryption + base64 encoding are correct.
    func test_signature_decryptsBackToInjectedTimestamp() throws {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        var err: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err)!
        let pub = SecKeyCopyPublicKey(priv)!
        let pubDER = SecKeyCopyExternalRepresentation(pub, &err)! as Data // PKCS#1 for RSA

        let fixed = Date(timeIntervalSince1970: 1_700_000_000) // -> 1700000000000 ms
        let signer = RequestSigner(publicKeyPKCS1DER: pubDER, now: { fixed })
        let sig = try signer.signature()

        let ct = Data(base64Encoded: sig)!
        let pt = SecKeyCreateDecryptedData(priv, .rsaEncryptionPKCS1, ct as CFData, &err)! as Data
        XCTAssertEqual(String(data: pt, encoding: .utf8), "1700000000000")
    }

    func test_goodCloudSigner_producesNonDeterministic88CharBase64Of64Bytes() throws {
        let signer = RequestSigner.goodCloud()
        let a = try signer.signature()
        let b = try signer.signature()
        XCTAssertEqual(a.count, 88)                    // 64-byte block, base64
        XCTAssertEqual(Data(base64Encoded: a)?.count, 64)
        XCTAssertNotEqual(a, b)                          // random PKCS#1 v1.5 padding
    }

    func test_encrypt_roundTripsArbitraryString() throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeySizeInBits as String: 1024]
        var err: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err)!
        let pubDER = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(priv)!, &err)! as Data
        let signer = RequestSigner(publicKeyPKCS1DER: pubDER)
        let ct = try signer.encrypt("hunter2-secret")
        let pt = SecKeyCreateDecryptedData(priv, .rsaEncryptionPKCS1, Data(base64Encoded: ct)! as CFData, &err)! as Data
        XCTAssertEqual(String(data: pt, encoding: .utf8), "hunter2-secret")
    }

    func test_encrypt_throwsWhenPlaintextTooLongForKey() {
        let signer = RequestSigner.goodCloud() // 512-bit: max 53 bytes
        XCTAssertThrowsError(try signer.encrypt(String(repeating: "x", count: 54))) { error in
            guard let gc = error as? GoodCloudError, case .signing = gc else {
                return XCTFail("expected .signing, got \(error)")
            }
        }
    }
}
