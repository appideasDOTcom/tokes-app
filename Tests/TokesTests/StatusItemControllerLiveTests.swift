import AppKit
import XCTest

@testable import Tokes

/// StatusItemController against a real NSStatusItem: init wiring, the state
/// and defaults subscriptions redrawing the actual button, hover scheduling,
/// and the context menu's wiring.
///
/// Deliberately out of bounds, because each would raise a window or steal
/// focus from a parallel session: showing the popover, statusButtonClicked
/// (activates the app), openSettings (orders a window front), and the
/// click monitors (need real out-of-process events).
final class StatusItemControllerLiveTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDir: URL!
    private var state: AppState!
    private var client: MockUsageClient!
    private var poller: UsagePoller!
    private var controller: StatusItemController?

    override func setUp() {
        super.setUp()
        suiteName = "com.appideas.tokes.tests.statusitem.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = TestFixtures.tempDirectory()
        state = AppState()
        client = MockUsageClient()
        poller = UsagePoller(state: state, history: HistoryStore(directory: tempDir),
                             client: client, credentials: MockCredentials(),
                             copilotClient: MockCopilotClient(),
                             copilotCredentials: MockCredentials(),
                             defaults: defaults)
    }

    override func tearDown() {
        if let controller { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        controller = nil
        poller.stop()
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeSuite(named: suiteName)
        for key in [SettingsKeys.menuBarLabel, SettingsKeys.showScopedWeekly] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    /// Builds the controller, skipping when the environment has no window
    /// server to hand out a status item button (headless CI).
    private func makeController() throws -> StatusItemController {
        let c = StatusItemController(state: state, poller: poller)
        controller = c
        try XCTSkipUnless(c.statusItem.button != nil,
                          "no status item button in this environment")
        return c
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins the main run loop until `condition` holds, up to two seconds.
    private func settle(_ condition: () -> Bool) -> Bool {
        for _ in 0..<40 {
            if condition() { return true }
            spin(0.05)
        }
        return condition()
    }

    private func publishSnapshot() {
        state.snapshot = UsageSnapshot(limits: [
            TestFixtures.limit(id: "session", label: "Session (5 hr)", percent: 24, isSession: true),
            TestFixtures.limit(id: "weekly_all", label: "Weekly (7 day)", percent: 18),
            TestFixtures.limit(id: "weekly_scoped:Fable", label: "Weekly Fable", percent: 19),
        ], fetchedAt: Date())
    }

    // MARK: - Wiring

    func testInitWiresTheButtonActionAndTrackingArea() throws {
        let c = try makeController()
        let button = c.statusItem.button!
        XCTAssertTrue(button.target === c)
        XCTAssertEqual(button.action, NSSelectorFromString("statusButtonClicked"))
        XCTAssertTrue(button.trackingAreas.contains { $0.owner === c })
    }

    /// Regression pin for the NSObject-owner selector trap: Swift would export
    /// these as mouseEnteredWith:/mouseExitedWith: without the explicit @objc
    /// names, and the tracking area's messages would be dropped silently.
    func testHoverHandlersExportUnderTheSelectorsTheTrackingAreaSends() {
        XCTAssertTrue(StatusItemController.instancesRespond(to: NSSelectorFromString("mouseEntered:")))
        XCTAssertTrue(StatusItemController.instancesRespond(to: NSSelectorFromString("mouseExited:")))
        XCTAssertFalse(StatusItemController.instancesRespond(to: NSSelectorFromString("mouseEnteredWith:")))
    }

    // MARK: - The subscriptions redraw the real button

    func testASnapshotRedrawsTheButtonTitleAndToolTip() throws {
        UserDefaults.standard.set(MenuBarLabel.session.rawValue, forKey: SettingsKeys.menuBarLabel)
        let c = try makeController()
        let button = c.statusItem.button!
        XCTAssertEqual(button.toolTip, "Tokes — waiting for usage data")

        publishSnapshot()
        XCTAssertTrue(settle { button.toolTip?.contains("Session (5 hr): 24%") == true })
        XCTAssertTrue(button.toolTip?.hasPrefix("Claude usage — ") == true)
        XCTAssertEqual(button.attributedTitle.string, " 24%")
    }

    func testAPollErrorTurnsTheTitleOrange() throws {
        UserDefaults.standard.set(MenuBarLabel.session.rawValue, forKey: SettingsKeys.menuBarLabel)
        let c = try makeController()
        let button = c.statusItem.button!
        publishSnapshot()
        _ = settle { button.attributedTitle.string == " 24%" }
        var color = button.attributedTitle.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .labelColor)

        state.errorMessage = "usage API down"
        XCTAssertTrue(settle {
            (button.attributedTitle.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor)
                == .systemOrange
        })
        color = button.attributedTitle.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .systemOrange)
    }

    /// Changing a default redraws without a new snapshot: the scoped weekly
    /// bucket leaves the tooltip and the icon gives up its third track.
    func testTheDefaultsSubscriptionRedrawsTheButton() throws {
        let c = try makeController()
        let button = c.statusItem.button!
        publishSnapshot()
        XCTAssertTrue(settle { button.toolTip?.contains("Weekly Fable: 19%") == true })
        let threeTrackWidth = button.image!.size.width

        UserDefaults.standard.set(false, forKey: SettingsKeys.showScopedWeekly)
        XCTAssertTrue(settle { button.toolTip?.contains("Weekly Fable") == false })
        XCTAssertLessThan(button.image!.size.width, threeTrackWidth)
    }

    // MARK: - Hover scheduling stays off-screen

    func testHoverInThenOutNeverShowsAPopover() throws {
        let c = try makeController()
        func popoverWindows() -> Int {
            NSApp.windows.filter { $0.className.contains("Popover") && $0.isVisible }.count
        }
        XCTAssertEqual(popoverWindows(), 0)
        c.mouseEntered(with: NSEvent())
        c.mouseExited(with: NSEvent())
        // Sampled continuously across both the cancelled 0.15s show and the
        // 0.4s hide: a popover that flashed open and was closed again by the
        // hide pass would slip past a single check at the end.
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            spin(0.05)
            XCTAssertEqual(popoverWindows(), 0)
        }
    }

    // MARK: - Context menu

    func testTheContextMenuIsWiredToTheRealActions() throws {
        let c = try makeController()
        let menu = c.contextMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Refresh Now", "Settings…", "", "Quit Tokes"])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertTrue(menu.items[0].target === c)
        XCTAssertTrue(menu.items[1].target === c)
        XCTAssertEqual(menu.items[1].action, NSSelectorFromString("settingsAction"))
        XCTAssertEqual(menu.items[1].keyEquivalent, ",")
        XCTAssertEqual(menu.items[3].action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(menu.items[3].keyEquivalent, "q")
    }

    func testRefreshNowInTheMenuActuallyPolls() throws {
        let c = try makeController()
        let menu = c.contextMenu()
        menu.performActionForItem(at: 0)
        XCTAssertTrue(settle { self.client.fetchCount == 1 })
    }

    // MARK: - Pure geometry and click decisions

    func testPopoverFrameSitsCenteredUnderTheStatusItem() {
        let frame = StatusItemController.popoverFrame(
            current: NSRect(x: 0, y: 0, width: 300, height: 400),
            buttonWindowFrame: NSRect(x: 850, y: 975, width: 30, height: 25),
            screenFrame: NSRect(x: 0, y: 0, width: 1800, height: 1000),
            visibleFrame: NSRect(x: 0, y: 0, width: 1800, height: 975))
        XCTAssertEqual(frame.origin.x, 850 + 15 - 150)
        XCTAssertEqual(frame.origin.y, 975 - 400)
    }

    func testPopoverFrameClampsToTheLeftScreenEdge() {
        let frame = StatusItemController.popoverFrame(
            current: NSRect(x: 0, y: 0, width: 300, height: 400),
            buttonWindowFrame: NSRect(x: 10, y: 975, width: 30, height: 25),
            screenFrame: NSRect(x: 0, y: 0, width: 1800, height: 1000),
            visibleFrame: NSRect(x: 0, y: 0, width: 1800, height: 975))
        XCTAssertEqual(frame.origin.x, 8)
    }

    func testPopoverFrameClampsToTheRightScreenEdge() {
        let frame = StatusItemController.popoverFrame(
            current: NSRect(x: 0, y: 0, width: 300, height: 400),
            buttonWindowFrame: NSRect(x: 1770, y: 975, width: 30, height: 25),
            screenFrame: NSRect(x: 0, y: 0, width: 1800, height: 1000),
            visibleFrame: NSRect(x: 0, y: 0, width: 1800, height: 975))
        XCTAssertEqual(frame.origin.x, 1800 - 300 - 8)
    }

    func testOutsideClickDecision() {
        // Never shown; isReleasedWhenClosed defaults to true, so closing (or
        // ARC releasing a closed one) would over-release and crash.
        let a = NSWindow(), b = NSWindow(), other = NSWindow()
        for w in [a, b, other] { w.isReleasedWhenClosed = false }
        XCTAssertFalse(StatusItemController.isOutsideClick(eventWindow: a, popoverWindow: a, statusWindow: b))
        XCTAssertFalse(StatusItemController.isOutsideClick(eventWindow: b, popoverWindow: a, statusWindow: b))
        XCTAssertTrue(StatusItemController.isOutsideClick(eventWindow: other, popoverWindow: a, statusWindow: b))
        // The global monitor's case: clicks in other apps carry no window.
        XCTAssertTrue(StatusItemController.isOutsideClick(eventWindow: nil, popoverWindow: a, statusWindow: b))
    }
}
