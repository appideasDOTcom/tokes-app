import AppKit
import XCTest

@testable import Tokes

/// The timer and the two notification observers: the parts of `UsagePoller`
/// that turn a settings change or a wake into a poll.
///
/// None of this needs a real event loop tick — `defaultsChanged` and `didWake`
/// are `@objc` selectors reachable by posting the notification, and the work
/// they queue lands on the main queue, which `wait(for:)` already drains. The
/// only concession is `wakeDelay`, which the app sets to three seconds.
final class UsagePollerLifecycleTests: XCTestCase {
    private var state: AppState!
    private var history: HistoryStore!
    private var client: MockUsageClient!
    private var credentials: MockCredentials!
    private var copilotClient: MockCopilotClient!
    private var copilotCredentials: MockCredentials!
    private var poller: UsagePoller!
    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    /// Fetches land off the main actor (`claudeResult` is nonisolated), so the
    /// counter behind them is locked rather than a bare `var`.
    private let lock = NSLock()
    private var fetches = 0

    override func setUp() {
        super.setUp()
        tempDir = TestFixtures.tempDirectory()
        // A UUID in the suite name: classes run in separate processes under
        // `--parallel` but share suite files on disk, so a fixed name collides.
        suiteName = "com.appideas.tokes.tests.lifecycle.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        state = AppState()
        history = HistoryStore(directory: tempDir)
        client = MockUsageClient()
        client.onFetch = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.fetches += 1
            self.lock.unlock()
        }
        credentials = MockCredentials()
        copilotClient = MockCopilotClient()
        copilotCredentials = MockCredentials()
        copilotCredentials.token = "copilot-token"
        poller = UsagePoller(state: state, history: history,
                             client: client, credentials: credentials,
                             copilotClient: copilotClient,
                             copilotCredentials: copilotCredentials,
                             defaults: defaults)
        poller.wakeDelay = 0.01
    }

    override func tearDown() {
        poller.stop()
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeSuite(named: suiteName)
        super.tearDown()
    }

    // MARK: - helpers

    private func fetchCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return fetches
    }

    /// Lets the main queue drain and any queued poll finish. Long enough for a
    /// `DispatchQueue.main.async` hop plus the `Task { @MainActor }` inside
    /// `refreshNow`; short enough that eight of these stay imperceptible.
    private func settle(_ seconds: TimeInterval = 0.3) {
        let idle = expectation(description: "settle")
        idle.isInverted = true
        wait(for: [idle], timeout: seconds)
    }

    /// Runs `body`, then waits until at least `count` fetches have happened.
    private func expectingFetches(_ count: Int, _ body: () -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let target = fetchCount() + count
        body()
        let deadline = Date().addingTimeInterval(3)
        while fetchCount() < target, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(fetchCount(), target,
                                    "expected \(count) more poll(s)", file: file, line: line)
    }

    private func postDefaultsChange() {
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    // MARK: - start / schedule

    func testStartPollsImmediatelyAndSchedulesAtTheConfiguredInterval() {
        defaults.set(120.0, forKey: SettingsKeys.refreshInterval)

        expectingFetches(1) { poller.start() }

        let timer = poller.timer
        XCTAssertNotNil(timer, "start() must leave a live timer behind")
        XCTAssertEqual(timer?.timeInterval ?? 0, 120, accuracy: 0.001)
        XCTAssertTrue(timer?.isValid ?? false)
        // 10% tolerance lets the OS coalesce the wakeup; the app is not a clock.
        XCTAssertEqual(timer?.tolerance ?? 0, 12, accuracy: 0.001)
    }

    func testChangingTheIntervalReschedulesTheTimer() {
        expectingFetches(1) { poller.start() }
        let original = poller.timer
        XCTAssertEqual(original?.timeInterval ?? 0, 60, accuracy: 0.001)

        defaults.set(300.0, forKey: SettingsKeys.refreshInterval)
        postDefaultsChange()
        settle()

        XCTAssertEqual(poller.timer?.timeInterval ?? 0, 300, accuracy: 0.001)
        XCTAssertFalse(original === poller.timer, "a new interval needs a new timer")
        XCTAssertFalse(original?.isValid ?? true, "the replaced timer must be invalidated")
    }

    /// The false arm of `defaultsChanged`'s first `if`. Any Settings edit posts
    /// this notification, so rebuilding the timer on every one of them would
    /// reset the poll clock each time the user touched an unrelated toggle.
    func testADefaultsChangeThatLeavesTheIntervalAloneKeepsTheSameTimer() {
        expectingFetches(1) { poller.start() }
        let original = poller.timer

        defaults.set("anything", forKey: "unrelated-setting")
        postDefaultsChange()
        settle()

        XCTAssertTrue(original === poller.timer, "the timer must survive an unrelated change")
        XCTAssertTrue(original?.isValid ?? false)
    }

    /// The scheduled timer's block itself — the thing that makes the app
    /// refresh without anyone touching it. `fire()` runs the block without
    /// waiting out the interval, and leaves a repeating timer valid.
    func testTheScheduledTimerPolls() {
        expectingFetches(1) { poller.start() }

        expectingFetches(1) { poller.timer?.fire() }

        XCTAssertTrue(poller.timer?.isValid ?? false,
                      "a repeating timer must survive firing")
    }

    // MARK: - Copilot toggle

    func testEnablingCopilotPollsImmediatelyRatherThanWaitingForTheTimer() {
        expectingFetches(1) { poller.start() }
        XCTAssertEqual(copilotClient.fetchCount, 0, "Copilot is off at start")

        expectingFetches(1) {
            defaults.set(true, forKey: SettingsKeys.copilotEnabled)
            postDefaultsChange()
        }
        settle()

        XCTAssertEqual(copilotClient.fetchCount, 1,
                       "turning Copilot on must fetch it, not wait out the interval")
        XCTAssertEqual(copilotClient.tokens, ["copilot-token"])
    }

    func testDisablingCopilotPollsAgainSoItsLimitStopsBeingCarried() {
        defaults.set(true, forKey: SettingsKeys.copilotEnabled)
        expectingFetches(1) { poller.start() }
        settle()
        XCTAssertEqual(copilotClient.fetchCount, 1)

        expectingFetches(1) {
            defaults.set(false, forKey: SettingsKeys.copilotEnabled)
            postDefaultsChange()
        }
        settle()

        XCTAssertEqual(copilotClient.fetchCount, 1, "a disabled provider must not be fetched")
    }

    /// The false arm of the second `if`. A settings change that touches neither
    /// the interval nor the Copilot toggle must not poll — Settings posts this
    /// notification on every keystroke in a text field.
    func testAnUnrelatedDefaultsChangeDoesNotPoll() {
        expectingFetches(1) { poller.start() }
        settle()
        let baseline = fetchCount()

        defaults.set(MenuBarLabel.session.rawValue, forKey: SettingsKeys.menuBarLabel)
        postDefaultsChange()
        settle()

        XCTAssertEqual(fetchCount(), baseline, "an unrelated setting must not trigger a poll")
    }

    // MARK: - wake

    func testWakingFromSleepPolls() {
        expectingFetches(1) { poller.start() }

        expectingFetches(1) {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didWakeNotification, object: nil)
        }
    }

    func testAWakeAfterStopDoesNotPoll() {
        expectingFetches(1) { poller.start() }
        settle()
        poller.stop()
        let baseline = fetchCount()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil)
        settle()

        XCTAssertEqual(fetchCount(), baseline, "stop() must remove the wake observer")
    }

    // MARK: - stop / restart

    func testStopInvalidatesTheTimerAndSilencesSettingsChanges() {
        expectingFetches(1) { poller.start() }
        let original = poller.timer
        settle()
        let baseline = fetchCount()

        poller.stop()

        XCTAssertNil(poller.timer)
        XCTAssertFalse(original?.isValid ?? true)

        defaults.set(true, forKey: SettingsKeys.copilotEnabled)
        defaults.set(300.0, forKey: SettingsKeys.refreshInterval)
        postDefaultsChange()
        settle()

        XCTAssertEqual(fetchCount(), baseline, "stop() must remove the defaults observer")
        XCTAssertNil(poller.timer, "a stopped poller must not reschedule itself")
    }

    /// A second `start()` leaves one timer and one poll per wake.
    ///
    /// The audit predicted that a doubled observer registration would double
    /// every poll. Half of that is true and half is not, and the difference was
    /// only visible by trying it: `NotificationCenter` really does deliver twice
    /// to a repeated observer/selector/name (probed directly), but the second
    /// `refreshNow()` lands while the first `tick()` is still in flight, so the
    /// `inFlight` guard swallows it. This test therefore passes with or without
    /// the reset at the top of `start()` — it pins the *observable* contract,
    /// and the reset is hygiene rather than a fix.
    func testStartingTwiceLeavesOneTimerAndOnePollPerWake() {
        poller.start()
        let first = poller.timer
        poller.start()
        settle()
        let baseline = fetchCount()

        XCTAssertFalse(first === poller.timer, "the second start() replaces the timer")
        XCTAssertFalse(first?.isValid ?? true, "and invalidates the one it replaced")

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil)
        settle(0.6)

        XCTAssertEqual(fetchCount(), baseline + 1, "a wake must produce exactly one poll")

        // One stop() clears every registration for this observer, doubled or not.
        poller.stop()
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil)
        settle()
        XCTAssertEqual(fetchCount(), baseline + 1, "stop() must silence both registrations")
    }

    func testStartAfterStopWorksAgain() {
        expectingFetches(1) { poller.start() }
        poller.stop()
        XCTAssertNil(poller.timer)

        expectingFetches(1) { poller.start() }

        XCTAssertNotNil(poller.timer, "a stopped poller must be restartable")
        expectingFetches(1) {
            defaults.set(true, forKey: SettingsKeys.copilotEnabled)
            postDefaultsChange()
        }
    }
}
