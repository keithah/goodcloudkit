import Foundation

public struct GoodCloudDevice: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let mac: String
    public let ddns: String?
    public let model: String
    public let status: Int
    public let networkMode: String?
    public let rttyWeb: String?
    public let rttySsh: String?

    public var isOnline: Bool { status == 1 }

    enum CodingKeys: String, CodingKey {
        // The device-LIST endpoint (verified live) uses snake_case `network_mode` but camelCase
        // `rttyWeb`/`rttySsh`. (The device-detail endpoint uses snake_case for the rtty fields —
        // if that endpoint is ever consumed, it needs its own model.)
        case id, name, mac, ddns, model, status, rttyWeb, rttySsh
        case networkMode = "network_mode"
    }
}
