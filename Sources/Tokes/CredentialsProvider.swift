import Foundation
import Security

enum CredentialError: LocalizedError {
    case notFound
    case denied
    case manualMissing

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code credentials found. Sign in with Claude Code, or set a token in Settings."
        case .denied:
            return "Keychain access denied. Allow access to \"Claude Code-credentials\", or set a token in Settings."
        case .manualMissing:
            return "No token configured. Paste one in Settings."
        }
    }
}

/// Resolves the OAuth access token used to call the usage endpoint.
///
/// "Auto" mode reads the credentials Claude Code maintains, trying in order:
///   1. ~/.claude/.credentials.json (no keychain prompt needed when present)
///   2. The "Claude Code-credentials" keychain item via the Security framework
///   3. /usr/bin/security as a fallback (its keychain approval survives
///      rebuilds of an ad-hoc-signed Tokes.app)
final class CredentialsProvider {
    static let manualService = "com.appideas.tokes"
    static let manualAccount = "oauth-token"
    private static let claudeCodeService = "Claude Code-credentials"

    private var cachedToken: String?
    private var cachedExpiry: Date?

    private var source: CredentialSource {
        CredentialSource(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.credentialSource) ?? "") ?? .claudeCode
    }

    func invalidate() {
        cachedToken = nil
        cachedExpiry = nil
    }

    func accessToken() throws -> String {
        if let token = cachedToken {
            // Reuse until 60s before expiry; unknown expiry gets no caching so
            // a refresh by Claude Code is picked up on the next poll.
            if let expiry = cachedExpiry, expiry.timeIntervalSinceNow > 60 {
                return token
            }
        }
        let (token, expiry) = try loadToken()
        cachedToken = token
        cachedExpiry = expiry
        return token
    }

    private func loadToken() throws -> (String, Date?) {
        switch source {
        case .manual:
            guard let token = Self.readManualToken(), !token.isEmpty else {
                throw CredentialError.manualMissing
            }
            return (token, nil)
        case .claudeCode:
            return try Self.loadClaudeCodeToken()
        }
    }

    static func loadClaudeCodeToken() throws -> (String, Date?) {
        if let data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")),
           let parsed = parseClaudeCredentials(data) {
            return parsed
        }

        // Prefer the security CLI: its keychain approval sticks to
        // /usr/bin/security, so it survives rebuilds of an ad-hoc-signed app,
        // while a direct SecItemCopyMatching re-prompts after every rebuild.
        if let parsed = securityCLIFallback() {
            return parsed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let parsed = parseClaudeCredentials(data) {
            return parsed
        }
        let denied = status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed
        throw denied ? CredentialError.denied : CredentialError.notFound
    }

    private static func securityCLIFallback() -> (String, Date?)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", claudeCodeService, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parseClaudeCredentials(data)
    }

    private static func parseClaudeCredentials(_ data: Data) -> (String, Date?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        var expiry: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expiry = Date(timeIntervalSince1970: ms / 1000)
        }
        return (token, expiry)
    }

    // MARK: - Manual token storage (Tokes' own keychain item)

    static func readManualToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualService,
            kSecAttrAccount as String: manualAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveManualToken(_ token: String) -> Bool {
        deleteManualToken()
        guard !token.isEmpty, let data = token.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualService,
            kSecAttrAccount as String: manualAccount,
            kSecValueData as String: data,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func deleteManualToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualService,
            kSecAttrAccount as String: manualAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
