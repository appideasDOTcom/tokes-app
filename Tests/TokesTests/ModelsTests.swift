import AppKit
import SwiftUI
import XCTest

@testable import Tokes

final class SeverityColorTests: XCTestCase {
    func testThresholds() {
        XCTAssertEqual(SeverityColor.nsColor(for: 0), .systemGreen)
        XCTAssertEqual(SeverityColor.nsColor(for: 59.9), .systemGreen)
        XCTAssertEqual(SeverityColor.nsColor(for: 60), .systemOrange)
        XCTAssertEqual(SeverityColor.nsColor(for: 84.9), .systemOrange)
        XCTAssertEqual(SeverityColor.nsColor(for: 85), .systemRed)
        XCTAssertEqual(SeverityColor.nsColor(for: 100), .systemRed)
        XCTAssertEqual(SeverityColor.nsColor(for: 150), .systemRed)
    }

    func testSwiftUIColorMatchesNSColor() {
        XCTAssertEqual(SeverityColor.color(for: 10), Color(nsColor: .systemGreen))
        XCTAssertEqual(SeverityColor.color(for: 70), Color(nsColor: .systemOrange))
        XCTAssertEqual(SeverityColor.color(for: 90), Color(nsColor: .systemRed))
    }
}

final class UsageProviderTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(UsageProvider.claude.displayName, "Claude")
        XCTAssertEqual(UsageProvider.copilot.displayName, "GitHub Copilot")
    }

    func testLimitDefaultsToClaudeWithNoDetail() {
        let limit = UsageLimit(id: "session", label: "Session", percent: 1,
                               severity: "normal", resetsAt: nil, isSession: true)
        XCTAssertEqual(limit.provider, .claude)
        XCTAssertNil(limit.detail)
    }

    func testCopilotLimitUsesWeeklyChartWindow() {
        XCTAssertEqual(TestFixtures.copilotLimit().chartWindow, 7 * 24 * 3600)
    }
}

final class ResetFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_600_000)

    func testMinutesOnly() {
        XCTAssertEqual(ResetFormatter.resetsIn(now.addingTimeInterval(45 * 60), from: now), "resets in 45m")
    }

    func testSubMinuteRoundsDownToZeroMinutes() {
        XCTAssertEqual(ResetFormatter.resetsIn(now.addingTimeInterval(45), from: now), "resets in 0m")
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(ResetFormatter.resetsIn(now.addingTimeInterval(90 * 60), from: now), "resets in 1h 30m")
        XCTAssertEqual(ResetFormatter.resetsIn(now.addingTimeInterval(3600), from: now), "resets in 1h 0m")
    }

    func testDaysAndHours() {
        XCTAssertEqual(ResetFormatter.resetsIn(now.addingTimeInterval(26 * 3600), from: now), "resets in 1d 2h")
        XCTAssertEqual(ResetFormatter.resetsIn(now.addingTimeInterval(6.5 * 24 * 3600), from: now), "resets in 6d 12h")
    }

    func testPastAndPresentDatesShowResetting() {
        XCTAssertEqual(ResetFormatter.resetsIn(now, from: now), "resetting…")
        XCTAssertEqual(ResetFormatter.resetsIn(now.addingTimeInterval(-60), from: now), "resetting…")
    }
}

final class UsageLimitTests: XCTestCase {
    func testChartWindow() {
        XCTAssertEqual(TestFixtures.limit(isSession: true).chartWindow, 6 * 3600)
        XCTAssertEqual(TestFixtures.limit(isSession: false).chartWindow, 7 * 24 * 3600)
    }

    func testIsScopedWeeklyMatchesOnlyModelScopedIds() {
        XCTAssertTrue(TestFixtures.limit(id: "weekly_scoped:Fable").isScopedWeekly)
        XCTAssertTrue(TestFixtures.limit(id: "weekly_scoped:Model").isScopedWeekly)
        XCTAssertFalse(TestFixtures.limit(id: "session").isScopedWeekly)
        XCTAssertFalse(TestFixtures.limit(id: "weekly_all").isScopedWeekly)
        XCTAssertFalse(TestFixtures.copilotLimit().isScopedWeekly)
    }
}

/// The recorded decision behind `UsageSample`'s key, which is the limit id and
/// therefore carries the model's display name for scoped buckets.
final class UsageSampleKeyingTests: XCTestCase {
    /// Renaming a model starts a new series rather than continuing the old one.
    /// This is intended — see `UsageSample`'s doc comment — and is pinned here
    /// so a future "fix" is a deliberate change rather than an accident.
    func testARenamedModelStartsANewSeries() {
        let before = UsageSample(t: Date().addingTimeInterval(-3600),
                                 v: ["weekly_scoped:Fable": 40])
        let after = UsageSample(t: Date(), v: ["weekly_scoped:Fable 5": 41])

        let series = [before, after].compactMap { $0.v["weekly_scoped:Fable 5"] }
        XCTAssertEqual(series, [41], "the pre-rename point does not join the new series")
        XCTAssertNil(after.v["weekly_scoped:Fable"], "and the old key is not back-filled")
    }

    /// The flip side, and the reason a stable key is not an option: two models
    /// metered at once must not collapse into one line on one chart.
    func testTwoScopedModelsKeepSeparateSeries() {
        let sample = UsageSample(t: Date(), v: ["weekly_scoped:Opus": 12,
                                                "weekly_scoped:Fable": 71])
        XCTAssertEqual(sample.v["weekly_scoped:Opus"], 12)
        XCTAssertEqual(sample.v["weekly_scoped:Fable"], 71)
    }
}

final class CredentialSourceTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(CredentialSource.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(CredentialSource.manual.rawValue, "manual")
        XCTAssertEqual(CredentialSource(rawValue: "manual"), .manual)
        XCTAssertNil(CredentialSource(rawValue: "bogus"))
    }
}

final class MenuBarLabelTests: XCTestCase {
    /// A full snapshot: both Claude weeklies, the model-scoped weekly, and Copilot.
    private let allLimits = [
        TestFixtures.limit(id: "session", percent: 24, isSession: true),
        TestFixtures.limit(id: "weekly_all", percent: 61),
        TestFixtures.limit(id: "weekly_scoped:Fable", percent: 88),
        TestFixtures.copilotLimit(percent: 12),
    ]

    func testRawValuesAreStable() {
        // Stored in UserDefaults — renaming a case would silently reset users.
        XCTAssertEqual(MenuBarLabel.allCases.map(\.rawValue),
                       ["off", "highest", "session", "weeklyAll", "weeklyScoped", "copilot"])
        XCTAssertEqual(MenuBarLabel(rawValue: "weeklyScoped"), .weeklyScoped)
        XCTAssertNil(MenuBarLabel(rawValue: "bogus"))
    }

    func testEachOptionSelectsItsOwnMeasurement() {
        XCTAssertNil(MenuBarLabel.off.limit(in: allLimits))
        XCTAssertEqual(MenuBarLabel.session.limit(in: allLimits)?.id, "session")
        XCTAssertEqual(MenuBarLabel.weeklyAll.limit(in: allLimits)?.id, "weekly_all")
        XCTAssertEqual(MenuBarLabel.weeklyScoped.limit(in: allLimits)?.id, "weekly_scoped:Fable")
        XCTAssertEqual(MenuBarLabel.copilot.limit(in: allLimits)?.id, "copilot_premium")
    }

    func testHighestPicksTheLargestPercentRegardlessOfProvider() {
        XCTAssertEqual(MenuBarLabel.highest.limit(in: allLimits)?.id, "weekly_scoped:Fable")

        let copilotLeads = [
            TestFixtures.limit(id: "session", percent: 5),
            TestFixtures.copilotLimit(percent: 97),
        ]
        XCTAssertEqual(MenuBarLabel.highest.limit(in: copilotLeads)?.id, "copilot_premium")
    }

    func testScopedWeeklyMatchesAnyModelName() {
        let limits = [TestFixtures.limit(id: "weekly_scoped:Some Future Model", percent: 40)]
        XCTAssertEqual(MenuBarLabel.weeklyScoped.limit(in: limits)?.percent, 40)
    }

    /// A plan can meter more than one model. "Weekly (model-specific)" shows
    /// the one closest to exhaustion, not the one the API happened to list
    /// first — that ordering is not guaranteed and it would hide the number the
    /// readout exists to surface.
    func testScopedWeeklyPicksTheHighestOfSeveralModels() {
        let limits = [
            TestFixtures.limit(id: "session", percent: 99, isSession: true),
            TestFixtures.limit(id: "weekly_scoped:Opus", percent: 12),
            TestFixtures.limit(id: "weekly_scoped:Fable", percent: 71),
            TestFixtures.limit(id: "weekly_scoped:Haiku", percent: 40),
        ]
        XCTAssertEqual(MenuBarLabel.weeklyScoped.limit(in: limits)?.id, "weekly_scoped:Fable")

        // Independent of the order they arrive in.
        XCTAssertEqual(MenuBarLabel.weeklyScoped.limit(in: limits.reversed())?.id,
                       "weekly_scoped:Fable")
        // And it stays inside the scoped buckets — the 99% session is higher
        // but is not a model-scoped weekly.
        XCTAssertEqual(MenuBarLabel.weeklyScoped.limit(in: limits)?.percent, 71)
    }

    func testMissingMeasurementSelectsNothing() {
        let claudeOnly = allLimits.filter { $0.provider == .claude }
        XCTAssertNil(MenuBarLabel.copilot.limit(in: claudeOnly))

        let noScoped = allLimits.filter { !$0.isScopedWeekly }
        XCTAssertNil(MenuBarLabel.weeklyScoped.limit(in: noScoped))

        for option in MenuBarLabel.allCases {
            XCTAssertNil(option.limit(in: []), "\(option) should select nothing from an empty snapshot")
        }
    }

    func testAvailableOptionsFollowTheOtherToggles() {
        XCTAssertEqual(MenuBarLabel.available(copilotEnabled: true, showScopedWeekly: true),
                       [.off, .highest, .session, .weeklyAll, .weeklyScoped, .copilot])
        XCTAssertEqual(MenuBarLabel.available(copilotEnabled: false, showScopedWeekly: true),
                       [.off, .highest, .session, .weeklyAll, .weeklyScoped])
        XCTAssertEqual(MenuBarLabel.available(copilotEnabled: true, showScopedWeekly: false),
                       [.off, .highest, .session, .weeklyAll, .copilot])
        XCTAssertEqual(MenuBarLabel.available(copilotEnabled: false, showScopedWeekly: false),
                       [.off, .highest, .session, .weeklyAll])
    }

    func testNormalizeFallsBackWhenAnOptionDisappears() {
        XCTAssertEqual(MenuBarLabel.copilot.normalized(copilotEnabled: false, showScopedWeekly: true),
                       .highest)
        XCTAssertEqual(MenuBarLabel.weeklyScoped.normalized(copilotEnabled: true, showScopedWeekly: false),
                       .highest)
        // Still-offered selections are left alone.
        XCTAssertEqual(MenuBarLabel.copilot.normalized(copilotEnabled: true, showScopedWeekly: false),
                       .copilot)
        XCTAssertEqual(MenuBarLabel.off.normalized(copilotEnabled: false, showScopedWeekly: false), .off)
        XCTAssertEqual(MenuBarLabel.session.normalized(copilotEnabled: false, showScopedWeekly: false),
                       .session)
    }

    func testEveryOptionHasADistinctMenuTitle() {
        let titles = MenuBarLabel.allCases.map(\.displayName)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertEqual(MenuBarLabel.off.displayName, "Off")
        XCTAssertEqual(MenuBarLabel.highest.displayName, "Highest value")
    }

    func testCurrentReadsStoredSelection() {
        let suiteName = "TokesTests-menuBarLabel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MenuBarLabel.current(in: defaults), .off)  // unset
        defaults.set("weeklyAll", forKey: SettingsKeys.menuBarLabel)
        XCTAssertEqual(MenuBarLabel.current(in: defaults), .weeklyAll)
        defaults.set("nonsense", forKey: SettingsKeys.menuBarLabel)
        XCTAssertEqual(MenuBarLabel.current(in: defaults), .off)
    }
}
