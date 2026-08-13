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

final class CredentialSourceTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(CredentialSource.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(CredentialSource.manual.rawValue, "manual")
        XCTAssertEqual(CredentialSource(rawValue: "manual"), .manual)
        XCTAssertNil(CredentialSource(rawValue: "bogus"))
    }
}
