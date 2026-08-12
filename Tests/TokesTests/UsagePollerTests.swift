import XCTest

@testable import Tokes

final class UsagePollerTests: XCTestCase {
    private var state: AppState!
    private var history: HistoryStore!
    private var client: MockUsageClient!
    private var credentials: MockCredentials!
    private var poller: UsagePoller!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TestFixtures.tempDirectory()
        state = AppState()
        history = HistoryStore(directory: tempDir)
        client = MockUsageClient()
        credentials = MockCredentials()
        poller = UsagePoller(state: state, history: history, client: client, credentials: credentials)
    }

    override func tearDown() {
        poller.stop()
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.refreshInterval)
        super.tearDown()
    }

    // MARK: - tick

    @MainActor
    func testTickPublishesSnapshotAndRecordsSample() async {
        let snap = TestFixtures.snapshot(percents: ["session": 24, "weekly_all": 18])
        client.results = [.success(snap)]

        await poller.tick()

        XCTAssertEqual(state.snapshot, snap)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(client.tokens, ["mock-token"])
        XCTAssertEqual(state.samples.count, 1)
        XCTAssertEqual(state.samples.last?.v, ["session": 24, "weekly_all": 18])
        XCTAssertEqual(history.samples.count, 1)
    }

    @MainActor
    func testTickRetriesOnceAfterUnauthorized() async {
        let snap = TestFixtures.snapshot(percents: ["session": 5])
        client.results = [.failure(UsageError.unauthorized), .success(snap)]

        await poller.tick()

        XCTAssertEqual(client.fetchCount, 2)
        XCTAssertEqual(credentials.invalidateCount, 1)
        XCTAssertEqual(state.snapshot, snap)
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testTickSurfacesPersistentUnauthorized() async {
        client.results = [.failure(UsageError.unauthorized), .failure(UsageError.unauthorized)]

        await poller.tick()

        XCTAssertEqual(client.fetchCount, 2)
        XCTAssertNil(state.snapshot)
        XCTAssertEqual(state.errorMessage, UsageError.unauthorized.errorDescription)
    }

    @MainActor
    func testTickSurfacesCredentialFailureWithoutFetching() async {
        credentials.error = CredentialError.notFound

        await poller.tick()

        XCTAssertEqual(client.fetchCount, 0)
        XCTAssertEqual(state.errorMessage, CredentialError.notFound.errorDescription)
    }

    @MainActor
    func testTickKeepsSnapshotAndBacksOffOnRateLimit() async {
        let old = TestFixtures.snapshot(percents: ["session": 10],
                                        fetchedAt: Date().addingTimeInterval(-600))
        state.snapshot = old
        client.results = [.failure(UsageError.http(429))]

        await poller.tick()

        XCTAssertEqual(state.errorMessage, "Usage API rate-limited — retrying automatically.")
        XCTAssertEqual(state.snapshot, old)
        XCTAssertTrue(state.samples.isEmpty)
        // Opportunistic refreshes are suppressed during the 429 backoff window.
        XCTAssertFalse(poller.refreshIfStale(olderThan: 0))
    }

    @MainActor
    func testTickSurfacesGenericErrors() async {
        client.results = [.failure(UsageError.http(500))]

        await poller.tick()

        XCTAssertEqual(state.errorMessage, "Usage API returned HTTP 500.")
    }

    @MainActor
    func testConcurrentTicksCoalesce() async {
        let snap = TestFixtures.snapshot(percents: ["session": 5])
        client.results = [.success(snap)]

        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "fetch started")
        client.gate = {
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
        }

        let first = Task { @MainActor in await self.poller.tick() }
        await fulfillment(of: [started], timeout: 2)

        await poller.tick()  // arrives while the first tick is in flight
        XCTAssertEqual(client.fetchCount, 1)

        release?.resume()
        _ = await first.value
        XCTAssertEqual(state.snapshot, snap)
    }

    // MARK: - refreshIfStale

    @MainActor
    func testRefreshIfStaleTriggersOnlyWhenStale() {
        client.results = [
            .success(TestFixtures.snapshot(percents: ["session": 1])),
            .success(TestFixtures.snapshot(percents: ["session": 2])),
        ]

        XCTAssertTrue(poller.refreshIfStale())  // no snapshot yet

        state.snapshot = TestFixtures.snapshot(percents: ["session": 1])
        XCTAssertFalse(poller.refreshIfStale(olderThan: 30))  // fresh

        state.snapshot = TestFixtures.snapshot(percents: ["session": 1],
                                               fetchedAt: Date().addingTimeInterval(-120))
        XCTAssertTrue(poller.refreshIfStale(olderThan: 30))  // stale
    }

    // MARK: - credentials & settings

    @MainActor
    func testCredentialsChangedInvalidatesAndRefreshes() async {
        let fetched = expectation(description: "fetched")
        client.onFetch = { fetched.fulfill() }
        client.results = [.success(TestFixtures.snapshot(percents: ["session": 1]))]

        poller.credentialsChanged()

        XCTAssertEqual(credentials.invalidateCount, 1)
        await fulfillment(of: [fetched], timeout: 2)
    }

    func testConfiguredIntervalFloorsSmallValues() {
        UserDefaults.standard.set(5.0, forKey: SettingsKeys.refreshInterval)
        XCTAssertEqual(poller.configuredInterval, 60)

        UserDefaults.standard.set(30.0, forKey: SettingsKeys.refreshInterval)
        XCTAssertEqual(poller.configuredInterval, 30)

        UserDefaults.standard.removeObject(forKey: SettingsKeys.refreshInterval)
        XCTAssertEqual(poller.configuredInterval, 60)
    }
}
