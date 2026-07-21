import Foundation

extension SignedAPIClient {
    private struct DeviceListInfo: Decodable, Sendable {
        let rows: [GoodCloudDevice]
    }

    /// Bound routers for the current account (GET /cloud-api/cloud/v2/device).
    public func devices(page: Int = 1, pageSize: Int = 100) async throws -> [GoodCloudDevice] {
        let info = try await get("/cloud-api/cloud/v2/device", query: [
            URLQueryItem(name: "pageNum", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ], as: DeviceListInfo.self)
        return info.rows
    }
}
