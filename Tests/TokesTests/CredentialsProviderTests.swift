import XCTest

@testable import Tokes

final class ClaudeCredentialParsingTests: XCTestCase {
    func testParsesTokenAndExpiry() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok-123","expiresAt":1786600000000}}"#
        let parsed = CredentialsProvider.parseClaudeCredentials(Data(json.utf8))
        XCTAssertEqual(parsed?.0, "tok-123")
        XCTAssertEqual(parsed?.1?.timeIntervalSince1970 ?? 0, 1_786_600_000, accuracy: 0.001)
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
