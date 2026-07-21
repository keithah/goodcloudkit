import Foundation

/// Shared `Set-Cookie` parsing for the small subset of formats GoodCloud uses.
enum CookieHeader {
    /// Extract a cookie value by name from one or more Set-Cookie header strings.
    static func value(named name: String, in setCookie: String?) -> String? {
        guard let setCookie else { return nil }
        let prefix = name + "="
        for cookie in setCookie.components(separatedBy: ",") {
            for part in cookie.split(separator: ";") {
                let kv = part.trimmingCharacters(in: .whitespaces)
                if kv.hasPrefix(prefix) { return String(kv.dropFirst(prefix.count)) }
            }
        }
        return nil
    }
}
