import AppKit
import SwiftUI
import XCTest

@testable import Tokes

/// Hosting-controller smoke tests: each view builds, lays out, and reports a
/// sensible fitting size for its state.
final class ViewSmokeTests: XCTestCase {
    private func makeState(withSnapshot: Bool = true, error: String? = nil,
                           withCopilot: Bool = false) -> AppState {
        let state = AppState()
        if withSnapshot {
            var limits = [
                TestFixtures.limit(id: "session", label: "Session (5 hr)", percent: 24,
                                   resetsAt: Date().addingTimeInterval(3600), isSession: true),
                TestFixtures.limit(id: "weekly_all", label: "Weekly (7 day)", percent: 18),
                TestFixtures.limit(id: "weekly_scoped:Fable", label: "Weekly Fable", percent: 19),
            ]
            if withCopilot {
                limits.append(TestFixtures.copilotLimit(percent: 12))
            }
            state.snapshot = UsageSnapshot(limits: limits, fetchedAt: Date())
            state.samples = (0..<20).map {
                UsageSample(t: Date().addingTimeInterval(Double(-$0) * 300),
                            v: ["session": Double($0), "weekly_all": 18,
                                "weekly_scoped:Fable": 19, "copilot_premium": 12])
            }
        }
        state.errorMessage = error
        return state
    }

    @MainActor
    private func popover(state: AppState) -> NSView {
        let hosting = NSHostingController(rootView: PopoverView(
            state: state, onHoverChanged: { _ in }, onSettings: {}, onRefresh: {}, onQuit: {}))
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view
    }

    @MainActor
    func testPopoverViewRendersAllLimitSections() {
        let view = popover(state: makeState())
        XCTAssertEqual(view.fittingSize.width, 320, accuracy: 1)
        // Three limit sections with 64pt charts comfortably exceed this.
        XCTAssertGreaterThan(view.fittingSize.height, 200)
    }

    @MainActor
    func testPopoverViewGrowsWithCopilotGroup() {
        let claudeOnly = popover(state: makeState())
        let withCopilot = popover(state: makeState(withCopilot: true))
        // A fourth section plus two provider group headers adds real height.
        XCTAssertGreaterThan(withCopilot.fittingSize.height,
                             claudeOnly.fittingSize.height + 60)
        XCTAssertEqual(withCopilot.fittingSize.width, 320, accuracy: 1)
    }

    @MainActor
    func testPopoverViewHidesScopedWeeklyWhenDisabled() {
        UserDefaults.standard.set(false, forKey: SettingsKeys.showScopedWeekly)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.showScopedWeekly) }
        let hidden = popover(state: makeState())

        UserDefaults.standard.removeObject(forKey: SettingsKeys.showScopedWeekly)
        let full = popover(state: makeState())

        // Dropping one 64pt-chart section loses real height.
        XCTAssertLessThan(hidden.fittingSize.height, full.fittingSize.height - 60)
    }

    @MainActor
    func testPopoverViewRendersConnectingState() {
        let view = popover(state: makeState(withSnapshot: false))
        XCTAssertGreaterThan(view.fittingSize.height, 40)
    }

    @MainActor
    func testPopoverViewRendersErrorBanner() {
        let plain = popover(state: makeState(withSnapshot: false))
        let withError = popover(state: makeState(withSnapshot: false, error: "Something went wrong"))
        XCTAssertGreaterThan(withError.fittingSize.height, plain.fittingSize.height - 60)
    }

    @MainActor
    func testLimitSectionWithChartRenders() {
        let limit = TestFixtures.limit(id: "session", label: "Session (5 hr)", percent: 24,
                                       resetsAt: Date().addingTimeInterval(3600), isSession: true)
        let samples = (0..<10).map {
            UsageSample(t: Date().addingTimeInterval(Double(-$0) * 60), v: ["session": Double($0)])
        }
        let hosting = NSHostingController(rootView: LimitSection(limit: limit, samples: samples)
            .frame(width: 320))
        hosting.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.view.fittingSize.height, 60)
    }

    @MainActor
    func testSettingsViewLoads() {
        let hosting = NSHostingController(rootView: SettingsView(onCredentialsChanged: {}))
        XCTAssertNotNil(hosting.view)
        XCTAssertEqual(hosting.view.fittingSize.width, 460, accuracy: 1)
    }

    /// The menu bar picker renders for every stored selection, including one
    /// whose measurement is currently switched off.
    @MainActor
    func testSettingsViewLoadsForEveryMenuBarSelection() {
        defer {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.menuBarLabel)
            UserDefaults.standard.removeObject(forKey: SettingsKeys.copilotEnabled)
            UserDefaults.standard.removeObject(forKey: SettingsKeys.showScopedWeekly)
        }
        for copilot in [false, true] {
            for scoped in [false, true] {
                UserDefaults.standard.set(copilot, forKey: SettingsKeys.copilotEnabled)
                UserDefaults.standard.set(scoped, forKey: SettingsKeys.showScopedWeekly)
                for option in MenuBarLabel.allCases {
                    UserDefaults.standard.set(option.rawValue, forKey: SettingsKeys.menuBarLabel)
                    let hosting = NSHostingController(rootView: SettingsView(onCredentialsChanged: {}))
                    hosting.view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(hosting.view.fittingSize.width, 460, accuracy: 1,
                                   "\(option) / copilot=\(copilot) scoped=\(scoped)")
                }
            }
        }
    }
}
