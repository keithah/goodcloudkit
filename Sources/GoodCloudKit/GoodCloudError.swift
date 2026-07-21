import Foundation

public enum GoodCloudError: Error, Equatable, Sendable {
    case authFailed
    case credentialsRejected
    case deviceOffline
    case deviceNotFound
    case relayUnavailable
    case sessionExpired
    case transport(URLError)
    case decoding(String)
    case signing(String)
    case api(code: Int, message: String)
    case httpStatus(Int)

    /// Loggable description of this error.
    ///
    /// The fixed cases (`.authFailed`, `.credentialsRejected`, `.deviceOffline`,
    /// `.deviceNotFound`, `.relayUnavailable`, `.sessionExpired`, `.transport`)
    /// carry no secrets: `.transport` surfaces only the numeric `URLError.Code`,
    /// never the underlying URL or host.
    ///
    /// `.decoding(context:)` echoes the caller-supplied diagnostic `context`
    /// string verbatim. Callers are responsible for ensuring that context is
    /// free of secret material before constructing this case.
    ///
    /// `.signing(message:)` echoes a caller-supplied diagnostic `message`
    /// verbatim. Callers must ensure that message never includes key material
    /// or the signed plaintext.
    ///
    /// `.api(code:message:)` logs only the numeric server `code`; the server-supplied
    /// `message` is omitted from the redacted line because it may echo untrusted
    /// server text.
    ///
    /// `.httpStatus(code:)` carries only the numeric HTTP status code, never the
    /// response body.
    public var redactedDescription: String {
        switch self {
        case .authFailed: return "authentication failed"
        case .credentialsRejected: return "credentials rejected"
        case .deviceOffline: return "device offline"
        case .deviceNotFound: return "device not found"
        case .relayUnavailable: return "relay unavailable"
        case .sessionExpired: return "remote-access session expired"
        case .transport(let e): return "transport error (\(e.code.rawValue))"
        case .decoding(let context): return "decoding error: \(context)"
        case .signing(let m): return "signing error: \(m)"
        case .api(let c, _): return "api error (code \(c))"
        case .httpStatus(let s): return "http status \(s)"
        }
    }
}
