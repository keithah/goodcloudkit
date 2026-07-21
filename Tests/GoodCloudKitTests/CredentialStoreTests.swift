import XCTest
@testable import GoodCloudKit

final class CredentialStoreTests: XCTestCase {
    func test_loadIsNilBeforeSave() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.load())
    }

    func test_saveThenLoadRoundTrips() throws {
        let store = InMemoryCredentialStore()
        let creds = Credentials(account: "user@example.com", refreshToken: "rt-123")
        try store.save(creds)
        XCTAssertEqual(try store.load(), creds)
    }

    func test_deleteClears() throws {
        let store = InMemoryCredentialStore()
        try store.save(Credentials(account: "a", refreshToken: "b"))
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func test_saveOverwrites() throws {
        let store = InMemoryCredentialStore()
        try store.save(Credentials(account: "a", refreshToken: "1"))
        try store.save(Credentials(account: "a", refreshToken: "2"))
        XCTAssertEqual(try store.load()?.refreshToken, "2")
    }
}
