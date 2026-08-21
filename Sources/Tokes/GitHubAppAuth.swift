import Foundation

/// Registration constants for Tokes' GitHub App.
///
/// The device flow authenticates with the app's *public* client ID alone — no
/// client secret ships in the binary, and refreshing a device-flow token needs
/// none either. The app is registered with a single fine-grained permission,
/// "Plan: read", which is all the billing usage endpoints require.
enum GitHubAppConfig {
    /// The registered GitHub App's client ID ("Dev Tokes", App ID 4666350,
    /// registered 2026-08-20 — see docs/github-app-setup.md). Public by
    /// design; the device flow uses no client secret.
    static let clientID = "Iv23lipdHFpNL7ZW67E4"
}

/// GitHub sign-in and billing-pipeline failures, with user-facing descriptions.
enum GitHubAuthError: LocalizedError, Equatable {
    case notConfigured
    case notConnected
    case storage
    case noBillingData
    case http(Int)
    case decode(String)
    case oauth(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build has no GitHub App client ID. See docs/github-app-setup.md."
        case .notConnected:
            return "Not signed in to GitHub — connect in Settings."
        case .storage:
            return "Could not save the GitHub sign-in to the keychain."
        case .noBillingData:
            return "GitHub reports no personal Copilot billing for this account. "
                + "A Copilot seat provided by an organization is billed to the "
                + "organization, and GitHub does not expose that usage per user."
        case .http(let code):
            return "GitHub returned HTTP \(code)."
        case .decode(let detail):
            return "Could not parse GitHub response (\(detail))."
        case .oauth(let message):
            return "GitHub sign-in failed: \(message)"
        }
    }
}

/// One issued token set plus the login it belongs to, persisted as JSON in
/// Tokes' own keychain item (service `com.appideas.tokes`). The login is
/// captured once at sign-in because the billing endpoints address the user by
/// username, and fetching it fresh every poll would double the request count.
struct GitHubAppTokens: Codable, Equatable {
    static let account = "github-app-oauth"

    var accessToken: String
    var accessExpiresAt: Date?
    var refreshToken: String?
    var refreshExpiresAt: Date?
    var login: String

    /// Builds a token set from a grant, stamping expiry deadlines from `issuedAt`.
    init(grant: GitHubDeviceAuth.TokenGrant, login: String, issuedAt: Date) {
        accessToken = grant.accessToken
        accessExpiresAt = grant.expiresIn.map { issuedAt.addingTimeInterval($0) }
        refreshToken = grant.refreshToken
        refreshExpiresAt = grant.refreshExpiresIn.map { issuedAt.addingTimeInterval($0) }
        self.login = login
    }

    init(accessToken: String, accessExpiresAt: Date?, refreshToken: String?,
         refreshExpiresAt: Date?, login: String) {
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
        self.login = login
    }

    /// Whether the access token is expired — or close enough to expire before
    /// a poll's response comes back — at `date`. No recorded expiry means the
    /// app was registered with non-expiring tokens; treat those as fresh.
    func accessExpired(at date: Date, leeway: TimeInterval = 60) -> Bool {
        guard let accessExpiresAt else { return false }
        return date >= accessExpiresAt.addingTimeInterval(-leeway)
    }

    /// Reads the stored token set, or nil when the user never signed in.
    static func load(service: String = CredentialsProvider.manualService) -> GitHubAppTokens? {
        guard let raw = CredentialsProvider.readManualToken(service: service, account: account),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GitHubAppTokens.self, from: data)
    }

    /// Persists this token set, replacing any previous one, and verifies the
    /// write by reading it back — a save that silently didn't stick would
    /// strand the poller signed-out while Settings says "Connected".
    @discardableResult
    func save(service: String = CredentialsProvider.manualService) -> Bool {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8),
              CredentialsProvider.saveManualToken(string, service: service, account: Self.account)
        else { return false }
        return Self.load(service: service) == self
    }

    /// Removes the stored token set (sign out).
    static func clear(service: String = CredentialsProvider.manualService) {
        CredentialsProvider.deleteManualToken(service: service, account: account)
    }
}

/// GitHub's device-authorization flow (RFC 8628) plus token refresh, against
/// github.com. Stateless single-shot calls; the Settings connect UI owns the
/// polling loop so it can render each phase and be cancelled.
struct GitHubDeviceAuth {
    /// Session used for requests; injectable for tests.
    var session: URLSession = .shared
    var clientID = GitHubAppConfig.clientID

    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    private static let userURL = URL(string: "https://api.github.com/user")!

    /// What `requestCode` returns: the code the user types and the polling terms.
    struct DeviceCode: Equatable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let interval: TimeInterval
        let expiresIn: TimeInterval
    }

    /// One issued token pair. GitHub Apps registered without token expiration
    /// return neither expiry nor refresh token, so everything past the access
    /// token is optional.
    struct TokenGrant: Equatable {
        let accessToken: String
        let expiresIn: TimeInterval?
        let refreshToken: String?
        let refreshExpiresIn: TimeInterval?
    }

    /// One answer from the token endpoint while the user is signing in.
    enum PollOutcome: Equatable {
        case authorized(TokenGrant)
        case pending
        case slowDown(interval: TimeInterval)
        case denied
        case expired
    }

    /// Starts the flow: asks GitHub for a user code and polling terms.
    func requestCode() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw GitHubAuthError.notConfigured }
        let wire = try await post(Self.deviceCodeURL, fields: [("client_id", clientID)])
        if let error = wire.error {
            throw GitHubAuthError.oauth(wire.error_description ?? error)
        }
        guard let device = wire.device_code, let user = wire.user_code,
              let uri = wire.verification_uri else {
            throw GitHubAuthError.decode("no device code in response")
        }
        return DeviceCode(deviceCode: device, userCode: user, verificationURI: uri,
                          interval: wire.interval ?? 5, expiresIn: wire.expires_in ?? 900)
    }

    /// One poll of the token endpoint while the user is at github.com/login/device.
    func pollOnce(deviceCode: String) async throws -> PollOutcome {
        let wire = try await post(Self.tokenURL, fields: [
            ("client_id", clientID),
            ("device_code", deviceCode),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ])
        switch wire.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(interval: wire.interval ?? 10)
        case "access_denied": return .denied
        case "expired_token": return .expired
        case let error?: throw GitHubAuthError.oauth(wire.error_description ?? error)
        case nil: break
        }
        return .authorized(try grant(from: wire))
    }

    /// Exchanges a refresh token for a fresh pair. Device-flow tokens refresh
    /// with the client ID alone — this is why no secret ships in the app.
    func refresh(refreshToken: String) async throws -> TokenGrant {
        guard !clientID.isEmpty else { throw GitHubAuthError.notConfigured }
        let wire = try await post(Self.tokenURL, fields: [
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
        if let error = wire.error {
            throw GitHubAuthError.oauth(wire.error_description ?? error)
        }
        return try grant(from: wire)
    }

    /// Resolves the signed-in user's login, which the billing URLs address.
    func fetchLogin(accessToken: String) async throws -> String {
        var request = URLRequest(url: Self.userURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tokes/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubAuthError.http(0) }
        guard http.statusCode == 200 else { throw GitHubAuthError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String, !login.isEmpty else {
            throw GitHubAuthError.decode("no login in /user response")
        }
        return login
    }

    // MARK: - Wire plumbing

    private func grant(from wire: TokenWire) throws -> TokenGrant {
        guard let token = wire.access_token, !token.isEmpty else {
            throw GitHubAuthError.decode("no access token in response")
        }
        return TokenGrant(accessToken: token, expiresIn: wire.expires_in,
                          refreshToken: wire.refresh_token,
                          refreshExpiresIn: wire.refresh_token_expires_in)
    }

    /// Form-encoded POST with a JSON Accept header; github.com answers OAuth
    /// errors as 200s with an `error` field, so non-200 here is transport-level.
    private func post(_ url: URL, fields: [(String, String)]) async throws -> TokenWire {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Tokes/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubAuthError.http(0) }
        guard http.statusCode == 200 else { throw GitHubAuthError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(TokenWire.self, from: data)
        } catch {
            throw GitHubAuthError.decode(error.localizedDescription)
        }
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }

    /// Union of every github.com OAuth answer Tokes reads: device-code grants,
    /// token grants, and in-band errors all come back through this one shape.
    private struct TokenWire: Decodable {
        let device_code: String?
        let user_code: String?
        let verification_uri: String?
        let expires_in: TimeInterval?
        let interval: TimeInterval?
        let access_token: String?
        let refresh_token: String?
        let refresh_token_expires_in: TimeInterval?
        let error: String?
        let error_description: String?
    }
}
