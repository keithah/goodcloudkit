import Foundation

/// Uniform GoodCloud API response envelope: `{code, msg, info}`, where `code == 0`
/// indicates success and `info` carries the payload.
public struct APIResponse<Info: Decodable & Sendable>: Decodable, Sendable {
    public let code: Int
    public let msg: String
    public let info: Info?

    enum CodingKeys: String, CodingKey { case code, msg, info }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(Int.self, forKey: .code)
        msg = (try? c.decode(String.self, forKey: .msg)) ?? ""
        // Decode `info` LENIENTLY: on an error response (`code != 0`) the server sends an
        // error-shaped `info` (e.g. `{}`) that won't match `Info`. A strict decode would throw a
        // confusing shape error and mask the real API code/message, so we tolerate a mismatch
        // here (→ nil) and let `unwrap()` surface `.api(code, msg)` for non-zero codes.
        info = try? c.decode(Info.self, forKey: .info)
    }
}

extension APIResponse {
    /// Returns `info` when the call succeeded (`code == 0`); otherwise throws a typed error.
    public func unwrap() throws -> Info {
        guard code == 0 else { throw GoodCloudError.api(code: code, message: msg) }
        guard let info else { throw GoodCloudError.decoding("code 0 but info was null") }
        return info
    }
}
