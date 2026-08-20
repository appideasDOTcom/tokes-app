import AppKit
import SwiftUI
import XCTest

@testable import Tokes

/// Hosting-controller smoke tests: each view builds, lays out, and reports a
/// sensible fitting size for its state.
final class ViewSmokeTests: XCTestCase {
    /// `SettingsView.onAppear` reads the manual-token keychain slot on every
    /// render, and this suite renders it 38 times. Pointed at the test-only
    /// service so a suite run never reads the item the installed app owns.
    static let keychainService = "com.appideas.tokes.tests"
    /// Same reasoning for the imported-file bookmarks `onAppear` resolves.
    static let bookmarks = UserDefaults(suiteName: "com.appideas.tokes.tests.viewsmoke")!

    /// Settings pointed at the test-only keychain slot and bookmark domain.
    private func settingsView() -> SettingsView {
        SettingsView(onCredentialsChanged: {}, keychainService: Self.keychainService,
                     bookmarkDefaults: Self.bookmarks)
    }

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

    /// The banner has to add height, and the old assertion could not see that.
    ///
    /// It compared the two *snapshotless* states with a `- 60` tolerance, and
    /// those two are not comparable: with no snapshot the banner *replaces* the
    /// "Connecting…" block, so the error state is legitimately 35pt shorter and
    /// the assertion passed on a number pointing the wrong way. A zero-height
    /// banner would have passed it too. Compared against a state that keeps its
    /// limits, the banner is purely additive and a strict inequality holds.
    @MainActor
    func testPopoverViewRendersErrorBanner() {
        let plain = popover(state: makeState())
        let withError = popover(state: makeState(error: "Something went wrong"))

        XCTAssertGreaterThan(withError.fittingSize.height, plain.fittingSize.height)
        // And the text itself is laid out, not clipped to one line.
        let wrapped = popover(state: makeState(
            error: String(repeating: "Usage API rate-limited — retrying automatically. ", count: 4)))
        XCTAssertGreaterThan(wrapped.fittingSize.height, withError.fittingSize.height)
    }

    /// The other half of that: with nothing to show, the banner stands in for
    /// the "Connecting…" block rather than sitting above it.
    @MainActor
    func testAnErrorReplacesTheConnectingBlockRatherThanStackingOnIt() {
        let connecting = popover(state: makeState(withSnapshot: false))
        let failed = popover(state: makeState(withSnapshot: false, error: "Something went wrong"))

        // Pinned because it is the fact that made the old assertion misleading:
        // these two states differ by a *swap*, so no tolerance-based comparison
        // between them says anything about whether the banner rendered. That
        // question is settled in the test above, against a state that keeps its
        // limits and where the banner is purely additive.
        XCTAssertLessThan(failed.fittingSize.height, connecting.fittingSize.height)
    }

    /// First launch: fewer than three samples draws the "Collecting history…"
    /// overlay instead of a line. Every other test here seeds 10–20 samples, so
    /// the state a new user actually sees was never rendered.
    @MainActor
    func testTheChartRendersBeforeThereIsHistoryToDraw() {
        let limit = TestFixtures.limit(id: "session", label: "Session (5 hr)", percent: 24,
                                       resetsAt: Date().addingTimeInterval(3600), isSession: true)
        for count in 0...3 {
            let samples = (0..<count).map {
                UsageSample(t: Date().addingTimeInterval(Double(-$0) * 60), v: ["session": 12])
            }
            let hosting = NSHostingController(rootView: LimitSection(limit: limit, samples: samples)
                .frame(width: 320))
            hosting.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.view.fittingSize.height, 60, "\(count) samples")
        }
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
        let hosting = NSHostingController(rootView: settingsView())
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
                    let hosting = NSHostingController(rootView: settingsView())
                    hosting.view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(hosting.view.fittingSize.width, 460, accuracy: 1,
                                   "\(option) / copilot=\(copilot) scoped=\(scoped)")
                }
            }
        }
    }

    /// Opening Settings must repair a stored credential source this build does
    /// not ship — the shape a `defaults` domain copied in from the Homebrew
    /// build has. The normalization ran before this test existed; nothing read
    /// the result back, so the guard was executed but unproven.
    @MainActor
    func testOpeningSettingsRepairsASourceThisBuildDoesNotShip() {
        defer {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.credentialSource)
            UserDefaults.standard.removeObject(forKey: SettingsKeys.copilotCredentialSource)
        }
        UserDefaults.standard.set(CredentialSource.claudeCode.rawValue,
                                  forKey: SettingsKeys.credentialSource)
        UserDefaults.standard.set(CopilotCredentialSource.editor.rawValue,
                                  forKey: SettingsKeys.copilotCredentialSource)

        let hosting = NSHostingController(rootView: settingsView())
        hosting.view.layoutSubtreeIfNeeded()  // fires onAppear

        let claude = UserDefaults.standard.string(forKey: SettingsKeys.credentialSource)
        let copilot = UserDefaults.standard.string(forKey: SettingsKeys.copilotCredentialSource)
        #if TOKES_APP_STORE
            XCTAssertEqual(claude, CredentialSource.importedFile.rawValue,
                           "the App Store build must not stay pointed at a reader it lacks")
            XCTAssertEqual(copilot, CopilotCredentialSource.importedFile.rawValue)
        #else
            XCTAssertEqual(claude, CredentialSource.claudeCode.rawValue,
                           "the direct build ships this reader and must keep the choice")
            XCTAssertEqual(copilot, CopilotCredentialSource.editor.rawValue)
        #endif
        // Whatever the build, the stored value names a source it offers.
        XCTAssertTrue(CredentialSource.available().contains(CredentialSource(rawValue: claude!)!))
        XCTAssertTrue(CopilotCredentialSource.available()
            .contains(CopilotCredentialSource(rawValue: copilot!)!))
    }

    /// Every credential source renders its own controls — the import buttons and
    /// the imported-path label included. `allCases`, not `available()`: a source
    /// this build hides must still render if a stale setting names it.
    @MainActor
    func testSettingsViewLoadsForEveryCredentialSource() {
        defer {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.credentialSource)
            UserDefaults.standard.removeObject(forKey: SettingsKeys.copilotCredentialSource)
            UserDefaults.standard.removeObject(forKey: SettingsKeys.copilotEnabled)
        }
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
        for claude in CredentialSource.allCases {
            for copilot in CopilotCredentialSource.allCases {
                UserDefaults.standard.set(claude.rawValue, forKey: SettingsKeys.credentialSource)
                UserDefaults.standard.set(copilot.rawValue, forKey: SettingsKeys.copilotCredentialSource)
                let hosting = NSHostingController(rootView: settingsView())
                hosting.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(hosting.view.fittingSize.width, 460, accuracy: 1,
                               "claude=\(claude) copilot=\(copilot)")
            }
        }
    }
}
