import XCTest

@testable import Tokes

final class ClaudeCredentialParsingTests: XCTestCase {
    func testParsesTokenAndExpiry() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok-123","expiresAt":4102444800000}}"#
        let parsed = CredentialsProvider.parseClaudeCredentials(Data(json.utf8))
        XCTAssertEqual(parsed?.0, "tok-123")
        XCTAssertEqual(parsed?.1?.timeIntervalSince1970 ?? 0, 4_102_444_800, accuracy: 0.001)
    }

    func testParsesTokenWithoutExpiry() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok-123"}}"#
        let parsed = CredentialsProvider.parseClaudeCredentials(Data(json.utf8))
        XCTAssertEqual(parsed?.0, "tok-123")
        XCTAssertNil(parsed?.1)
    }

    func testRejectsMissingOrEmptyToken() {
        XCTAssertNil(CredentialsProvider.parseClaudeCredentials(Data(#"{"claudeAiOauth":{}}"#.utf8)))
        XCTAssertNil(CredentialsProvider.parseClaudeCredentials(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)))
        XCTAssertNil(CredentialsProvider.parseClaudeCredentials(Data(#"{"other":true}"#.utf8)))
    }

    func testRejectsNonJSON() {
        XCTAssertNil(CredentialsProvider.parseClaudeCredentials(Data("not json".utf8)))
    }

    func testErrorDescriptionsAreUserFacing() {
        XCTAssertNotNil(CredentialError.notFound.errorDescription)
        XCTAssertNotNil(CredentialError.manualMissing.errorDescription)
        XCTAssertNotNil(CredentialError.sourceUnavailable.errorDescription)
        #if !TOKES_APP_STORE
            XCTAssertNotNil(CredentialError.denied.errorDescription)
        #endif
    }
}

final class ManualTokenKeychainTests: XCTestCase {
    // A test-only keychain item, so runs never touch the real Tokes token.
    private let service = "com.appideas.tokes.tests"
    private let account = "oauth-token-test"

    override func setUp() {
        super.setUp()
        CredentialsProvider.deleteManualToken(service: service, account: account)
    }

    override func tearDown() {
        CredentialsProvider.deleteManualToken(service: service, account: account)
        super.tearDown()
    }

    func testSaveReadOverwriteDeleteRoundTrip() {
        XCTAssertNil(CredentialsProvider.readManualToken(service: service, account: account))

        XCTAssertTrue(CredentialsProvider.saveManualToken("secret-1", service: service, account: account))
        XCTAssertEqual(CredentialsProvider.readManualToken(service: service, account: account), "secret-1")

        XCTAssertTrue(CredentialsProvider.saveManualToken("secret-2", service: service, account: account))
        XCTAssertEqual(CredentialsProvider.readManualToken(service: service, account: account), "secret-2")

        CredentialsProvider.deleteManualToken(service: service, account: account)
        XCTAssertNil(CredentialsProvider.readManualToken(service: service, account: account))
    }

    func testSavingEmptyTokenFailsAndClearsExisting() {
        CredentialsProvider.saveManualToken("secret", service: service, account: account)
        XCTAssertFalse(CredentialsProvider.saveManualToken("", service: service, account: account))
        XCTAssertNil(CredentialsProvider.readManualToken(service: service, account: account))
    }
}

/// `loadToken()` — the switch that turns the user's Settings choice into an
/// actual token. Every other suite here reaches it through `loadTokenOverride`,
/// which is checked *before* it and so leaves the dispatch itself unexercised;
/// these drive it for real, against an injected defaults domain, an injected
/// keychain slot, and a temp-directory imported file.
final class ClaudeCredentialDispatchTests: XCTestCase {
    private let suite = "com.appideas.tokes.tests.claudedispatch.\(UUID().uuidString)"
    private let service = "com.appideas.tokes.tests"
    private let account = "oauth-token-dispatch"
    private var defaults: UserDefaults!
    private var directory: URL!
    private var provider: CredentialsProvider!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        directory = TestFixtures.tempDirectory()
        CredentialsProvider.deleteManualToken(service: service, account: account)

        provider = CredentialsProvider()
        provider.defaults = defaults
        provider.manualService = service
        provider.manualAccount = account
        provider.importedFile = ImportedCredentialFile(
            defaultsKey: "dispatchBookmark", describing: "test credentials", defaults: defaults)
    }

    override func tearDown() {
        CredentialsProvider.deleteManualToken(service: service, account: account)
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func select(_ source: CredentialSource) {
        defaults.set(source.rawValue, forKey: SettingsKeys.credentialSource)
    }

    @discardableResult
    private func importFile(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("creds.json")
        try Data(body.utf8).write(to: url)
        try provider.importedFile.store(url)
        return url
    }

    private func claudeJSON(_ token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":4102444800000}}"#
    }

    // MARK: - Manual

    func testManualSourceReadsTheKeychainSlot() throws {
        select(.manual)
        CredentialsProvider.saveManualToken("pasted-token", service: service, account: account)

        XCTAssertEqual(try provider.accessToken(), "pasted-token")
    }

    func testManualSourceWithNothingSavedIsActionable() {
        select(.manual)
        XCTAssertThrowsError(try provider.accessToken()) { error in
            XCTAssertEqual(error as? CredentialError, .manualMissing)
        }
    }

    /// A manual token has no expiry, so it is re-read every call — which is
    /// what makes deleting it in Settings take effect on the next poll rather
    /// than at the next launch.
    func testManualSourceNoticesTheTokenBeingRemoved() throws {
        select(.manual)
        CredentialsProvider.saveManualToken("first", service: service, account: account)
        XCTAssertEqual(try provider.accessToken(), "first")

        CredentialsProvider.deleteManualToken(service: service, account: account)
        XCTAssertThrowsError(try provider.accessToken())
    }

    // MARK: - Imported file

    func testImportedFileSourceReadsTheImportedFile() throws {
        select(.importedFile)
        try importFile(claudeJSON("from-file"))

        XCTAssertEqual(try provider.accessToken(), "from-file")
    }

    func testImportedFileSourceWithNothingImported() {
        select(.importedFile)
        XCTAssertThrowsError(try provider.accessToken()) { error in
            XCTAssertEqual(error as? ImportedFileError, .notImported("test credentials"))
        }
    }

    func testImportedFileSourceRejectsTheWrongFile() throws {
        select(.importedFile)
        try importFile(#"{"some":"other json"}"#)

        XCTAssertThrowsError(try provider.accessToken()) { error in
            guard let error = error as? ImportedFileError else {
                return XCTFail("expected ImportedFileError, got \(error)")
            }
            XCTAssertTrue(error.errorDescription!.contains("usable token"))
        }
    }

    /// The two sources must not leak into each other: a saved manual token is
    /// not consulted while the imported file is selected, and vice versa.
    func testTheSelectedSourceIsTheOnlyOneConsulted() throws {
        CredentialsProvider.saveManualToken("keychain-token", service: service, account: account)
        try importFile(claudeJSON("file-token"))

        select(.manual)
        XCTAssertEqual(try provider.accessToken(), "keychain-token")

        provider.invalidate()
        select(.importedFile)
        XCTAssertEqual(try provider.accessToken(), "file-token")
    }

    // MARK: - A source this build does not ship

    /// Settings copied in from the Homebrew build can name `claudeCode`. The
    /// App Store build has no reader for it, and this is the path that proves
    /// the normalization in `CredentialSource.current(in:)` actually protects
    /// the resolver rather than only the Settings picker.
    func testAStoredClaudeCodeSelectionIsHandledByThisBuild() throws {
        defaults.set(CredentialSource.claudeCode.rawValue, forKey: SettingsKeys.credentialSource)
        try importFile(claudeJSON("file-token"))

        #if TOKES_APP_STORE
            XCTAssertEqual(try provider.accessToken(), "file-token",
                           "the App Store build falls back to the source it does ship")
        #else
            // The direct build honors it. The reader beyond this point touches
            // Claude Code's own store, so a test stops here deliberately.
            XCTAssertEqual(CredentialSource.current(in: defaults), .claudeCode)
        #endif
    }
}

final class TokenCachingTests: XCTestCase {
    private final class Counter {
        var value = 0
    }

    private func provider(expiry: Date?, count: Counter) -> CredentialsProvider {
        let p = CredentialsProvider()
        p.loadTokenOverride = {
            count.value += 1
            return ("token-\(count.value)", expiry)
        }
        return p
    }

    func testCachesUntilNearExpiry() throws {
        let count = Counter()
        let p = provider(expiry: Date().addingTimeInterval(3600), count: count)
        XCTAssertEqual(try p.accessToken(), "token-1")
        XCTAssertEqual(try p.accessToken(), "token-1")
        XCTAssertEqual(count.value, 1)
    }

    func testReloadsWithinSixtySecondsOfExpiry() throws {
        let count = Counter()
        let p = provider(expiry: Date().addingTimeInterval(30), count: count)
        XCTAssertEqual(try p.accessToken(), "token-1")
        XCTAssertEqual(try p.accessToken(), "token-2")
        XCTAssertEqual(count.value, 2)
    }

    func testUnknownExpiryNeverCaches() throws {
        let p = provider(expiry: nil, count: Counter())
        XCTAssertEqual(try p.accessToken(), "token-1")
        XCTAssertEqual(try p.accessToken(), "token-2")
    }

    func testInvalidateForcesReload() throws {
        let p = provider(expiry: Date().addingTimeInterval(3600), count: Counter())
        XCTAssertEqual(try p.accessToken(), "token-1")
        p.invalidate()
        XCTAssertEqual(try p.accessToken(), "token-2")
    }

    func testLoadErrorsPropagate() {
        let p = CredentialsProvider()
        p.loadTokenOverride = { throw CredentialError.notFound }
        XCTAssertThrowsError(try p.accessToken()) { error in
            XCTAssertEqual(error as? CredentialError, .notFound)
        }
    }
}
