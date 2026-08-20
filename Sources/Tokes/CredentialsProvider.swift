import Foundation
import Security

/// Credential-resolution failures, with user-facing guidance.
enum CredentialError: LocalizedError, Equatable {
    case notFound
    #if !TOKES_APP_STORE
        /// Only `loadClaudeCodeToken` raises this, and that reader is not in the
        /// App Store build — so neither is the case, nor its message naming
        /// Claude Code's keychain item.
        case denied
    #endif
    case manualMissing
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code credentials found. Sign in with Claude Code, or set a token in Settings."
        #if !TOKES_APP_STORE
            case .denied:
                return "Keychain access denied. Allow access to \"Claude Code-credentials\", or set a token in Settings."
        #endif
        case .manualMissing:
            return "No token configured. Paste one in Settings."
        case .sourceUnavailable:
            return "That credential source isn't available in this build. "
                + "Import a credentials file or paste a token in Settings."
        }
    }
}

/// Resolves the OAuth access token used to call the usage endpoint.
///
/// "Auto" mode reads the credentials Claude Code maintains, trying in order:
///   1. ~/.claude/.credentials.json (no keychain prompt needed when present)
///   2. The "Claude Code-credentials" keychain item via /usr/bin/security
///      (its keychain approval survives rebuilds of an ad-hoc-signed Tokes.app)
///   3. The same keychain item via the Security framework
///
/// All three read a store Claude Code owns, so all three are compiled out of the
/// App Store build (`Capabilities.canReadForeignCredentialStores`). What remains
/// there is the imported-file path and the manual token.
final class CredentialsProvider {
    static let manualService = "com.appideas.tokes"
    static let manualAccount = "oauth-token"
    #if !TOKES_APP_STORE
        private static let claudeCodeService = "Claude Code-credentials"
    #endif

    /// The credentials file the user imported, if any; injectable for tests.
    var importedFile = ImportedCredentialFile(
        defaultsKey: SettingsKeys.claudeCredentialFile,
        describing: "Claude Code credentials")

    private var cachedToken: String?
    private var cachedExpiry: Date?

    /// Test seam: replaces credential lookup when set.
    var loadTokenOverride: (() throws -> (String, Date?))?

    private var source: CredentialSource {
        CredentialSource.current()
    }

    /// Drops the cached token so the next poll re-reads credentials.
    func invalidate() {
        cachedToken = nil
        cachedExpiry = nil
    }

    /// Returns an OAuth token, cached until 60 s before expiry. Tokens with
    /// unknown expiry are re-read every call so rotations are picked up.
    func accessToken() throws -> String {
        if let token = cachedToken {
            if let expiry = cachedExpiry, expiry.timeIntervalSinceNow > 60 {
                return token
            }
        }
        let (token, expiry): (String, Date?)
        if let load = loadTokenOverride {
            (token, expiry) = try load()
        } else {
            (token, expiry) = try loadToken()
        }
        cachedToken = token
        cachedExpiry = expiry
        return token
    }

    /// Reads a token from the configured source.
    private func loadToken() throws -> (String, Date?) {
        switch source {
        case .manual:
            guard let token = Self.readManualToken(), !token.isEmpty else {
                throw CredentialError.manualMissing
            }
            return (token, nil)
        case .importedFile:
            return try Self.loadImportedToken(from: importedFile)
        case .claudeCode:
            #if TOKES_APP_STORE
                // Unreachable: `CredentialSource.current()` normalizes this away
                // in the App Store build, and the reader itself isn't compiled in.
                throw CredentialError.sourceUnavailable
            #else
                return try Self.loadClaudeCodeToken()
            #endif
        }
    }

    /// Parses the credentials file the user picked in an open panel. Re-read on
    /// every load, so a token the owning tool rotates is picked up.
    static func loadImportedToken(from file: ImportedCredentialFile) throws -> (String, Date?) {
        let data = try file.read()
        guard let parsed = parseClaudeCredentials(data) else {
            throw ImportedFileError.unparsable(file.displayPath ?? "imported file")
        }
        return parsed
    }

    #if !TOKES_APP_STORE

    /// Reads Claude Code's token: credentials file, then security CLI, then
    /// Security framework.
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

    /// Reads the keychain item via /usr/bin/security, whose approval survives rebuilds.
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

    #endif  // !TOKES_APP_STORE

    /// Extracts the access token and expiry from Claude Code's credentials JSON.
    static func parseClaudeCredentials(_ data: Data) -> (String, Date?)? {
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

    /// Reads the manually saved token from Tokes' own keychain item.
    static func readManualToken(service: String = manualService, account: String = manualAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored manual token; returns whether the save succeeded.
    @discardableResult
    static func saveManualToken(_ token: String, service: String = manualService, account: String = manualAccount) -> Bool {
        deleteManualToken(service: service, account: account)
        guard !token.isEmpty, let data = token.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the manual token's keychain item.
    static func deleteManualToken(service: String = manualService, account: String = manualAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
