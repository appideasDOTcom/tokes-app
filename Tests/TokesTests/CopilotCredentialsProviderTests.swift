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
