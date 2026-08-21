import XCTest

@testable import Tokes

/// Settings' "Test Connection" buttons — the app's only self-diagnostic, and
/// the first thing a new App Store user presses after importing a credentials
/// file.
///
/// The buttons themselves cannot be pressed by a test: a SwiftUI action closure
/// in a view that is never rendered into a window never runs. What is asserted
/// here is everything the press does — resolve a token from the selected
/// source, fetch once, and turn either result into the line the user reads.
/// Both take an injected `URLSession`, which is the change that made them
/// reachable at all; before it they built `UsageClient()` inline and would have
/// hit the live endpoint.
final class ClaudeConnectionTestTests: XCTestCase {
    private let suite = "com.appideas.tokes.tests.claudeconntest"
    private var defaults: UserDefaults!
    private var directory: URL!
    private var file: ImportedCredentialFile!

    private let twoLimits = #"{"limits":[{"kind":"session","percent":24},{"kind":"weekly_all","percent":8}]}"#

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        directory = TestFixtures.tempDirectory()
        file = ImportedCredentialFile(defaultsKey: "connTestBookmark",
                                      describing: "Claude Code credentials", defaults: defaults)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func respond(status: Int, body: String) {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    private func outcome(_ source: CredentialSource,
                         pasted: String = "") async -> SettingsView.TestOutcome {
        await SettingsView.claudeTestOutcome(source: source, pastedToken: pasted,
                                             file: file, session: mockSession())
    }

    private func importFile(_ body: String) throws {
        let url = directory.appendingPathComponent("creds.json")
        try Data(body.utf8).write(to: url)
        try file.store(url)
    }

    // MARK: - Success

    func testAPastedTokenReportsTheLimitCount() async {
        respond(status: 200, body: twoLimits)
        let result = await outcome(.manual, pasted: "tok-123")

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.message, "Connected — 2 limits reported")
    }

    func testThePastedTokenIsTheOneSent() async {
        var authorization: String?
        MockURLProtocol.handler = { [twoLimits] request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!, Data(twoLimits.utf8))
        }
        _ = await outcome(.manual, pasted: "tok-abc")

        // Tests the *pasted* field, not whatever is saved in the keychain —
        // pressing Test before Save has to check what is on screen.
        XCTAssertEqual(authorization, "Bearer tok-abc")
    }

    func testAnImportedFileIsReadAndUsed() async throws {
        try importFile(#"{"claudeAiOauth":{"accessToken":"file-tok"}}"#)
        var authorization: String?
        MockURLProtocol.handler = { [twoLimits] request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!, Data(twoLimits.utf8))
        }
        let result = await outcome(.importedFile)

        XCTAssertTrue(result.passed)
        XCTAssertEqual(authorization, "Bearer file-tok")
    }

    // MARK: - Failure, per source

    func testAnEmptyPastedTokenFailsBeforeAnyRequest() async {
        var requested = false
        MockURLProtocol.handler = { _ in
            requested = true
            throw URLError(.badServerResponse)
        }
        let result = await outcome(.manual, pasted: "")

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, CredentialError.manualMissing.errorDescription)
        XCTAssertFalse(requested, "no point asking the API with no token")
    }

    func testNoImportedFileSaysSoRatherThanFailingAtTheAPI() async {
        respond(status: 200, body: twoLimits)
        let result = await outcome(.importedFile)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, ImportedFileError.notImported("Claude Code credentials")
            .errorDescription)
    }

    func testAnUnusableImportedFileSaysSo() async throws {
        try importFile(#"{"not":"credentials"}"#)
        respond(status: 200, body: twoLimits)
        let result = await outcome(.importedFile)

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.message.contains("usable token"), result.message)
    }

    /// The reason someone presses this button: a token that no longer works.
    func testARejectedTokenSurfacesTheUnauthorizedGuidance() async {
        respond(status: 401, body: "")
        let result = await outcome(.manual, pasted: "expired")

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, UsageError.unauthorized.errorDescription)
    }

    func testAServerErrorSurfacesItsStatus() async {
        respond(status: 500, body: "")
        let result = await outcome(.manual, pasted: "tok")

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Usage API returned HTTP 500.")
    }

    func testBeingOfflineSurfacesFoundationsMessage() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let result = await outcome(.manual, pasted: "tok")

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.message.isEmpty)
    }

    /// The App Store build ships no Claude Code reader, so selecting it — which
    /// only a settings file carried in from the Homebrew build can do — has to
    /// say that rather than crash or hang.
    func testTheClaudeCodeSourceInTheAppStoreBuild() async throws {
        #if TOKES_APP_STORE
            let result = await outcome(.claudeCode)
            XCTAssertFalse(result.passed)
            XCTAssertEqual(result.message, CredentialError.sourceUnavailable.errorDescription)
        #else
            throw XCTSkip("the direct build reads Claude Code's own store; not a test's business")
        #endif
    }
}

final class CopilotConnectionTestTests: XCTestCase {
    private let suite = "com.appideas.tokes.tests.copilotconntest"
    private var defaults: UserDefaults!
    private var directory: URL!
    private var file: ImportedCredentialFile!

    private let quota = """
        {"quota_snapshots": {"premium_interactions":
          {"entitlement": 7000, "credits_used": 37, "percent_remaining": 99.4, "unlimited": false}}}
        """

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        directory = TestFixtures.tempDirectory()
        file = ImportedCredentialFile(defaultsKey: "copilotConnTestBookmark",
                                      describing: "Copilot config", defaults: defaults)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func respond(status: Int, body: String) {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    private func outcome(_ source: CopilotCredentialSource,
                         pasted: String = "") async -> SettingsView.TestOutcome {
        await SettingsView.copilotTestOutcome(source: source, pastedToken: pasted,
                                              file: file, session: mockSession())
    }

    /// The Copilot success line quotes the credit detail rather than a percent,
    /// because "37 of 7,000 credits used" is the thing worth confirming.
    func testSuccessQuotesTheCreditDetail() async {
        respond(status: 200, body: quota)
        let result = await outcome(.manual, pasted: "gho_x")

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.message, "Connected — 37 of 7,000 credits used")
    }

    /// A plan with no credit detail still has to produce a sentence.
    func testSuccessFallsBackToAPercentWhenThereIsNoDetail() async {
        respond(status: 200, body: #"{"quota_snapshots":{"premium_interactions":{"percent_remaining":75}}}"#)
        let result = await outcome(.manual, pasted: "gho_x")

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.message, "Connected — 25% used")
    }

    func testAnImportedConfigIsReadAndUsed() async throws {
        let url = directory.appendingPathComponent("apps.json")
        try Data(#"{"github.com:Iv1.x":{"oauth_token":"ghu_file"}}"#.utf8).write(to: url)
        try file.store(url)

        var authorization: String?
        MockURLProtocol.handler = { [quota] request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!, Data(quota.utf8))
        }
        let result = await outcome(.importedFile)

        XCTAssertTrue(result.passed)
        XCTAssertEqual(authorization, "token ghu_file")
    }

    func testAnEmptyPastedTokenFailsBeforeAnyRequest() async {
        let result = await outcome(.manual, pasted: "")
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, CopilotCredentialError.manualMissing.errorDescription)
    }

    func testARejectedTokenSurfacesTheUnauthorizedGuidance() async {
        respond(status: 401, body: "")
        let result = await outcome(.manual, pasted: "expired")

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, CopilotError.unauthorized.errorDescription)
    }

    func testNoImportedFileSaysSo() async {
        respond(status: 200, body: quota)
        let result = await outcome(.importedFile)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message,
                       ImportedFileError.notImported("Copilot config").errorDescription)
    }

    func testTheEditorSourceInTheAppStoreBuild() async throws {
        #if TOKES_APP_STORE
            let result = await outcome(.editor)
            XCTAssertFalse(result.passed)
            XCTAssertEqual(result.message, CopilotCredentialError.sourceUnavailable.errorDescription)
        #else
            throw XCTSkip("the direct build reads the plugin's own config; not a test's business")
        #endif
    }
}
