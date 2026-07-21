import XCTest
@testable import GoodCloudKit

final class DevicesTests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func test_devices_decodesRowsAndOnlineFlag() async throws {
        let json = """
        {"code":0,"msg":"Success.","info":{"all_count":2,"online_count":1,"total":2,"rows":[
          {"id":"100000001","name":"Mudi7","mac":"aabbccddeeff","ddns":"demo01","model":"e5800",
           "status":1,"network_mode":"router","rtty_web":"1","rtty_ssh":"1"},
          {"id":"111","name":"Tesla","mac":"001122334455","ddns":"tsla","model":"x3000",
           "status":0,"network_mode":"router","rtty_web":"1","rtty_ssh":"1"}
        ]}}
        """
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/cloud-api/cloud/v2/device")
            return .init(status: 200, data: Data(json.utf8), headers: [:])
        }
        let client = SignedAPIClient(session: StubURLProtocol.session(), tokens: StaticTokenProvider("t"))
        let devices = try await client.devices()
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].id, "100000001")
        XCTAssertEqual(devices[0].ddns, "demo01")
        XCTAssertTrue(devices[0].isOnline)
        XCTAssertFalse(devices[1].isOnline)
    }

    func test_devices_decodesRowMissingOptionalFields() async throws {
        let json = """
        {"code":0,"msg":"Success.","info":{"rows":[
          {"id":"999","name":"Bare","mac":"aabbccddeeff","model":"e5800","status":1}
        ]}}
        """
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/cloud-api/cloud/v2/device")
            return .init(status: 200, data: Data(json.utf8), headers: [:])
        }
        let client = SignedAPIClient(session: StubURLProtocol.session(), tokens: StaticTokenProvider("t"))
        let devices = try await client.devices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertNil(devices[0].ddns)
        XCTAssertNil(devices[0].networkMode)
        XCTAssertNil(devices[0].rttyWeb)
        XCTAssertNil(devices[0].rttySsh)
        XCTAssertTrue(devices[0].isOnline)
    }
}
