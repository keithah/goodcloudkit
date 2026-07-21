import Foundation

extension SignedAPIClient {
    private struct RttyRunInfo: Decodable, Sendable {
        let token_domain: String
        let url: String
        struct Content: Decodable, Sendable { let id: String?; let time: Int64? }
        let content: Content?
    }

    /// Provision an rtty relay to a device's LAN target and return the relay base URL.
    /// `port`/`protocol`/`ip` select the LAN service (e.g. port 8377 for Wattline).
    public func remoteAccess(deviceID: String,
                             kind: RelayKind = .web,
                             protocol proto: RelayProtocol = .http,
                             ip: String = "127.0.0.1",
                             port: Int = 80) async throws -> RemoteAccessSession {
        let (info, response) = try await sendReturningResponse(method: "POST",
            path: "/cloud-api/cloud/device/v4/\(deviceID)/rtty/run", query: [
            URLQueryItem(name: "enable", value: "true"),
            URLQueryItem(name: "ip", value: ip),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "protocol", value: proto.rawValue),
            URLQueryItem(name: "rtty_type", value: kind.rawValue),
            // Only observed live for rtty_type=web (Remote GUI); web=true with rtty_type=.ssh is unverified — confirm when the SSH path is built.
            URLQueryItem(name: "web", value: "true"),
        ], body: nil, as: RttyRunInfo.self)

        guard let url = URL(string: info.url) else {
            throw GoodCloudError.decoding("rtty/run returned an invalid relay url")
        }
        // The provisioning response carries NO Set-Cookie. The web client derives the
        // `gl-rtty-token` cookie from the body (value = `content.id`) and also sends the
        // session `FE_TOKEN`; both are `.goodcloud.xyz` cookies the relay host reads.
        _ = response // headers unused; relay auth comes from the body + session token
        let feToken = try? await currentAuthToken()
        return RemoteAccessSession(baseURL: url,
                                   tokenDomain: info.token_domain,
                                   sessionID: info.content?.id,
                                   issuedAtMillis: info.content?.time,
                                   relayToken: info.content?.id,
                                   feToken: feToken)
    }
}
