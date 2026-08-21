import XCTest

@testable import Tokes

/// Parsing of Copilot plugin config files (apps.json / hosts.json).
final class CopilotConfigParsingTests: XCTestCase {
    func testParsesAppsJsonStyleKey() {
        let data = Data("""
            {"github.com:Iv1.abc123": {"user": "someone", "oauth_token": "ghu_apps"}}
            """.utf8)
        XCTAssertEqual(CopilotCredentialsProvider.token(fromConfig: data), "ghu_apps")
    }

    func testParsesHostsJsonStyleKey() {
        let data = Data("""
            {"github.com": {"user": "someone", "oauth_token": "gho_hosts"}}
            """.utf8)
        XCTAssertEqual(CopilotCredentialsProvider.token(fromConfig: data), "gho_hosts")
    }

    func testIgnoresNonGitHubKeys() {
        let data = Data("""
            {"ghe.example.com": {"oauth_token": "ghe_token"}}
            """.utf8)
        XCTAssertNil(CopilotCredentialsProvider.token(fromConfig: data))
    }

    func testEmptyTokenReturnsNil() {
        let data = Data("{\"github.com\": {\"oauth_token\": \"\"}}".utf8)
        XCTAssertNil(CopilotCredentialsProvider.token(fromConfig: data))
    }

    func testNonJSONReturnsNil() {
        XCTAssertNil(CopilotCredentialsProvider.token(fromConfig: Data("nope".utf8)))
    }

    func testErrorDescriptions() {
        XCTAssertTrue(CopilotCredentialError.notFound.errorDescription!.contains("No Copilot credentials"))
        XCTAssertTrue(CopilotCredentialError.manualMissing.errorDescription!.contains("No GitHub token"))
        XCTAssertNotNil(CopilotCredentialError.sourceUnavailable.errorDescription)
    }
}

#if !TOKES_APP_STORE

/// File-lookup order within a (temp) Copilot config directory. The editor reader
/// is compiled out of the App Store build, so this suite is too — that this file
/// stops compiling under `-DTOKES_APP_STORE` without the guard is the point.
final class CopilotEditorTokenLookupTests: XCTestCase {
    private var configDir: URL!
    private var provider: CopilotCredentialsProvider!

    override func setUp() {
        super.setUp()
        configDir = TestFixtures.tempDirectory()
        provider = CopilotCredentialsProvider()
        provider.configDirectory = configDir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configDir)
        super.tearDown()
    }

    private func write(_ name: String, token: String) throws {
        let body = "{\"github.com:Iv1.x\": {\"oauth_token\": \"\(token)\"}}"
        try Data(body.utf8).write(to: configDir.appendingPathComponent(name))
    }

    func testPrefersAppsJsonOverHostsJson() throws {
        try write("apps.json", token: "from-apps")
        try write("hosts.json", token: "from-hosts")
        XCTAssertEqual(try provider.loadEditorToken(), "from-apps")
    }

    func testFallsBackToHostsJson() throws {
        try write("hosts.json", token: "from-hosts")
        XCTAssertEqual(try provider.loadEditorToken(), "from-hosts")
    }

    func testCorruptAppsJsonFallsThrough() throws {
        try Data("garbage".utf8).write(to: configDir.appendingPathComponent("apps.json"))
        try write("hosts.json", token: "from-hosts")
        XCTAssertEqual(try provider.loadEditorToken(), "from-hosts")
    }
}

#endif  // !TOKES_APP_STORE

/// The Copilot half of `loadToken()`'s source dispatch — see
/// `ClaudeCredentialDispatchTests` for why the `loadTokenOverride` suites do
/// not reach it.
final class CopilotCredentialDispatchTests: XCTestCase {
    private let suite = "com.appideas.tokes.tests.copilotdispatch.\(UUID().uuidString)"
    private let service = "com.appideas.tokes.tests"
    private let account = "copilot-token-dispatch"
    private var defaults: UserDefaults!
    private var directory: URL!
    private var provider: CopilotCredentialsProvider!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        directory = TestFixtures.tempDirectory()
        CredentialsProvider.deleteManualToken(service: service, account: account)

        provider = CopilotCredentialsProvider()
        provider.defaults = defaults
        provider.manualService = service
        provider.manualAccount = account
        provider.importedFile = ImportedCredentialFile(
            defaultsKey: "copilotDispatchBookmark", describing: "Copilot config", defaults: defaults)
    }

    override func tearDown() {
        CredentialsProvider.deleteManualToken(service: service, account: account)
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func select(_ source: CopilotCredentialSource) {
        defaults.set(source.rawValue, forKey: SettingsKeys.copilotCredentialSource)
    }

    private func importFile(_ body: String) throws {
        let url = directory.appendingPathComponent("apps.json")
        try Data(body.utf8).write(to: url)
        try provider.importedFile.store(url)
    }

    func testManualSourceReadsTheCopilotKeychainSlot() throws {
        select(.manual)
        CredentialsProvider.saveManualToken("gh-pasted", service: service, account: account)

        XCTAssertEqual(try provider.accessToken(), "gh-pasted")
    }

    /// The two providers share a keychain service and differ only by account,
    /// so a Claude token must not satisfy a Copilot lookup.
    func testTheClaudeTokenDoesNotSatisfyCopilot() {
        select(.manual)
        CredentialsProvider.saveManualToken("claude-token", service: service,
                                            account: "oauth-token-dispatch")
        defer {
            CredentialsProvider.deleteManualToken(service: service, account: "oauth-token-dispatch")
        }

        XCTAssertThrowsError(try provider.accessToken()) { error in
            XCTAssertEqual(error as? CopilotCredentialError, .manualMissing)
        }
    }

    func testManualSourceWithNothingSavedIsActionable() {
        select(.manual)
        XCTAssertThrowsError(try provider.accessToken()) { error in
            XCTAssertEqual(error as? CopilotCredentialError, .manualMissing)
        }
    }

    func testImportedFileSourceReadsTheImportedConfig() throws {
        select(.importedFile)
        try importFile(#"{"github.com:Iv1.x":{"oauth_token":"ghu_imported"}}"#)

        XCTAssertEqual(try provider.accessToken(), "ghu_imported")
    }

    func testImportedFileSourceWithNothingImported() {
        select(.importedFile)
        XCTAssertThrowsError(try provider.accessToken()) { error in
            XCTAssertEqual(error as? ImportedFileError, .notImported("Copilot config"))
        }
    }

    func testImportedFileSourceRejectsTheWrongFile() throws {
        select(.importedFile)
        try importFile(#"{"claudeAiOauth":{"accessToken":"wrong-tool"}}"#)

        XCTAssertThrowsError(try provider.accessToken()) { error in
            guard let error = error as? ImportedFileError else {
                return XCTFail("expected ImportedFileError, got \(error)")
            }
            XCTAssertTrue(error.errorDescription!.contains("usable token"))
        }
    }

    /// The equivalent of the Claude `claudeCode` case: an `editor` selection
    /// carried in from the Homebrew build.
    func testAStoredEditorSelectionIsHandledByThisBuild() throws {
        defaults.set(CopilotCredentialSource.editor.rawValue,
                     forKey: SettingsKeys.copilotCredentialSource)
        try importFile(#"{"github.com":{"oauth_token":"gho_imported"}}"#)

        #if TOKES_APP_STORE
            // `editor` normalizes to the sanctioned GitHub sign-in, whose
            // pipeline lives in GitHubBillingFetcher — the poller dispatches
            // there before this provider, so reaching it is an error, not a
            // fallback to the imported file.
            XCTAssertEqual(CopilotCredentialSource.current(in: defaults), .githubApp)
            XCTAssertThrowsError(try provider.accessToken()) { error in
                XCTAssertEqual(error as? CopilotCredentialError, .sourceUnavailable)
            }
        #else
            XCTAssertEqual(CopilotCredentialSource.current(in: defaults), .editor)
        #endif
    }
}

private final class Counter {
    var value = 0
}

/// Token caching semantics via the loadTokenOverride seam.
final class CopilotTokenCachingTests: XCTestCase {
    func testCachesUntilInvalidated() throws {
        let provider = CopilotCredentialsProvider()
        let loads = Counter()
        provider.loadTokenOverride = {
            loads.value += 1
            return "token-\(loads.value)"
        }

        XCTAssertEqual(try provider.accessToken(), "token-1")
        XCTAssertEqual(try provider.accessToken(), "token-1")
        XCTAssertEqual(loads.value, 1)

        provider.invalidate()
        XCTAssertEqual(try provider.accessToken(), "token-2")
        XCTAssertEqual(loads.value, 2)
    }

    func testLoadErrorsPropagate() {
        let provider = CopilotCredentialsProvider()
        provider.loadTokenOverride = { throw CopilotCredentialError.notFound }

        XCTAssertThrowsError(try provider.accessToken()) { error in
            XCTAssertEqual(error as? CopilotCredentialError, .notFound)
        }
    }
}
