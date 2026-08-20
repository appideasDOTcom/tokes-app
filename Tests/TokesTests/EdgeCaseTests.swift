import AppKit
import XCTest

@testable import Tokes

/// The §4.13 batch: values a server can send that no test had ever sent, and
/// two static APIs the suite drives directly. Each of these was found by
/// probing rather than by reading, and each is one branch wide.
final class EdgeCaseTests: XCTestCase {
    // MARK: - Copilot: a plan with no premium allowance

    private func copilotBody(_ quota: String) -> Data {
        Data(#"{"quota_snapshots":{"premium_interactions":\#(quota)}}"#.utf8)
    }

    /// `entitlement: 0` is a real plan shape — some org seats and free accounts
    /// carry no premium-request allowance. It used to fall through every arm
    /// and surface as "Could not parse Copilot response", which blames Tokes
    /// for the plan the user is on.
    func testAPlanWithNoPremiumAllowanceReadsAsZeroRatherThanAParseError() throws {
        let limit = try CopilotClient.limit(
            from: copilotBody(#"{"entitlement":0,"credits_used":0}"#))

        XCTAssertEqual(limit.percent, 0)
        XCTAssertEqual(limit.detail, "Plan includes no premium requests")
        XCTAssertEqual(limit.id, "copilot_premium")
        XCTAssertEqual(limit.provider, .copilot)
    }

    /// The same plan without a `credits_used` field, which is the shape the
    /// endpoint actually returns when there is nothing to count.
    func testANoAllowancePlanParsesWithoutACreditsUsedField() throws {
        let limit = try CopilotClient.limit(from: copilotBody(#"{"entitlement":0}"#))

        XCTAssertEqual(limit.percent, 0)
        XCTAssertEqual(limit.detail, "Plan includes no premium requests")
    }

    /// The guard that keeps the new branch from swallowing a genuinely
    /// unreadable body.
    func testAQuotaWithNoUsableFieldsIsStillAParseError() {
        XCTAssertThrowsError(try CopilotClient.limit(from: copilotBody(#"{"credits_used":5}"#))) {
            guard case .decode = $0 as? CopilotError else {
                return XCTFail("expected .decode, got \($0)")
            }
        }
    }

    /// A metered plan still meters — the zero branch sits after the real one.
    func testAMeteredPlanIsUnaffected() throws {
        let limit = try CopilotClient.limit(
            from: copilotBody(#"{"entitlement":300,"credits_used":75}"#))

        XCTAssertEqual(limit.percent, 25, accuracy: 0.001)
        XCTAssertEqual(limit.detail, "75 of 300 credits used")
    }

    // MARK: - Out-of-range percents

    private func title(_ percent: Double) -> String? {
        StatusItemController.makeTitle(
            limits: [TestFixtures.limit(id: "session", label: "Session (5 hr)",
                                        percent: percent, isSession: true)],
            selection: .session, hasError: false)?.string
    }

    /// `makeIcon` has always clamped its bar heights; `makeTitle` did not, so
    /// one value drew a full red bar beside the text " 420%".
    func testAnOverHundredPercentIsClampedTheWayTheBarsAre() {
        XCTAssertEqual(title(420), " 100%")
        XCTAssertEqual(title(100.4), " 100%")
    }

    func testANegativePercentIsClampedToZero() {
        XCTAssertEqual(title(-5), " 0%")
        XCTAssertEqual(title(-0.4), " 0%")
    }

    func testClampingDoesNotDisturbNormalValues() {
        XCTAssertEqual(title(0), " 0%")
        XCTAssertEqual(title(24.4), " 24%")
        XCTAssertEqual(title(99.5), " 100%")
    }

    /// A clamped-up value is still at its limit, so it still reads red; a
    /// clamped-up-from-negative one is not.
    func testTheClampKeepsTheAtLimitColor() {
        let over = StatusItemController.makeTitle(
            limits: [TestFixtures.limit(id: "session", label: "s", percent: 420, isSession: true)],
            selection: .session, hasError: false)
        let under = StatusItemController.makeTitle(
            limits: [TestFixtures.limit(id: "session", label: "s", percent: -5, isSession: true)],
            selection: .session, hasError: false)

        XCTAssertEqual(over?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       .systemRed)
        XCTAssertEqual(under?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       .labelColor)
    }

    // MARK: - Duplicate limit ids

    private func snapshot(_ limits: String) throws -> UsageSnapshot {
        try UsageClient.snapshot(from: Data(#"{"limits":\#(limits)}"#.utf8))
    }

    /// Two entries claiming one id would reach `ForEach` over an `Identifiable`
    /// whose id repeats, and `UsageSample.v` is a dictionary, so history would
    /// keep only the last. The survivor is the highest — the same rule the
    /// scoped-weekly menu bar pick uses.
    func testDuplicateIdsCollapseToTheHighest() throws {
        let snap = try snapshot(#"[{"kind":"session","percent":24},{"kind":"session","percent":61}]"#)

        XCTAssertEqual(snap.limits.count, 1)
        XCTAssertEqual(snap.limits.first?.id, "session")
        XCTAssertEqual(snap.limits.first?.percent, 61)
    }

    /// Order must not decide it — the higher value wins from either position.
    func testTheHighestWinsFromEitherPosition() throws {
        let snap = try snapshot(#"[{"kind":"session","percent":61},{"kind":"session","percent":24}]"#)

        XCTAssertEqual(snap.limits.map(\.percent), [61])
    }

    /// Two *different* scoped models are not duplicates and both survive; the
    /// dedup keys on the id, which carries the model name.
    func testDistinctScopedModelsAreNotTreatedAsDuplicates() throws {
        let snap = try snapshot("""
            [{"kind":"weekly_scoped","percent":10,"scope":{"model":{"display_name":"Fable"}}},
             {"kind":"weekly_scoped","percent":80,"scope":{"model":{"display_name":"Opus"}}}]
            """)

        XCTAssertEqual(snap.limits.count, 2)
        XCTAssertEqual(Set(snap.limits.map(\.id)),
                       ["weekly_scoped:Fable", "weekly_scoped:Opus"])
    }

    /// Dedup must not disturb the display order the popover depends on.
    func testDedupKeepsSessionBeforeWeeklyBeforeScoped() throws {
        let snap = try snapshot("""
            [{"kind":"weekly_scoped","percent":10,"scope":{"model":{"display_name":"Fable"}}},
             {"kind":"weekly_all","percent":18},
             {"kind":"session","percent":24},
             {"kind":"session","percent":30}]
            """)

        XCTAssertEqual(snap.limits.map(\.id), ["session", "weekly_all", "weekly_scoped:Fable"])
        XCTAssertEqual(snap.limits.first?.percent, 30)
    }

    // MARK: - Chart windowing

    private func sample(_ minutesAgo: Double, _ values: [String: Double]) -> UsageSample {
        UsageSample(t: Date().addingTimeInterval(-minutesAgo * 60), v: values)
    }

    /// The window filter's reject arm, which had never run: every sample the
    /// view smoke tests seed is inside the window and carries every limit id.
    func testSamplesOlderThanTheWindowAreDropped() {
        let pts = UsageChart.points(
            samples: [sample(10, ["session": 1]), sample(400, ["session": 2])],
            limitID: "session", window: 6 * 3600, currentPercent: 5)

        // The in-window sample plus the appended "now" point; the 400-minute
        // one is outside a 6-hour session window.
        XCTAssertEqual(pts.map(\.value), [1, 5])
    }

    /// The other half of the same guard: one limit's series must not appear in
    /// another limit's chart.
    func testAnotherLimitsSamplesDoNotEnterThisChart() {
        let pts = UsageChart.points(
            samples: [sample(5, ["weekly_all": 90]), sample(4, ["session": 12])],
            limitID: "session", window: 6 * 3600, currentPercent: 12)

        XCTAssertEqual(pts.map(\.value), [12, 12])
    }

    /// A 7-day chart keeps what a 6-hour chart drops.
    func testTheWeeklyWindowKeepsWhatTheSessionWindowDrops() {
        let samples = [sample(10, ["weekly_all": 1]), sample(400, ["weekly_all": 2])]

        XCTAssertEqual(UsageChart.points(samples: samples, limitID: "weekly_all",
                                         window: 7 * 86400, currentPercent: 3).count, 3)
        XCTAssertEqual(UsageChart.points(samples: samples, limitID: "weekly_all",
                                         window: 6 * 3600, currentPercent: 3).count, 2)
    }

    /// With no history at all the chart still has the "now" point, which is
    /// what makes it alive from the first poll.
    func testAnEmptyHistoryStillPlotsNow() {
        let pts = UsageChart.points(samples: [], limitID: "session",
                                    window: 6 * 3600, currentPercent: 42)

        XCTAssertEqual(pts.map(\.value), [42])
    }

    // MARK: - downsample

    /// `Int(ceil(10 / 0.0))` traps rather than throwing. Unreachable from the
    /// app — the only call site passes 240 — but this is a static API the tests
    /// drive, and a trap is the wrong way for the next caller to find out.
    func testAZeroBudgetReturnsTheInputRatherThanTrapping() {
        let pts = (0..<10).map { ChartPoint(date: Date().addingTimeInterval(Double($0)),
                                            value: Double($0)) }

        XCTAssertEqual(UsageChart.downsample(pts, maxCount: 0).count, 10)
        XCTAssertEqual(UsageChart.downsample(pts, maxCount: -1).count, 10)
    }

    func testDownsamplingAveragesIntoTheBudget() {
        let pts = (0..<100).map { ChartPoint(date: Date().addingTimeInterval(Double($0)),
                                             value: Double($0)) }

        let reduced = UsageChart.downsample(pts, maxCount: 10)
        XCTAssertLessThanOrEqual(reduced.count, 10)
        XCTAssertEqual(reduced.first?.value ?? 0, 4.5, accuracy: 0.001)
    }
}
