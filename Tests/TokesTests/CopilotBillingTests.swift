import XCTest

@testable import Tokes

private let testService = "com.appideas.tokes.tests"

/// A canned billing usage report row.
private func usageBody(gross: Double, netAmount: Double = 0) -> String {
    """
    {"timePeriod":{"year":2026,"month":8},"user":"costmo","usageItems":[
      {"product":"Copilot AI Credits","sku":"AI Credit","model":"GPT-5",
       "unitType":"ai-credits","pricePerUnit":0.01,
       "grossQuantity":\(gross),"grossAmount":\(gross / 100),
       "discountQuantity":\(gross),"discountAmount":\(gross / 100),
       "netQuantity":0,"netAmount":\(netAmount)}]}
    """
}

private let emptyBody = #"{"timePeriod":{"year":2026,"month":8},"user":"costmo","usageItems":[]}"#

/// The documented billing report endpoints: meter fallback, aggregation, and
/// the auth/absence answers.
final class CopilotBillingClientTests: XCTestCase {
    private var client: CopilotBillingClient!
    private var requested: [URLRequest] = []

    override func setUp() {
        super.setUp()
        client = CopilotBillingClient(session: mockSession())
        requested = []
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// Routes by meter path; records every request for header/URL assertions.
    private func respond(aiCredit: (Int, String), premium: (Int, String)) {
        MockURLProtocol.handler = { [self] request in
            requested.append(request)
            let (status, body) = request.url!.path.contains("/ai_credit/")
                ? aiCredit : premium
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    func testAICreditRowsAggregateAndStopThere() async throws {
        respond(aiCredit: (200, usageBody(gross: 412)), premium: (200, emptyBody))
        let usage = try await client.fetchMonthUsage(token: "ghu_t", login: "costmo",
                                                     now: utcDate(2026, 8, 20))
        XCTAssertEqual(usage, CopilotBillingClient.MonthUsage(
            mode: .aiCredits, grossQuantity: 412, overageAmount: 0))
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested[0].url?.absoluteString,
                       "https://api.github.com/users/costmo/settings/billing/ai_credit/usage?year=2026&month=8")
        XCTAssertEqual(requested[0].value(forHTTPHeaderField: "Authorization"), "Bearer ghu_t")
        XCTAssertEqual(requested[0].value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    /// Grandfathered annual plans still bill premium requests; an empty
    /// AI-credit report falls through to that meter.
    func testEmptyAICreditsFallBackToPremiumRequests() async throws {
        let premiumBody = """
            {"usageItems":[{"product":"Copilot","sku":"Copilot Premium Request",
             "unitType":"requests","grossQuantity":37,"netAmount":0}]}
            """
        respond(aiCredit: (200, emptyBody), premium: (200, premiumBody))
        let usage = try await client.fetchMonthUsage(token: "t", login: "costmo",
                                                     now: utcDate(2026, 8, 20))
        XCTAssertEqual(usage, CopilotBillingClient.MonthUsage(
            mode: .premiumRequests, grossQuantity: 37, overageAmount: 0))
        XCTAssertEqual(requested.count, 2)
        XCTAssertTrue(requested[1].url!.path.contains("/premium_request/"))
    }

    /// No rows on either meter — the org-provided-seat shape — is nil, not an
    /// error; the fetcher turns it into its own message.
    func testBothMetersEmptyIsNil() async throws {
        respond(aiCredit: (200, emptyBody), premium: (404, #"{"message":"Not Found"}"#))
        let usage = try await client.fetchMonthUsage(token: "t", login: "costmo",
                                                     now: utcDate(2026, 8, 20))
        XCTAssertNil(usage)
    }

    func testUnauthorizedSurfacesAsUnauthorized() async {
        respond(aiCredit: (401, #"{"message":"Bad credentials"}"#), premium: (200, emptyBody))
        do {
            _ = try await client.fetchMonthUsage(token: "t", login: "costmo",
                                                 now: utcDate(2026, 8, 20))
            XCTFail("expected unauthorized")
        } catch let error as CopilotError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

/// Scripted GitHubBillingFetching stand-in for poller dispatch tests.
final class MockGitHubFetcher: GitHubBillingFetching {
    var results: [Result<UsageLimit, Error>] = []
    private(set) var fetchCount = 0
    private(set) var invalidateCount = 0

    func fetch() async throws -> UsageLimit {
        fetchCount += 1
        guard !results.isEmpty else { throw GitHubAuthError.http(599) }
        return try results.removeFirst().get()
    }

    func invalidate() { invalidateCount += 1 }
}

/// The whole `githubApp` pipeline: stored tokens in, UsageLimit out, with
/// refresh and its persistence in between.
final class GitHubBillingFetcherTests: XCTestCase {
    private var fetcher: GitHubBillingFetcher!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var authHeaders: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "TokesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        fetcher = GitHubBillingFetcher()
        fetcher.keychainService = testService
        fetcher.defaults = defaults
        fetcher.billing = CopilotBillingClient(session: mockSession())
        fetcher.deviceAuth = GitHubDeviceAuth(session: mockSession(), clientID: "test-client-id")
        fetcher.now = { utcDate(2026, 8, 20, 12) }
        authHeaders = []
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        GitHubAppTokens.clear(service: testService)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func seedTokens(accessExpiresAt: Date?, refreshToken: String? = "ghr_seed") {
        XCTAssertTrue(GitHubAppTokens(accessToken: "ghu_seed",
                                      accessExpiresAt: accessExpiresAt,
                                      refreshToken: refreshToken,
                                      refreshExpiresAt: utcDate(2027, 1, 1),
                                      login: "costmo").save(service: testService))
    }

    /// Billing GETs answer with `billingStatus`/`billingBody`; token POSTs
    /// answer with a rotated grant.
    private func script(billingStatus: Int = 200, billingBody: String = usageBody(gross: 412)) {
        MockURLProtocol.handler = { [self] request in
            let ok = { (status: Int, body: String) in
                (HTTPURLResponse(url: request.url!, statusCode: status,
                                 httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            if request.url!.host == "github.com" {
                return ok(200, """
                    {"access_token":"ghu_rotated","expires_in":28800,
                     "refresh_token":"ghr_rotated","refresh_token_expires_in":15897600}
                    """)
            }
            authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if request.url!.path.contains("/premium_request/") {
                return ok(200, emptyBody)
            }
            return ok(billingStatus, billingBody)
        }
    }

    func testNothingStoredIsNotConnected() async {
        script()
        do {
            _ = try await fetcher.fetch()
            XCTFail("expected notConnected")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFreshTokenFetchesAndShapesAgainstPlan() async throws {
        seedTokens(accessExpiresAt: utcDate(2026, 8, 21))
        script()
        let limit = try await fetcher.fetch()

        XCTAssertEqual(limit.id, "copilot_premium")
        XCTAssertEqual(limit.label, "Copilot Credits")
        XCTAssertEqual(limit.percent, 412.0 / 1500 * 100, accuracy: 0.01)
        XCTAssertEqual(limit.detail, "412 of 1,500 AI credits used")
        XCTAssertEqual(limit.resetsAt, utcDate(2026, 9, 1))
        XCTAssertEqual(authHeaders, ["Bearer ghu_seed"])
    }

    func testPlanSettingChangesAllowance() async throws {
        defaults.set(CopilotPlan.proPlus.rawValue, forKey: SettingsKeys.copilotPlan)
        seedTokens(accessExpiresAt: utcDate(2026, 8, 21))
        script()
        let limit = try await fetcher.fetch()
        XCTAssertEqual(limit.percent, 412.0 / 7000 * 100, accuracy: 0.01)
    }

    func testCustomPlanUsesStoredAllowance() async throws {
        defaults.set(CopilotPlan.custom.rawValue, forKey: SettingsKeys.copilotPlan)
        defaults.set(824.0, forKey: SettingsKeys.copilotCustomAllowance)
        seedTokens(accessExpiresAt: utcDate(2026, 8, 21))
        script()
        let limit = try await fetcher.fetch()
        XCTAssertEqual(limit.percent, 50, accuracy: 0.01)
    }

    /// An expired access token refreshes first, and the rotated pair must be
    /// back in the keychain — a refresh rotates the refresh token, so a lost
    /// write is a lost session.
    func testExpiredAccessRefreshesAndPersistsRotation() async throws {
        seedTokens(accessExpiresAt: utcDate(2026, 8, 20, 11))
        script()
        let limit = try await fetcher.fetch()

        XCTAssertEqual(authHeaders, ["Bearer ghu_rotated"])
        XCTAssertEqual(limit.label, "Copilot Credits")
        let stored = GitHubAppTokens.load(service: testService)
        XCTAssertEqual(stored?.accessToken, "ghu_rotated")
        XCTAssertEqual(stored?.refreshToken, "ghr_rotated")
        XCTAssertEqual(stored?.login, "costmo")
    }

    /// A 401 mid-fetch (token revoked server-side before its recorded expiry)
    /// refreshes once and retries.
    func testUnauthorizedMidFetchRefreshesOnceAndRetries() async throws {
        seedTokens(accessExpiresAt: utcDate(2026, 8, 21))
        var billingCalls = 0
        MockURLProtocol.handler = { [self] request in
            let ok = { (status: Int, body: String) in
                (HTTPURLResponse(url: request.url!, statusCode: status,
                                 httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            if request.url!.host == "github.com" {
                return ok(200, #"{"access_token":"ghu_rotated","expires_in":28800,"refresh_token":"ghr_rotated"}"#)
            }
            authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            billingCalls += 1
            return billingCalls == 1 ? ok(401, "{}") : ok(200, usageBody(gross: 10))
        }
        let limit = try await fetcher.fetch()
        XCTAssertEqual(authHeaders, ["Bearer ghu_seed", "Bearer ghu_rotated"])
        XCTAssertEqual(limit.detail, "10 of 1,500 AI credits used")
    }

    /// GitHub rejecting the refresh token means the session is dead — the
    /// answer is "sign in again", not a transient error.
    func testRejectedRefreshIsNotConnected() async {
        seedTokens(accessExpiresAt: utcDate(2026, 8, 20, 11))
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"bad_refresh_token"}"#.utf8))
        }
        do {
            _ = try await fetcher.fetch()
            XCTFail("expected notConnected")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNoRowsAnywhereIsNoBillingData() async {
        seedTokens(accessExpiresAt: utcDate(2026, 8, 21))
        script(billingBody: emptyBody)
        do {
            _ = try await fetcher.fetch()
            XCTFail("expected noBillingData")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .noBillingData)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

/// The pure shaping helpers.
final class GitHubBillingShapingTests: XCTestCase {
    func testOverageShowsInDetailAndPercentClamps() {
        let usage = CopilotBillingClient.MonthUsage(mode: .aiCredits,
                                                    grossQuantity: 1612,
                                                    overageAmount: 1.12)
        let limit = GitHubBillingFetcher.limit(usage: usage, allowance: 1500,
                                               now: utcDate(2026, 8, 20))
        XCTAssertEqual(limit.percent, 100)  // clamped by UsageLimit.init
        XCTAssertEqual(limit.detail, "1,612 of 1,500 AI credits used — $1.12 overage")
    }

    func testLegacyMeterWordingAndLabel() {
        let usage = CopilotBillingClient.MonthUsage(mode: .premiumRequests,
                                                    grossQuantity: 37, overageAmount: 0)
        let limit = GitHubBillingFetcher.limit(usage: usage, allowance: 300,
                                               now: utcDate(2026, 8, 20))
        XCTAssertEqual(limit.label, "Copilot Premium")
        XCTAssertEqual(limit.detail, "37 of 300 premium requests used")
    }

    func testNextMonthResetWrapsYearEnd() {
        XCTAssertEqual(GitHubBillingFetcher.nextMonthReset(after: utcDate(2026, 8, 20, 12)),
                       utcDate(2026, 9, 1))
        XCTAssertEqual(GitHubBillingFetcher.nextMonthReset(after: utcDate(2026, 12, 31, 23, 59)),
                       utcDate(2027, 1, 1))
    }

    func testZeroAllowanceReadsZeroPercent() {
        let usage = CopilotBillingClient.MonthUsage(mode: .aiCredits,
                                                    grossQuantity: 10, overageAmount: 0)
        let limit = GitHubBillingFetcher.limit(usage: usage, allowance: 0,
                                               now: utcDate(2026, 8, 20))
        XCTAssertEqual(limit.percent, 0)
    }
}

/// The new source's model plumbing: build offerings, defaults, and plan table.
final class GitHubSourceModelTests: XCTestCase {
    func testGithubAppOfferedFirstInBothBuilds() {
        XCTAssertEqual(CopilotCredentialSource.available(for: .direct),
                       [.githubApp, .editor, .importedFile, .manual])
        XCTAssertEqual(CopilotCredentialSource.available(for: .appStore),
                       [.githubApp, .importedFile, .manual])
    }

    /// The App Store build starts on the sanctioned sign-in; the direct build
    /// keeps `.editor` so existing zero-setup installs keep working.
    func testDefaultSourcePerBuild() {
        XCTAssertEqual(CopilotCredentialSource.defaultSource(for: .appStore), .githubApp)
        XCTAssertEqual(CopilotCredentialSource.defaultSource(for: .direct), .editor)
    }

    func testGithubAppSurvivesNormalizationEverywhere() {
        XCTAssertEqual(CopilotCredentialSource.githubApp.normalized(for: .direct), .githubApp)
        XCTAssertEqual(CopilotCredentialSource.githubApp.normalized(for: .appStore), .githubApp)
    }

    func testPlanAllowanceTable() {
        XCTAssertEqual(CopilotPlan.pro.allowance(mode: .aiCredits, custom: 0), 1500)
        XCTAssertEqual(CopilotPlan.proPlus.allowance(mode: .aiCredits, custom: 0), 7000)
        XCTAssertEqual(CopilotPlan.max.allowance(mode: .aiCredits, custom: 0), 20000)
        XCTAssertEqual(CopilotPlan.pro.allowance(mode: .premiumRequests, custom: 0), 300)
        XCTAssertEqual(CopilotPlan.proPlus.allowance(mode: .premiumRequests, custom: 0), 1500)
        XCTAssertEqual(CopilotPlan.custom.allowance(mode: .aiCredits, custom: 824), 824)
        XCTAssertEqual(CopilotPlan.custom.allowance(mode: .premiumRequests, custom: 824), 824)
    }

    func testCurrentPlanFallsBackToPro() {
        let suite = "TokesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CopilotPlan.current(in: defaults), .pro)
        defaults.set("proPlus", forKey: SettingsKeys.copilotPlan)
        XCTAssertEqual(CopilotPlan.current(in: defaults), .proPlus)
    }
}

/// The poller hands the `githubApp` source to the billing pipeline and leaves
/// the legacy client alone.
final class UsagePollerGitHubDispatchTests: XCTestCase {
    private var state: AppState!
    private var history: HistoryStore!
    private var client: MockUsageClient!
    private var copilotClient: MockCopilotClient!
    private var githubFetcher: MockGitHubFetcher!
    private var poller: UsagePoller!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "TokesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(true, forKey: SettingsKeys.copilotEnabled)
        defaults.set(CopilotCredentialSource.githubApp.rawValue,
                     forKey: SettingsKeys.copilotCredentialSource)
        tempDir = TestFixtures.tempDirectory()
        state = AppState()
        history = HistoryStore(directory: tempDir)
        client = MockUsageClient()
        copilotClient = MockCopilotClient()
        githubFetcher = MockGitHubFetcher()
        poller = UsagePoller(state: state, history: history,
                             client: client, credentials: MockCredentials(),
                             copilotClient: copilotClient,
                             copilotCredentials: MockCredentials(),
                             githubFetcher: githubFetcher,
                             defaults: defaults)
    }

    override func tearDown() {
        poller.stop()
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testGithubAppSourcePollsFetcherNotLegacyClient() async {
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 5]))]
        githubFetcher.results = [.success(TestFixtures.copilotLimit(percent: 27))]

        await poller.tick()

        XCTAssertEqual(githubFetcher.fetchCount, 1)
        XCTAssertEqual(copilotClient.fetchCount, 0)
        XCTAssertEqual(state.snapshot?.limits.map(\.id), ["session", "copilot_premium"])
    }

    @MainActor
    func testFetcherFailureSurfacesItsMessage() async {
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 5]))]
        githubFetcher.results = [.failure(GitHubAuthError.notConnected)]

        await poller.tick()

        XCTAssertEqual(state.errorMessage, "Not signed in to GitHub — connect in Settings.")
        XCTAssertEqual(state.snapshot?.limits.map(\.id), ["session"])
    }

    func testCredentialsChangedInvalidatesFetcher() {
        poller.credentialsChanged()
        XCTAssertEqual(githubFetcher.invalidateCount, 1)
    }
}
