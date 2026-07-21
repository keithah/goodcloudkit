import Foundation

public protocol TokenProvider: Sendable {
    func token() async throws -> String
}

/// A fixed token (e.g. an FE_TOKEN obtained out-of-band). The OIDC login provider is separate.
public struct StaticTokenProvider: TokenProvider {
    private let value: String
    public init(_ token: String) { self.value = token }
    public func token() async throws -> String { value }
}
