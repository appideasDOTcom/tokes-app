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
        client.results = [.failure(UsageError.rateLimited(retryAfter: nil))]

        await poller.tick()

        XCTAssertEqual(state.errorMessage, "Usage API rate-limited — retrying automatically.")
        XCTAssertEqual(state.snapshot, old)
        XCTAssertTrue(state.samples.isEmpty)
        // Opportunistic refreshes are suppressed during the 429 backoff window.
        XCTAssertFalse(poller.refreshIfStale(olderThan: 0))
    }

    @MainActor
    func testTimerTicksSkipClaudeDuringBackoff() async {
        client.results = [.failure(UsageError.rateLimited(retryAfter: nil))]
        await poller.tick()
        XCTAssertEqual(client.fetchCount, 1)

        // Next tick lands inside the backoff window: no request, banner stays.
        await poller.tick()
        XCTAssertEqual(client.fetchCount, 1)
        XCTAssertEqual(state.errorMessage, "Usage API rate-limited — retrying automatically.")
    }

    @MainActor
    func testExpiredBackoffResumesPollingAndClearsIt() async {
        var clock = Date()
        poller.now = { clock }
        let snap = TestFixtures.snapshot(percents: ["session": 5])
        client.results = [.failure(UsageError.rateLimited(retryAfter: 30)), .success(snap)]

        await poller.tick()
        XCTAssertEqual(client.fetchCount, 1)

        clock = clock.addingTimeInterval(31)  // the window has passed
        await poller.tick()

        XCTAssertEqual(client.fetchCount, 2)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.snapshot, snap)
        XCTAssertTrue(poller.refreshIfStale(olderThan: 0))
    }

    /// A server answering `Retry-After: 0` used to mean no backoff at all — six
    /// ticks made six requests. The floor is what stops Tokes hammering an
    /// endpoint that is already telling it to stop.
    @MainActor
    func testZeroRetryAfterStillBacksOff() async {
        var clock = Date()
        poller.now = { clock }
        client.results = Array(repeating: .failure(UsageError.rateLimited(retryAfter: 0)), count: 6)

        for _ in 0..<5 {
            await poller.tick()
            clock = clock.addingTimeInterval(5)  // well inside the 30 s floor
        }

        XCTAssertEqual(client.fetchCount, 1, "only the first tick should reach the network")
        XCTAssertEqual(state.errorMessage, "Usage API rate-limited — retrying automatically.")
    }

    /// Consecutive 429s without a Retry-After double the window: 90 s, then
    /// 180 s. Each tick below sits just past the *previous* window and just
    /// short of the new one.
    @MainActor
    func testConsecutiveRateLimitsWidenTheWindow() async {
        var clock = Date()
        poller.now = { clock }
        client.results = Array(repeating: .failure(UsageError.rateLimited(retryAfter: nil)), count: 6)

        await poller.tick()                        // 429 #1 → 90 s window
        clock = clock.addingTimeInterval(91)
        await poller.tick()                        // 429 #2 → 180 s window
        XCTAssertEqual(client.fetchCount, 2)

        clock = clock.addingTimeInterval(91)       // past 90 s, inside 180 s
        await poller.tick()
        XCTAssertEqual(client.fetchCount, 2, "the second window is wider than the first")

        clock = clock.addingTimeInterval(91)       // now past 180 s
        await poller.tick()
        XCTAssertEqual(client.fetchCount, 3)
    }

    /// A Claude success clears the streak, so the next 429 starts at 90 s again
    /// rather than resuming the doubling where it left off.
    @MainActor
    func testSuccessResetsTheBackoffSchedule() async {
        var clock = Date()
        poller.now = { clock }
        client.results = [
            .failure(UsageError.rateLimited(retryAfter: nil)),   // → 90 s
            .failure(UsageError.rateLimited(retryAfter: nil)),   // → 180 s
            .success(TestFixtures.snapshot(percents: ["session": 5])),
            .failure(UsageError.rateLimited(retryAfter: nil)),   // → 90 s again, not 360
        ]
        await poller.tick()
        clock = clock.addingTimeInterval(91)
        await poller.tick()
        clock = clock.addingTimeInterval(181)
        await poller.tick()                        // success
        clock = clock.addingTimeInterval(1)
        await poller.tick()                        // 429 again
        XCTAssertEqual(client.fetchCount, 4)

        clock = clock.addingTimeInterval(91)       // 90 s would be over; 360 s would not
        await poller.tick()
        XCTAssertEqual(client.fetchCount, 5, "the streak restarted at 90 s after the success")
    }

    /// A tick that makes no request at all because the 429 window is still open
    /// must not re-stamp the limits it is carrying forward. This is the path
    /// where the app is least in touch with reality and most likely to claim
    /// otherwise: no error from a failed call, just silence.
    @MainActor
    func testABackedOffTickDoesNotRefreshTheTimestamp() async {
        let old = Date().addingTimeInterval(-3600)
        state.snapshot = UsageSnapshot(limits: [TestFixtures.limit(id: "session", percent: 7)],
                                       fetchedAt: old)
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
        // Name a legacy source so the injected mock pair below is what polls —
        // the App Store flavor's default is `githubApp`, a different pipeline.
        UserDefaults.standard.set(CopilotCredentialSource.manual.rawValue,
                                  forKey: SettingsKeys.copilotCredentialSource)
        defer {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.copilotEnabled)
            UserDefaults.standard.removeObject(forKey: SettingsKeys.copilotCredentialSource)
        }

        let copilot = MockCopilotClient()
        copilot.results = [.success(TestFixtures.copilotLimit(percent: 4)),
                           .success(TestFixtures.copilotLimit(percent: 5))]
        let backedOff = UsagePoller(state: state, history: history, client: client,
                                    credentials: credentials, copilotClient: copilot,
                                    copilotCredentials: MockCredentials())
        defer { backedOff.stop() }
        client.results = [.failure(UsageError.rateLimited(retryAfter: 120))]

        await backedOff.tick()   // 429 → window opens
        await backedOff.tick()   // inside the window: Claude is not called at all

        XCTAssertEqual(client.fetchCount, 1)
        XCTAssertEqual(state.snapshot?.limits.map(\.id), ["session", "copilot_premium"])
        XCTAssertEqual(state.snapshot?.fetchedAt.timeIntervalSince1970 ?? 0,
                       old.timeIntervalSince1970, accuracy: 1,
                       "the hour-old session limit still sets the snapshot's age")
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

    /// The clock is driven here because two rules gate this call and they no
    /// longer coincide in wall-clock time: staleness of the data, and the rate
    /// floor on the calls themselves. Advancing past the floor isolates the
    /// staleness rule this test is about.
    @MainActor
    func testRefreshIfStaleTriggersOnlyWhenStale() {
        var clock = Date()
        poller.now = { clock }
        client.results = [
            .success(TestFixtures.snapshot(percents: ["session": 1])),
            .success(TestFixtures.snapshot(percents: ["session": 2])),
        ]

        XCTAssertTrue(poller.refreshIfStale())  // no snapshot yet

        clock = clock.addingTimeInterval(31)
        state.snapshot = TestFixtures.snapshot(percents: ["session": 1], fetchedAt: clock)
        XCTAssertFalse(poller.refreshIfStale(olderThan: 30))  // fresh

        clock = clock.addingTimeInterval(31)
        state.snapshot = TestFixtures.snapshot(percents: ["session": 1],
                                               fetchedAt: clock.addingTimeInterval(-120))
        XCTAssertTrue(poller.refreshIfStale(olderThan: 30))  // stale
    }

    /// The regression this floor exists for. A provider stuck failing pins
    /// `fetchedAt` to its last success, so the staleness test is true forever —
    /// and the popover opens on hover, which made every brush past the menu bar
    /// a poll against an endpoint that rate-limits.
    @MainActor
    func testStaleDataDoesNotLetHoverPollWithoutLimit() {
        var clock = Date()
        poller.now = { clock }
        // An hour old, and nothing will refresh it: exactly the shape a snapshot
        // takes while one provider's credentials have expired.
        state.snapshot = TestFixtures.snapshot(percents: ["session": 1],
                                               fetchedAt: clock.addingTimeInterval(-3600))

        XCTAssertTrue(poller.refreshIfStale(olderThan: 30))

        // Six more openings inside the window — the data is still an hour old
        // every single time, and not one of them may reach the network.
        for _ in 0..<6 {
            clock = clock.addingTimeInterval(4)
            XCTAssertFalse(poller.refreshIfStale(olderThan: 30))
        }

        // Past the floor, the retry the outage is supposed to get.
        clock = clock.addingTimeInterval(7)
        XCTAssertTrue(poller.refreshIfStale(olderThan: 30))
    }

    /// The floor is measured from the last poll let through, not from the last
    /// call — a suppressed opening must not push the next retry further out.
    @MainActor
    func testSuppressedOpeningsDoNotPostponeTheNextRetry() {
        var clock = Date()
        poller.now = { clock }
        state.snapshot = TestFixtures.snapshot(percents: ["session": 1],
                                               fetchedAt: clock.addingTimeInterval(-3600))

        XCTAssertTrue(poller.refreshIfStale(olderThan: 30))
        clock = clock.addingTimeInterval(29)
        XCTAssertFalse(poller.refreshIfStale(olderThan: 30))
        clock = clock.addingTimeInterval(1)  // 30 s after the poll, not after the call
        XCTAssertTrue(poller.refreshIfStale(olderThan: 30))
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

/// The 429 backoff schedule, as a pure function. Every value a server can put
/// in a `Retry-After` header reaches this, so both ends are pinned rather than
/// only the well-behaved middle.
final class BackoffDelayTests: XCTestCase {
    private func delay(_ retryAfter: TimeInterval?, streak: Int = 1) -> TimeInterval {
        UsagePoller.backoffDelay(retryAfter: retryAfter, streak: streak)
    }

    func testAbsentHeaderDoublesFromNinetySecondsAndCaps() {
        XCTAssertEqual(delay(nil, streak: 1), 90)
        XCTAssertEqual(delay(nil, streak: 2), 180)
        XCTAssertEqual(delay(nil, streak: 3), 360)
        XCTAssertEqual(delay(nil, streak: 4), 720)
        XCTAssertEqual(delay(nil, streak: 5), 900)    // capped, not 1440
        XCTAssertEqual(delay(nil, streak: 50), 900)
    }

    func testAServerSuppliedDelayIsHonoredWithinTheBounds() {
        XCTAssertEqual(delay(30), 30)
        XCTAssertEqual(delay(45), 45)
        XCTAssertEqual(delay(600), 600)
        XCTAssertEqual(delay(900), 900)
    }

    /// `Retry-After: 0` and a past HTTP-date (which parses to a non-positive
    /// number) would otherwise leave no backoff at all.
    func testNonPositiveDelaysAreFlooredRatherThanIgnored() {
        XCTAssertEqual(delay(0), 30)
        XCTAssertEqual(delay(-1), 30)
        XCTAssertEqual(delay(-100_000), 30)
    }

    /// An absurd value would park Claude polling for the life of the process.
    func testHugeDelaysAreCapped() {
        XCTAssertEqual(delay(901), 900)
        XCTAssertEqual(delay(1e9), 900)
    }

    /// The streak is 1-based; a defensive 0 must not produce a negative
    /// exponent and a sub-90 s window.
    func testStreakBelowOneIsTreatedAsTheFirst() {
        XCTAssertEqual(delay(nil, streak: 0), 90)
    }
}
