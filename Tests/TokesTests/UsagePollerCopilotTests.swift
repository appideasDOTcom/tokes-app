import XCTest

@testable import Tokes

/// Dual-source poller behavior with Copilot monitoring enabled.
final class UsagePollerCopilotTests: XCTestCase {
    private var state: AppState!
    private var history: HistoryStore!
    private var client: MockUsageClient!
    private var credentials: MockCredentials!
    private var copilotClient: MockCopilotClient!
    private var copilotCredentials: MockCredentials!
    private var poller: UsagePoller!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TestFixtures.tempDirectory()
        state = AppState()
        history = HistoryStore(directory: tempDir)
        client = MockUsageClient()
        credentials = MockCredentials()
        copilotClient = MockCopilotClient()
        copilotCredentials = MockCredentials()
        copilotCredentials.token = "copilot-token"
        poller = UsagePoller(state: state, history: history,
                             client: client, credentials: credentials,
                             copilotClient: copilotClient, copilotCredentials: copilotCredentials)
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
    }

    override func tearDown() {
        poller.stop()
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.copilotEnabled)
        super.tearDown()
    }

    @MainActor
    func testTickMergesCopilotAfterClaudeLimits() async {
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 24, "weekly_all": 18]))]
        copilotClient.results = [.success(TestFixtures.copilotLimit(percent: 12))]

        await poller.tick()

        XCTAssertEqual(state.snapshot?.limits.map(\.id),
                       ["session", "weekly_all", "copilot_premium"])
        XCTAssertEqual(state.snapshot?.limits.last?.provider, .copilot)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(copilotClient.tokens, ["copilot-token"])
        XCTAssertEqual(state.samples.last?.v,
                       ["session": 24, "weekly_all": 18, "copilot_premium": 12])
    }

    @MainActor
    func testCopilotDisabledSkipsFetch() async {
        UserDefaults.standard.set(false, forKey: SettingsKeys.copilotEnabled)
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 1]))]

        await poller.tick()

        XCTAssertEqual(copilotClient.fetchCount, 0)
        XCTAssertEqual(state.snapshot?.limits.map(\.id), ["session"])
    }

    @MainActor
    func testCopilotFailureKeepsClaudeAndSurfacesError() async {
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 1]))]
        copilotClient.results = [.failure(CopilotError.http(500))]

        await poller.tick()

        XCTAssertEqual(state.snapshot?.limits.map(\.id), ["session"])
        XCTAssertEqual(state.errorMessage, "Copilot API returned HTTP 500.")
        XCTAssertEqual(state.samples.last?.v, ["session": 1])
    }

    @MainActor
    func testCopilotFailureCarriesForwardPreviousLimit() async {
        let oldCopilot = TestFixtures.copilotLimit(percent: 9)
        state.snapshot = UsageSnapshot(
            limits: [TestFixtures.limit(id: "session", percent: 3), oldCopilot],
            fetchedAt: Date().addingTimeInterval(-300))
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 4]))]
        copilotClient.results = [.failure(CopilotError.http(502))]

        await poller.tick()

        XCTAssertEqual(state.snapshot?.limits.map(\.id), ["session", "copilot_premium"])
        // Stale Copilot value stays visible…
        XCTAssertEqual(state.snapshot?.limits.last, oldCopilot)
        // …but is not recorded as a fresh history sample.
        XCTAssertEqual(state.samples.last?.v, ["session": 4])
        XCTAssertEqual(state.errorMessage, "Copilot API returned HTTP 502.")
    }

    @MainActor
    func testClaudeFailureCarriesForwardClaudeLimits() async {
        let oldClaude = TestFixtures.limit(id: "session", percent: 7)
        state.snapshot = UsageSnapshot(limits: [oldClaude],
                                       fetchedAt: Date().addingTimeInterval(-300))
        client.results = [.failure(UsageError.http(500))]
        copilotClient.results = [.success(TestFixtures.copilotLimit(percent: 11))]

        await poller.tick()

        XCTAssertEqual(state.snapshot?.limits.map(\.id), ["session", "copilot_premium"])
        XCTAssertEqual(state.snapshot?.limits.first, oldClaude)
        XCTAssertEqual(state.samples.last?.v, ["copilot_premium": 11])
        XCTAssertEqual(state.errorMessage, "Usage API returned HTTP 500.")
    }

    @MainActor
    func testBothFailingKeepsOldSnapshotAndJoinsErrors() async {
        let old = UsageSnapshot(limits: [TestFixtures.limit(id: "session", percent: 7)],
                                fetchedAt: Date().addingTimeInterval(-300))
        state.snapshot = old
        client.results = [.failure(UsageError.http(500))]
        copilotClient.results = [.failure(CopilotError.http(502))]

        await poller.tick()

        XCTAssertEqual(state.snapshot, old)
        XCTAssertTrue(state.samples.isEmpty)
        XCTAssertEqual(state.errorMessage,
                       "Usage API returned HTTP 500.\nCopilot API returned HTTP 502.")
    }

    @MainActor
    func testCopilotUnauthorizedRetriesOnce() async {
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 1]))]
        copilotClient.results = [.failure(CopilotError.unauthorized),
                                 .success(TestFixtures.copilotLimit(percent: 2))]

        await poller.tick()

        XCTAssertEqual(copilotClient.fetchCount, 2)
        XCTAssertEqual(copilotCredentials.invalidateCount, 1)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.snapshot?.limits.map(\.id), ["session", "copilot_premium"])
    }

    @MainActor
    func testCopilotCredentialFailureShortCircuits() async {
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 1]))]
        copilotCredentials.error = CopilotCredentialError.notFound

        await poller.tick()

        XCTAssertEqual(copilotClient.fetchCount, 0)
        XCTAssertEqual(state.snapshot?.limits.map(\.id), ["session"])
        XCTAssertEqual(state.errorMessage, CopilotCredentialError.notFound.errorDescription)
    }

    @MainActor
    func testCredentialsChangedInvalidatesBothProviders() {
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 1]))]
        copilotClient.results = [.success(TestFixtures.copilotLimit())]

        poller.credentialsChanged()

        XCTAssertEqual(credentials.invalidateCount, 1)
        XCTAssertEqual(copilotCredentials.invalidateCount, 1)
    }
}
