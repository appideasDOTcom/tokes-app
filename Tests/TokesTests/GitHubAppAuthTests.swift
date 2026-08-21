import XCTest

@testable import Tokes

/// The keychain slot every GitHub sign-in test uses. Same test-only service the
/// other keychain tests use; the real slot (service "com.appideas.tokes") is
/// off-limits to tests.
private let testService = "com.appideas.tokes.tests"

/// Wire-level device-flow behavior against canned github.com answers.
final class GitHubDeviceAuthTests: XCTestCase {
    private var auth: GitHubDeviceAuth!

    override func setUp() {
        super.setUp()
        auth = GitHubDeviceAuth(session: mockSession(), clientID: "test-client-id")
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func respond(_ json: String, status: Int = 200) {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
    }

    func testRequestCodeParsesTerms() async throws {
        respond("""
            {"device_code":"dc123","user_code":"ABCD-1234",
             "verification_uri":"https://github.com/login/device",
             "expires_in":899,"interval":5}
            """)
        let code = try await auth.requestCode()
        XCTAssertEqual(code.deviceCode, "dc123")
        XCTAssertEqual(code.userCode, "ABCD-1234")
        XCTAssertEqual(code.verificationURI, "https://github.com/login/device")
        XCTAssertEqual(code.interval, 5)
        XCTAssertEqual(code.expiresIn, 899)
    }

    func testRequestCodeWithoutClientIDFailsBeforeNetwork() async {
        MockURLProtocol.handler = { _ in XCTFail("no request expected"); throw URLError(.badURL) }
        let unconfigured = GitHubDeviceAuth(session: mockSession(), clientID: "")
        do {
            _ = try await unconfigured.requestCode()
            XCTFail("expected notConfigured")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testPollOutcomes() async throws {
        respond(#"{"error":"authorization_pending"}"#)
        var outcome = try await auth.pollOnce(deviceCode: "dc")
        XCTAssertEqual(outcome, .pending)

        respond(#"{"error":"slow_down","interval":10}"#)
        outcome = try await auth.pollOnce(deviceCode: "dc")
        XCTAssertEqual(outcome, .slowDown(interval: 10))

        respond(#"{"error":"access_denied"}"#)
        outcome = try await auth.pollOnce(deviceCode: "dc")
        XCTAssertEqual(outcome, .denied)

        respond(#"{"error":"expired_token"}"#)
        outcome = try await auth.pollOnce(deviceCode: "dc")
        XCTAssertEqual(outcome, .expired)

        respond("""
            {"access_token":"ghu_new","expires_in":28800,
             "refresh_token":"ghr_new","refresh_token_expires_in":15897600,
             "token_type":"bearer","scope":""}
            """)
        outcome = try await auth.pollOnce(deviceCode: "dc")
        XCTAssertEqual(outcome, .authorized(GitHubDeviceAuth.TokenGrant(
            accessToken: "ghu_new", expiresIn: 28800,
            refreshToken: "ghr_new", refreshExpiresIn: 15_897_600)))
    }

    /// A GitHub App registered with non-expiring tokens grants no expiry and
    /// no refresh token; the optional fields must survive that.
    func testAuthorizedGrantWithoutExpiryFields() async throws {
        respond(#"{"access_token":"ghu_forever","token_type":"bearer","scope":""}"#)
        let outcome = try await auth.pollOnce(deviceCode: "dc")
        XCTAssertEqual(outcome, .authorized(GitHubDeviceAuth.TokenGrant(
            accessToken: "ghu_forever", expiresIn: nil,
            refreshToken: nil, refreshExpiresIn: nil)))
    }

    func testRefreshRejectionSurfacesOAuthError() async {
        respond(#"{"error":"bad_refresh_token","error_description":"The refresh token is invalid."}"#)
        do {
            _ = try await auth.refresh(refreshToken: "ghr_dead")
            XCTFail("expected oauth error")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .oauth("The refresh token is invalid."))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFetchLoginReadsLogin() async throws {
        respond(#"{"login":"costmo","id":12345}"#)
        let login = try await auth.fetchLogin(accessToken: "ghu_x")
        XCTAssertEqual(login, "costmo")
    }

    func testTransportErrorStatusSurfacesAsHTTP() async {
        respond("oops", status: 503)
        do {
            _ = try await auth.pollOnce(deviceCode: "dc")
            XCTFail("expected http error")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .http(503))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFormBodyPercentEncodesValues() {
        let body = GitHubDeviceAuth.formBody([
            ("client_id", "abc123"),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ])
        XCTAssertEqual(String(data: body, encoding: .utf8),
                       "client_id=abc123&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code")
    }
}

/// Persistence of the token set in Tokes' own keychain item.
final class GitHubAppTokensTests: XCTestCase {
    override func tearDown() {
        GitHubAppTokens.clear(service: testService)
        super.tearDown()
    }

    func testSaveLoadRoundTripAndClear() {
        let tokens = GitHubAppTokens(accessToken: "ghu_abc",
                                     accessExpiresAt: utcDate(2026, 8, 20, 12),
                                     refreshToken: "ghr_xyz",
                                     refreshExpiresAt: utcDate(2027, 2, 20),
                                     login: "costmo")
        XCTAssertTrue(tokens.save(service: testService))
        XCTAssertEqual(GitHubAppTokens.load(service: testService), tokens)

        GitHubAppTokens.clear(service: testService)
        XCTAssertNil(GitHubAppTokens.load(service: testService))
    }

    func testAccessExpiryUsesLeeway() {
        let tokens = GitHubAppTokens(accessToken: "t",
                                     accessExpiresAt: utcDate(2026, 8, 20, 12, 0, 0),
                                     refreshToken: nil, refreshExpiresAt: nil, login: "u")
        XCTAssertFalse(tokens.accessExpired(at: utcDate(2026, 8, 20, 11, 58, 0)))
        // Inside the 60 s leeway counts as expired — the token would die
        // before a response comes back.
        XCTAssertTrue(tokens.accessExpired(at: utcDate(2026, 8, 20, 11, 59, 30)))
        XCTAssertTrue(tokens.accessExpired(at: utcDate(2026, 8, 20, 13)))
    }

    func testNoRecordedExpiryNeverExpires() {
        let tokens = GitHubAppTokens(accessToken: "t", accessExpiresAt: nil,
                                     refreshToken: nil, refreshExpiresAt: nil, login: "u")
        XCTAssertFalse(tokens.accessExpired(at: .distantFuture))
    }
}

/// The Settings sign-in state machine, driven end to end against canned wires.
@MainActor
final class GitHubConnectModelTests: XCTestCase {
    private var model: GitHubConnectModel!

    override func setUp() {
        super.setUp()
        model = GitHubConnectModel()
        model.auth = GitHubDeviceAuth(session: mockSession(), clientID: "test-client-id")
        model.keychainService = testService
        model.sleeper = { _ in }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        GitHubAppTokens.clear(service: testService)
        super.tearDown()
    }

    /// Scripted github.com: device code, then N pending answers, then the
    /// grant, then the /user login.
    private func scriptHappyPath(pendingPolls: Int) {
        var tokenCalls = 0
        MockURLProtocol.handler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!
            switch request.url!.absoluteString {
            case "https://github.com/login/device/code":
                return (ok, Data("""
                    {"device_code":"dc","user_code":"ABCD-1234",
                     "verification_uri":"https://github.com/login/device",
                     "expires_in":900,"interval":5}
                    """.utf8))
            case "https://github.com/login/oauth/access_token":
                tokenCalls += 1
                if tokenCalls <= pendingPolls {
                    return (ok, Data(#"{"error":"authorization_pending"}"#.utf8))
                }
                return (ok, Data("""
                    {"access_token":"ghu_ok","expires_in":28800,
                     "refresh_token":"ghr_ok","refresh_token_expires_in":15897600}
                    """.utf8))
            case "https://api.github.com/user":
                return (ok, Data(#"{"login":"costmo"}"#.utf8))
            default:
                XCTFail("unexpected request \(request.url!)")
                throw URLError(.badURL)
            }
        }
    }

    func testConnectHappyPathSavesTokensAndReportsLogin() async {
        scriptHappyPath(pendingPolls: 2)
        var changed = 0
        model.connect(onChange: { changed += 1 })
        await model.settle()

        XCTAssertEqual(model.phase, .connected(login: "costmo"))
        XCTAssertEqual(changed, 1)
        let stored = GitHubAppTokens.load(service: testService)
        XCTAssertEqual(stored?.accessToken, "ghu_ok")
        XCTAssertEqual(stored?.refreshToken, "ghr_ok")
        XCTAssertEqual(stored?.login, "costmo")
    }

    func testDeniedStopsWithMessageAndSavesNothing() async {
        MockURLProtocol.handler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!
            if request.url!.path.contains("device/code") {
                return (ok, Data("""
                    {"device_code":"dc","user_code":"ABCD-1234",
                     "verification_uri":"https://github.com/login/device",
                     "expires_in":900,"interval":5}
                    """.utf8))
            }
            return (ok, Data(#"{"error":"access_denied"}"#.utf8))
        }
        var changed = 0
        model.connect(onChange: { changed += 1 })
        await model.settle()

        XCTAssertEqual(model.phase, .failed("Sign-in was denied on GitHub."))
        XCTAssertEqual(changed, 0)
        XCTAssertNil(GitHubAppTokens.load(service: testService))
    }

    func testDeadlineExpiryFailsRatherThanLoopingForever() async {
        // A clock the sleeper advances: every wait moves time forward, so the
        // 900 s window runs out after a bounded number of pending polls.
        var fakeNow = utcDate(2026, 8, 20, 12)
        model.now = { fakeNow }
        model.sleeper = { fakeNow = fakeNow.addingTimeInterval($0) }
        MockURLProtocol.handler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!
            if request.url!.path.contains("device/code") {
                return (ok, Data("""
                    {"device_code":"dc","user_code":"ABCD-1234",
                     "verification_uri":"https://github.com/login/device",
                     "expires_in":900,"interval":5}
                    """.utf8))
            }
            return (ok, Data(#"{"error":"authorization_pending"}"#.utf8))
        }
        model.connect(onChange: { XCTFail("must not connect") })
        await model.settle()

        XCTAssertEqual(model.phase,
                       .failed("The code expired before it was entered — try again."))
    }

    func testDisconnectClearsStoredSession() {
        XCTAssertTrue(GitHubAppTokens(accessToken: "t", accessExpiresAt: nil,
                                      refreshToken: nil, refreshExpiresAt: nil,
                                      login: "costmo").save(service: testService))
        model.refreshConnectionState()
        XCTAssertEqual(model.phase, .connected(login: "costmo"))

        var changed = 0
        model.disconnect(onChange: { changed += 1 })
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(changed, 1)
        XCTAssertNil(GitHubAppTokens.load(service: testService))
    }
}
