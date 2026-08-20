import AppKit
import XCTest

@testable import Tokes

final class StatusIconTests: XCTestCase {
    func testIconSizeForThreeBars() {
        let icon = StatusItemController.makeIcon(limits: [
            TestFixtures.limit(id: "a", percent: 10),
            TestFixtures.limit(id: "b", percent: 50),
            TestFixtures.limit(id: "c", percent: 90),
        ])
        XCTAssertEqual(icon.size.width, 23)  // 3×5pt bars + 2×3pt gaps + 2pt margin
        XCTAssertEqual(icon.size.height, 18)
        XCTAssertFalse(icon.isTemplate)
    }

    func testIconAlwaysReservesThreeTracks() {
        XCTAssertEqual(StatusItemController.makeIcon(limits: []).size.width, 23)
    }

    func testIconReservesTwoTracksWhenScopedWeeklyHidden() {
        let icon = StatusItemController.makeIcon(limits: [
            TestFixtures.limit(id: "session", percent: 10),
            TestFixtures.limit(id: "weekly_all", percent: 50),
        ], claudeTracks: 2)
        XCTAssertEqual(icon.size.width, 15)  // 2×5pt bars + 1×3pt gap + 2pt margin
        XCTAssertEqual(StatusItemController.makeIcon(limits: [], claudeTracks: 2).size.width, 15)
    }

    func testIconGrowsWithExtraLimits() {
        let icon = StatusItemController.makeIcon(limits: (0..<4).map {
            TestFixtures.limit(id: "l\($0)", percent: 10)
        })
        XCTAssertEqual(icon.size.width, 31)  // 4 bars + 3 gaps + margin
    }

    func testBarFillColorFollowsSeverity() throws {
        let icon = StatusItemController.makeIcon(limits: [
            TestFixtures.limit(id: "red", percent: 100),
            TestFixtures.limit(id: "orange", percent: 70),
            TestFixtures.limit(id: "green", percent: 10),
        ])
        let raster = try XCTUnwrap(Raster(icon))

        // Bar i spans x = 1 + 8i ..< 6 + 8i; sample near each bar's center.
        let red = raster.pixel(x: 3, yFromBottom: 8)  // 100% fills the track
        XCTAssertGreaterThan(red.r, red.g)
        XCTAssertGreaterThan(red.r, red.b)

        let orange = raster.pixel(x: 11, yFromBottom: 3)
        XCTAssertGreaterThan(orange.r, orange.g)
        XCTAssertGreaterThan(orange.g, orange.b)

        let green = raster.pixel(x: 19, yFromBottom: 2)  // minimum 3pt nub
        XCTAssertGreaterThan(green.g, green.r)

        // Above a 10% fill only the faint track remains.
        let track = raster.pixel(x: 19, yFromBottom: 14)
        XCTAssertLessThan(track.a, 150)
    }

    func testEmptyLimitsDrawOnlyFaintTracks() throws {
        let raster = try XCTUnwrap(Raster(StatusItemController.makeIcon(limits: [])))
        XCTAssertLessThan(raster.pixel(x: 3, yFromBottom: 8).a, 150)
    }

    func testCopilotBarSitsBehindDivider() throws {
        let icon = StatusItemController.makeIcon(limits: [
            TestFixtures.limit(id: "session", percent: 10),
            TestFixtures.limit(id: "weekly_all", percent: 10),
            TestFixtures.limit(id: "weekly_scoped:Fable", percent: 10),
            TestFixtures.copilotLimit(percent: 40),
        ])
        // 3 Claude bars (21) + divider band (7) + 1 Copilot bar (5) + 2 margin.
        XCTAssertEqual(icon.size.width, 35)

        let raster = try XCTUnwrap(Raster(icon))
        // Divider line at x=25, mid-height; faint but present.
        let divider = raster.pixel(x: 25, yFromBottom: 8)
        XCTAssertGreaterThan(divider.a, 30)
        XCTAssertLessThan(divider.a, 160)
        // The gap beside the divider is empty.
        XCTAssertEqual(raster.pixel(x: 23, yFromBottom: 8).a, 0)
        // Copilot bar (x 29..34) fills green at 40%.
        let copilot = raster.pixel(x: 31, yFromBottom: 2)
        XCTAssertGreaterThan(copilot.g, copilot.r)
    }

    func testClaudeOnlyIconHasNoDivider() {
        let icon = StatusItemController.makeIcon(limits: [
            TestFixtures.limit(id: "session", percent: 10),
            TestFixtures.limit(id: "weekly_all", percent: 10),
            TestFixtures.limit(id: "weekly_scoped:Fable", percent: 10),
        ])
        XCTAssertEqual(icon.size.width, 23)
    }
}

/// What the menu bar button is *given* — the half of `updateButton` that is not
/// AppKit. `makeIcon` and `makeTitle` are asserted above; this is the step that
/// decides which limits reach them, how many bar slots to reserve, and what the
/// tooltip says.
final class MenuBarContentTests: XCTestCase {
    private let claude = [
        TestFixtures.limit(id: "session", label: "Session (5 hr)", percent: 24.4, isSession: true),
        TestFixtures.limit(id: "weekly_all", label: "Weekly (7 day)", percent: 60.5),
        TestFixtures.limit(id: "weekly_scoped:Fable", label: "Weekly Fable", percent: 88),
    ]

    private func content(_ limits: [UsageLimit]?, showScopedWeekly: Bool = true)
        -> StatusItemController.MenuBarContent {
        StatusItemController.content(
            for: limits.map { UsageSnapshot(limits: $0, fetchedAt: Date()) },
            showScopedWeekly: showScopedWeekly)
    }

    // MARK: - The scoped-weekly setting

    func testHidingTheScopedWeeklyDropsItAndItsBarSlot() {
        let shown = content(claude)
        XCTAssertEqual(shown.limits.map(\.id), ["session", "weekly_all", "weekly_scoped:Fable"])
        XCTAssertEqual(shown.claudeTracks, 3)

        let hidden = content(claude, showScopedWeekly: false)
        XCTAssertEqual(hidden.limits.map(\.id), ["session", "weekly_all"])
        // The reserved slot has to move with the filter, or the item's width
        // jitters as buckets appear and disappear.
        XCTAssertEqual(hidden.claudeTracks, 2)
        XCTAssertEqual(StatusItemController.makeIcon(limits: hidden.limits,
                                                     claudeTracks: hidden.claudeTracks).size.width,
                       15)
    }

    func testHidingTheScopedWeeklyLeavesCopilotAlone() {
        let hidden = content(claude + [TestFixtures.copilotLimit(percent: 12)],
                             showScopedWeekly: false)
        XCTAssertEqual(hidden.limits.map(\.id), ["session", "weekly_all", "copilot_premium"])
    }

    func testEveryScopedBucketIsHiddenTogether() {
        let two = claude + [TestFixtures.limit(id: "weekly_scoped:Opus", percent: 12)]
        XCTAssertEqual(content(two, showScopedWeekly: false).limits.map(\.id),
                       ["session", "weekly_all"])
        XCTAssertEqual(content(two).limits.count, 4)
    }

    func testTheSettingDefaultsToOnWhenNeverSet() {
        let suite = "TokesTests-scoped-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(StatusItemController.showScopedWeekly(in: defaults))
        defaults.set(false, forKey: SettingsKeys.showScopedWeekly)
        XCTAssertFalse(StatusItemController.showScopedWeekly(in: defaults))
        defaults.set(true, forKey: SettingsKeys.showScopedWeekly)
        XCTAssertTrue(StatusItemController.showScopedWeekly(in: defaults))
    }

    // MARK: - Tooltip

    func testTooltipBeforeTheFirstPoll() {
        XCTAssertEqual(content(nil).toolTip, "Tokes — waiting for usage data")
        XCTAssertEqual(content([]).toolTip, "Tokes — waiting for usage data")
    }

    func testTooltipNamesClaudeWhileItIsTheOnlyProvider() {
        XCTAssertEqual(content(claude).toolTip,
                       "Claude usage — Session (5 hr): 24% · Weekly (7 day): 61% · Weekly Fable: 88%")
    }

    /// With two services reporting, "Claude usage" would be wrong for half the
    /// numbers, so the prefix drops the brand.
    func testTooltipDropsTheBrandOnceCopilotIsReporting() {
        let toolTip = content(claude + [TestFixtures.copilotLimit(percent: 12)]).toolTip
        XCTAssertTrue(toolTip.hasPrefix("Usage — "), toolTip)
        XCTAssertFalse(toolTip.contains("Claude usage"))
        XCTAssertTrue(toolTip.hasSuffix("Copilot Premium: 12%"), toolTip)
    }

    func testTooltipRoundsHalfUpLikeTheMenuBarLabel() {
        // 60.5 → 61 in both places; a tooltip that truncated would disagree
        // with the number beside the icon.
        XCTAssertTrue(content(claude).toolTip.contains("Weekly (7 day): 61%"))
        XCTAssertEqual(StatusItemController.makeTitle(limits: claude, selection: .weeklyAll,
                                                      hasError: false)?.string, " 61%")
    }

    func testTooltipFollowsTheScopedWeeklySetting() {
        XCTAssertFalse(content(claude, showScopedWeekly: false).toolTip.contains("Weekly Fable"))
    }
}

final class DebugLogTests: XCTestCase {
    private var logURL: URL!
    private var originalURL: URL!

    override func setUp() {
        super.setUp()
        originalURL = DebugLog.fileURL
        logURL = TestFixtures.tempDirectory().appendingPathComponent("debug.log")
        DebugLog.fileURL = logURL
        UserDefaults.standard.removeObject(forKey: "debugLogging")
    }

    override func tearDown() {
        DebugLog.fileURL = originalURL
        UserDefaults.standard.removeObject(forKey: "debugLogging")
        try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testDisabledByDefault() {
        DebugLog.log("should not appear")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testWritesAndAppendsWhenEnabled() throws {
        UserDefaults.standard.set(true, forKey: "debugLogging")
        DebugLog.log("first entry")
        DebugLog.log("second entry")

        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("first entry"))
        XCTAssertTrue(text.contains("second entry"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }
}

final class StatusTitleTests: XCTestCase {
    private let limits = [
        TestFixtures.limit(id: "session", percent: 24.4, isSession: true),
        TestFixtures.limit(id: "weekly_all", percent: 60.5),
        TestFixtures.limit(id: "weekly_scoped:Fable", percent: 88),
        TestFixtures.copilotLimit(percent: 12),
    ]

    private func title(_ selection: MenuBarLabel, limits: [UsageLimit]? = nil,
                       hasError: Bool = false) -> NSAttributedString? {
        StatusItemController.makeTitle(limits: limits ?? self.limits,
                                       selection: selection, hasError: hasError)
    }

    func testOffDrawsNoTitle() {
        XCTAssertNil(title(.off))
    }

    func testEachSelectionDrawsItsOwnPercent() {
        XCTAssertEqual(title(.session)?.string, " 24%")
        XCTAssertEqual(title(.weeklyAll)?.string, " 61%")   // 60.5 rounds up
        XCTAssertEqual(title(.weeklyScoped)?.string, " 88%")
        XCTAssertEqual(title(.copilot)?.string, " 12%")
        XCTAssertEqual(title(.highest)?.string, " 88%")
    }

    func testAbsentMeasurementDrawsNoTitleRatherThanAnotherLimit() {
        let claudeOnly = limits.filter { $0.provider == .claude }
        XCTAssertNil(title(.copilot, limits: claudeOnly))

        let noScoped = limits.filter { !$0.isScopedWeekly }
        XCTAssertNil(title(.weeklyScoped, limits: noScoped))

        for option in MenuBarLabel.allCases {
            XCTAssertNil(title(option, limits: []), "\(option) should draw nothing before the first poll")
        }
    }

    func testColorSignalsExhaustionThenStaleness() throws {
        func color(of string: NSAttributedString?) throws -> NSColor {
            let attributed = try XCTUnwrap(string)
            return try XCTUnwrap(
                attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        }

        let maxed = [TestFixtures.limit(id: "session", percent: 100)]
        XCTAssertEqual(try color(of: title(.session, limits: maxed)), .systemRed)
        // Exhaustion outranks staleness.
        XCTAssertEqual(try color(of: title(.session, limits: maxed, hasError: true)), .systemRed)
        XCTAssertEqual(try color(of: title(.session, hasError: true)), .systemOrange)
        XCTAssertEqual(try color(of: title(.session)), .labelColor)
    }

    func testTitleUsesMonospacedDigitsSoWidthDoesNotJitter() throws {
        let attributed = try XCTUnwrap(title(.session))
        let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font, NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium))
    }
}
