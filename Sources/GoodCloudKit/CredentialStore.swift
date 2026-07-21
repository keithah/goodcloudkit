import Foundation

public struct Credentials: Sendable, Equatable {
    public var account: String
    public var refreshToken: String
    public init(account: String, refreshToken: String) {
        self.account = account
        self.refreshToken = refreshToken
    }
}

public protocol CredentialStore: Sendable {
    func save(_ credentials: Credentials) throws
    func load() throws -> Credentials?
    func delete() throws
}

/// In-memory store for tests and previews. Not persistent.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    public init() {}
    public func save(_ credentials: Credentials) throws {
        lock.lock(); defer { lock.unlock() }
        value = credentials
    }
    public func load() throws -> Credentials? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        value = nil
    }
}
