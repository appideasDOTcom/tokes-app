import Foundation

/// Copilot credential-resolution failures, with user-facing guidance.
enum CopilotCredentialError: LocalizedError, Equatable {
    case notFound
    case manualMissing
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Copilot credentials found. Sign in to GitHub Copilot in your editor (or `gh auth login`), or set a token in Settings."
        case .manualMissing:
            return "No GitHub token configured. Paste one in Settings."
        case .sourceUnavailable:
            return "That credential source isn't available in this build. "
                + "Import a Copilot config file or paste a token in Settings."
        }
    }
}

/// Resolves the GitHub token used to call the Copilot entitlement endpoint.
///
/// "Editor" mode reads the credentials Copilot plugins maintain, trying in order:
///   1. ~/.config/github-copilot/apps.json (current plugin versions)
///   2. ~/.config/github-copilot/hosts.json (older plugin versions)
///   3. `gh auth token` from the GitHub CLI
///
/// All three read stores another tool owns, so all three are compiled out of the
/// App Store build (`Capabilities.canReadForeignCredentialStores`). What remains
/// there is the imported-file path and the manual token.
final class CopilotCredentialsProvider: TokenProviding {
    static let manualAccount = "copilot-token"

    #if !TOKES_APP_STORE
        /// Copilot's plugin config directory; injectable for tests.
        var configDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/github-copilot")
    #endif

    /// The Copilot config file the user imported, if any; injectable for tests.
    var importedFile = ImportedCredentialFile(
        defaultsKey: SettingsKeys.copilotCredentialFile,
        describing: "Copilot config")

    private var cachedToken: String?

    /// Test seam: replaces credential lookup when set.
    var loadTokenOverride: (() throws -> String)?

    private var source: CopilotCredentialSource {
        CopilotCredentialSource.current()
    }

    /// Drops the cached token so the next poll re-reads credentials.
    func invalidate() {
        cachedToken = nil
    }

    /// Returns a GitHub token, cached until invalidated (a 401 poll invalidates
    /// and retries, picking up plugin token rotations).
    func accessToken() throws -> String {
        if let token = cachedToken { return token }
        let token: String
        if let load = loadTokenOverride {
            token = try load()
        } else {
            token = try loadToken()
        }
        cachedToken = token
        return token
    }

    /// Reads a token from the configured source.
    private func loadToken() throws -> String {
        switch source {
        case .manual:
            guard let token = CredentialsProvider.readManualToken(account: Self.manualAccount),
                  !token.isEmpty else {
                throw CopilotCredentialError.manualMissing
            }
            return token
        case .importedFile:
            return try Self.loadImportedToken(from: importedFile)
        case .editor:
            #if TOKES_APP_STORE
                // Unreachable: `CopilotCredentialSource.current()` normalizes
                // this away, and the reader itself isn't compiled in.
                throw CopilotCredentialError.sourceUnavailable
            #else
                return try loadEditorToken()
            #endif
        }
    }

    /// Parses the Copilot config file the user picked in an open panel. Re-read
    /// on every load, so a rotated token is picked up.
    static func loadImportedToken(from file: ImportedCredentialFile) throws -> String {
        let data = try file.read()
        guard let token = token(fromConfig: data) else {
            throw ImportedFileError.unparsable(file.displayPath ?? "imported file")
        }
        return token
    }

    #if !TOKES_APP_STORE

    /// Reads the plugin config files, then falls back to the gh CLI.
    func loadEditorToken() throws -> String {
        for file in ["apps.json", "hosts.json"] {
            if let data = try? Data(contentsOf: configDirectory.appendingPathComponent(file)),
               let token = Self.token(fromConfig: data) {
                return token
            }
        }
        if let token = Self.ghCLIToken() {
            return token
        }
        throw CopilotCredentialError.notFound
    }

    #endif  // !TOKES_APP_STORE

    /// Extracts the github.com oauth_token from an apps.json/hosts.json body.
    static func token(fromConfig data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // apps.json keys look like "github.com:<client-id>"; hosts.json uses "github.com".
        for key in json.keys.sorted() where key == "github.com" || key.hasPrefix("github.com:") {
            if let entry = json[key] as? [String: Any],
               let token = entry["oauth_token"] as? String, !token.isEmpty {
                return token
            }
        }
        return nil
    }

    #if !TOKES_APP_STORE

    /// Asks the GitHub CLI for its stored token, trying common install paths.
    private static func ghCLIToken() -> String? {
        let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let gh = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "token"]
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
        guard process.terminationStatus == 0,
              let token = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    #endif  // !TOKES_APP_STORE
}
