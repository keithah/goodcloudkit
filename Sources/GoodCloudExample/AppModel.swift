import Foundation
import GoodCloudKit

/// The outcome of a single relay probe: the decoded HTTP result, or a redacted error string.
enum RelayOutcome {
    case success(RelayResult)
    case failure(String)
}

/// A relay probe result, safe to render directly (no tokens or cookies).
struct RelayResult {
    let statusCode: Int
    let byteCount: Int
    let bodyPreview: String
    let relayHost: String
    let hasRelayToken: Bool
}

/// Holds the GoodCloudKit auth actor plus all app state, and exposes async actions the
/// views call into. A fresh `SignedAPIClient` is created per operation, matching the
/// library's own usage pattern.
@MainActor
final class AppModel: ObservableObject {
    // Session
    @Published var isCheckingSession = true
    @Published var isAuthenticated = false
    @Published var isLoggingIn = false
    @Published var loginError: String?

    // Devices
    @Published var devices: [GoodCloudDevice] = []
    @Published var isLoadingDevices = false
    @Published var devicesError: String?

    private let auth = GoodCloudAuth()

    private func makeClient() -> SignedAPIClient {
        SignedAPIClient(tokens: PasswordTokenProvider(auth: auth))
    }

    /// Called once at launch. If a persisted token is still VALID, skip to devices; otherwise
    /// clear the stale token and show a clean login screen (no error flash). Validating here
    /// avoids the "resume → -1010 → bounce back to login" churn, important because GoodCloud
    /// accounts are single-session so persisted tokens are often stale.
    func checkExistingSession() async {
        defer { isCheckingSession = false }
        guard let token = try? await auth.currentToken(), !token.isEmpty else { return }
        do {
            devices = try await makeClient().devices()   // validates the token + preloads
            isAuthenticated = true
        } catch {
            try? await auth.logOut()                      // stale — clear silently, stay on login
        }
    }

    func logIn(email: String, password: String) async {
        loginError = nil
        isLoggingIn = true
        defer { isLoggingIn = false }
        gcklog("login: attempting for \(email)")
        do {
            _ = try await auth.logIn(email: email, password: password)
            isAuthenticated = true
            gcklog("login: OK (token acquired)")
        } catch {
            loginError = Self.describe(error)
            gcklog("login: FAILED — \((error as? GoodCloudError)?.redactedDescription ?? "\(error)")")
        }
    }

    func logOut() async {
        try? await auth.logOut()
        resetToLogin()
    }

    /// Ends the session server-side (all sessions, since the account is single-session) and
    /// returns to login. Use when a session is stuck or held elsewhere.
    func logOutEverywhere() async {
        await auth.logOutEverywhere()
        resetToLogin()
        loginError = "Logged out everywhere. Log in to start a new session."
    }

    private func resetToLogin() {
        isAuthenticated = false
        devices = []
        devicesError = nil
        loginError = nil
    }

    func loadDevices() async {
        isLoadingDevices = true
        devicesError = nil
        defer { isLoadingDevices = false }
        gcklog("devices: loading")
        do {
            devices = try await makeClient().devices()
            let online = devices.filter { $0.isOnline }.count
            gcklog("devices: got \(devices.count) (online: \(online))")
        } catch {
            gcklog("devices: FAILED — \((error as? GoodCloudError)?.redactedDescription ?? "\(error)")")
            if Self.isSessionExpired(error) { await expireSession(); return }
            devicesError = Self.describe(error)
        }
    }

    /// True for errors that mean the stored session is no longer valid (GoodCloud accounts are
    /// single-session: a newer login elsewhere returns code -1010 "Account Login Elsewhere").
    static func isSessionExpired(_ error: Error) -> Bool {
        if case let GoodCloudError.api(code, _) = error { return code == -1010 }
        return false
    }

    /// Clears the dead session and routes back to the login screen with an explanation.
    private func expireSession() async {
        await logOut()
        loginError = "Session ended (your account was used elsewhere). Please log in again."
    }

    /// Provisions a relay to the device's LAN target and issues a single GET through it.
    func sendRelayRequest(device: GoodCloudDevice, proto: RelayProtocol, port: Int,
                          path: String) async -> RelayOutcome {
        gcklog("remoteAccess: provisioning device=\(device.id) proto=\(proto.rawValue) port=\(port)")
        let session: RemoteAccessSession
        do {
            session = try await makeClient().remoteAccess(deviceID: device.id, kind: .web,
                                                            protocol: proto, port: port)
            gcklog("remoteAccess: OK relayHost=\(session.baseURL.host ?? "unknown host") relayTokenCaptured=\(session.relayToken != nil)")
        } catch {
            let message = Self.describe(error)
            gcklog("remoteAccess: FAILED — \((error as? GoodCloudError)?.redactedDescription ?? "\(error)")")
            if Self.isSessionExpired(error) { await expireSession() }
            return .failure(message)
        }

        gcklog("relay GET '\(path)'")
        do {
            let (data, response) = try await RelayHTTPClient(session: session).get(path)
            gcklog("relay: HTTP \(response.statusCode), \(data.count) bytes (final host=\(response.url?.host ?? "?"))")
            let result = RelayResult(
                statusCode: response.statusCode,
                byteCount: data.count,
                bodyPreview: Self.previewText(for: data),
                relayHost: session.baseURL.host ?? "unknown host",
                hasRelayToken: session.relayToken != nil
            )
            return .success(result)
        } catch {
            let message = Self.describe(error)
            gcklog("relay: FAILED — \((error as? GoodCloudError)?.redactedDescription ?? "\(error)")")
            return .failure(message)
        }
    }

    /// Decodes up to the first ~2KB of a response body as text for on-screen preview.
    private static func previewText(for data: Data) -> String {
        let capped = data.prefix(2048)
        if capped.isEmpty { return "(empty response body)" }
        if let text = String(data: capped, encoding: .utf8) { return text }
        return "(binary data, \(data.count) bytes — cannot display as text)"
    }

    private static func describe(_ error: Error) -> String {
        (error as? GoodCloudError)?.redactedDescription ?? "Unexpected error. Please try again."
    }
}
