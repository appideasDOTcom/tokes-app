import AppKit
import Combine
import SwiftUI
import ViewInspector
import XCTest

@testable import Tokes

extension Inspection: InspectionEmissary {}

/// Reference cell for values a @Sendable inspection closure must hand back.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Drives SettingsView's real controls — taps, toggles, text input, and the
/// async Test Connection flows — via ViewInspector. Stateful tests host the
/// view in a windowless NSHostingController, so nothing here can order a
/// window front or steal focus.
final class SettingsInteractionTests: XCTestCase {
    static let keychainService = "com.appideas.tokes.tests"

    private var bookmarksName: String!
    private var bookmarks: UserDefaults!
    private var hosts: [NSViewController] = []
    private var tempDirs: [URL] = []

    override func setUp() {
        super.setUp()
        bookmarksName = "com.appideas.tokes.tests.interaction.\(UUID().uuidString)"
        bookmarks = UserDefaults(suiteName: bookmarksName)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        hosts = []
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        CredentialsProvider.deleteManualToken(service: Self.keychainService)
        CredentialsProvider.deleteManualToken(service: Self.keychainService,
                                              account: CopilotCredentialsProvider.manualAccount)
        UserDefaults.standard.removePersistentDomain(forName: bookmarksName)
        for key in [SettingsKeys.copilotEnabled, SettingsKeys.menuBarLabel,
                    SettingsKeys.showScopedWeekly, SettingsKeys.credentialSource,
                    SettingsKeys.copilotCredentialSource, SettingsKeys.refreshInterval] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private func settingsView(session: URLSession = .shared,
                              onChange: @escaping () -> Void = {}) -> SettingsView {
        SettingsView(onCredentialsChanged: onChange,
                     keychainService: Self.keychainService,
                     bookmarkDefaults: bookmarks,
                     testSession: session)
    }

    /// Installs the view in a hosting controller with no window, which is what
    /// makes @State live and .onAppear fire.
    @MainActor
    @discardableResult
    private func host(_ sut: SettingsView) -> NSHostingController<SettingsView> {
        let controller = NSHostingController(rootView: sut)
        controller.view.frame = NSRect(x: 0, y: 0, width: 460, height: 620)
        controller.view.layoutSubtreeIfNeeded()
        hosts.append(controller)
        return controller
    }

    /// One synchronous look at the live, hosted view.
    @MainActor
    private func visit(_ sut: SettingsView,
                       file: StaticString = #filePath, line: UInt = #line,
                       _ body: @escaping @MainActor @Sendable (InspectableView<ViewType.View<SettingsView>>) throws -> Void) {
        let exp = sut.inspection.inspect(function: #function, file: file, line: line) { view in
            try body(view)
        }
        wait(for: [exp], timeout: 5)
    }

    /// Spins the main run loop until the hosted view shows `text`, for results
    /// that arrive from an async Task.
    @MainActor
    private func awaitText(_ sut: SettingsView, _ text: String) -> Bool {
        for _ in 0..<80 {
            let found = Box(false)
            visit(sut) { view in
                found.value = (try? view.find(text: text)) != nil
            }
            if found.value { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func copilotToggle(in sut: SettingsView) throws -> InspectableView<ViewType.Toggle> {
        try sut.inspect().find(ViewType.Toggle.self, where: {
            try $0.labelView().text().string().contains("Copilot")
        })
    }

    // MARK: - Toggles and normalization (unhosted: bindings write straight to defaults)

    func testTappingTheCopilotToggleWritesTheDefault() throws {
        UserDefaults.standard.set(false, forKey: SettingsKeys.copilotEnabled)
        let sut = settingsView()
        try copilotToggle(in: sut).tap()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SettingsKeys.copilotEnabled))
    }

    func testTurningCopilotOffDropsACopilotMenuBarSelection() throws {
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
        UserDefaults.standard.set(MenuBarLabel.copilot.rawValue, forKey: SettingsKeys.menuBarLabel)
        let sut = settingsView()
        try copilotToggle(in: sut).tap()
        try sut.inspect().form().callOnChange(oldValue: true, newValue: false, index: 0)
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.menuBarLabel),
                       MenuBarLabel.highest.rawValue)
    }

    func testTurningOffScopedWeeklyDropsAScopedSelection() throws {
        UserDefaults.standard.set(true, forKey: SettingsKeys.showScopedWeekly)
        UserDefaults.standard.set(MenuBarLabel.weeklyScoped.rawValue, forKey: SettingsKeys.menuBarLabel)
        let sut = settingsView()
        try sut.inspect().find(ViewType.Toggle.self, where: {
            try $0.labelView().text().string().contains("model-specific")
        }).tap()
        try sut.inspect().form().callOnChange(oldValue: true, newValue: false, index: 1)
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.menuBarLabel),
                       MenuBarLabel.highest.rawValue)
    }

    // MARK: - Source changes notify the app (unhosted)

    func testChangingTheClaudeSourceNotifies() throws {
        let notified = Box(0)
        let sut = settingsView { notified.value += 1 }
        try sut.inspect().form().callOnChange(
            oldValue: CredentialSource.manual.rawValue,
            newValue: CredentialSource.importedFile.rawValue, index: 0)
        XCTAssertEqual(notified.value, 1)
    }

    func testChangingTheCopilotSourceNotifies() throws {
        let notified = Box(0)
        let sut = settingsView { notified.value += 1 }
        try sut.inspect().form().callOnChange(
            oldValue: CopilotCredentialSource.manual.rawValue,
            newValue: CopilotCredentialSource.importedFile.rawValue, index: 1)
        XCTAssertEqual(notified.value, 1)
    }

    // MARK: - Launch at login goes through the seam (unhosted)

    func testLaunchAtLoginChangesGoThroughTheSeam() throws {
        let calls = Box<[Bool]>([])
        var sut = settingsView()
        sut.setLaunchAtLogin = { calls.value.append($0) }
        let toggle = try sut.inspect().find(ViewType.Toggle.self, where: {
            try $0.labelView().text().string() == "Launch at login"
        })
        try toggle.callOnChange(oldValue: false, newValue: true, index: 0)
        try toggle.callOnChange(oldValue: true, newValue: false, index: 0)
        XCTAssertEqual(calls.value, [true, false])
    }

    func testLaunchAtLoginFailureRereadsTheRealStatus() throws {
        let statusReads = Box(0)
        var sut = settingsView()
        sut.setLaunchAtLogin = { _ in throw CocoaError(.featureUnsupported) }
        sut.launchAtLoginStatus = { statusReads.value += 1; return false }
        try sut.inspect().find(ViewType.Toggle.self, where: {
            try $0.labelView().text().string() == "Launch at login"
        }).callOnChange(oldValue: false, newValue: true, index: 0)
        XCTAssertEqual(statusReads.value, 1)
    }

    // MARK: - Popover toolbar (unhosted; its actions are injected closures)

    func testPopoverToolbarButtonsInvokeTheirActions() throws {
        let taps = Box<[String]>([])
        let view = PopoverView(state: AppState(),
                               onHoverChanged: { _ in },
                               onSettings: { taps.value.append("settings") },
                               onRefresh: { taps.value.append("refresh") },
                               onQuit: { taps.value.append("quit") })
        for name in ["arrow.clockwise", "gearshape", "power"] {
            try view.inspect().find(ViewType.Button.self, where: {
                (try? $0.labelView().image().actualImage().name()) == name
            }).tap()
        }
        XCTAssertEqual(taps.value, ["refresh", "settings", "quit"])
    }

    // MARK: - Stateful flows (hosted)

    @MainActor
    func testOnAppearPopulatesBothTokenFieldsFromTheKeychain() throws {
        _ = CredentialsProvider.saveManualToken("tok-claude", service: Self.keychainService)
        _ = CredentialsProvider.saveManualToken("tok-copilot", service: Self.keychainService,
                                                account: CopilotCredentialsProvider.manualAccount)
        UserDefaults.standard.set(CredentialSource.manual.rawValue, forKey: SettingsKeys.credentialSource)
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
        UserDefaults.standard.set(CopilotCredentialSource.manual.rawValue,
                                  forKey: SettingsKeys.copilotCredentialSource)
        let sut = settingsView()
        host(sut)
        visit(sut) { view in
            let inputs = try view.findAll(ViewType.SecureField.self).map { try $0.input() }
            XCTAssertEqual(inputs, ["tok-claude", "tok-copilot"])
        }
    }

    @MainActor
    func testSaveTokenWritesTheKeychainAndShowsSaved() throws {
        UserDefaults.standard.set(CredentialSource.manual.rawValue, forKey: SettingsKeys.credentialSource)
        let notified = Box(0)
        let sut = settingsView { notified.value += 1 }
        host(sut)
        visit(sut) { view in
            try view.find(ViewType.SecureField.self).setInput("fresh-token")
        }
        visit(sut) { view in
            try view.find(button: "Save Token").tap()
        }
        XCTAssertEqual(CredentialsProvider.readManualToken(service: Self.keychainService), "fresh-token")
        XCTAssertEqual(notified.value, 1)
        visit(sut) { view in
            XCTAssertNoThrow(try view.find(text: "Saved"))
        }
    }

    @MainActor
    func testCopilotSaveTokenWritesItsOwnSlotOnly() throws {
        UserDefaults.standard.set(CredentialSource.importedFile.rawValue, forKey: SettingsKeys.credentialSource)
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
        UserDefaults.standard.set(CopilotCredentialSource.manual.rawValue,
                                  forKey: SettingsKeys.copilotCredentialSource)
        let sut = settingsView()
        host(sut)
        visit(sut) { view in
            try view.find(ViewType.SecureField.self).setInput("cop-fresh")
        }
        visit(sut) { view in
            try view.find(button: "Save Token").tap()
        }
        XCTAssertEqual(CredentialsProvider.readManualToken(service: Self.keychainService,
                                                           account: CopilotCredentialsProvider.manualAccount),
                       "cop-fresh")
        XCTAssertNil(CredentialsProvider.readManualToken(service: Self.keychainService))
    }

    @MainActor
    func testForgetClearsTheImportAndNotifies() throws {
        UserDefaults.standard.set(CredentialSource.importedFile.rawValue, forKey: SettingsKeys.credentialSource)
        let dir = TestFixtures.tempDirectory()
        tempDirs.append(dir)
        let fileURL = dir.appendingPathComponent("creds.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8).write(to: fileURL)
        let claudeFile = ImportedCredentialFile(defaultsKey: SettingsKeys.claudeCredentialFile,
                                                describing: "Claude Code credentials",
                                                defaults: bookmarks)
        try claudeFile.store(fileURL)

        let notified = Box(0)
        let sut = settingsView { notified.value += 1 }
        host(sut)
        visit(sut) { view in
            try view.find(button: "Forget").tap()
        }
        XCTAssertFalse(claudeFile.hasImport)
        XCTAssertEqual(notified.value, 1)
        visit(sut) { view in
            XCTAssertThrowsError(try view.find(button: "Forget"))
        }
    }

    // MARK: - Test Connection, pressed for real (hosted, async)

    private let threeLimits = #"{"limits":[{"kind":"session","percent":24},{"kind":"weekly_all","percent":8},{"kind":"weekly_scoped","percent":19,"scope":{"model":{"display_name":"Fable"}}}]}"#

    @MainActor
    func testTestConnectionShowsTheVerdictFromARealFetch() throws {
        UserDefaults.standard.set(CredentialSource.manual.rawValue, forKey: SettingsKeys.credentialSource)
        _ = CredentialsProvider.saveManualToken("tok", service: Self.keychainService)
        let body = threeLimits
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let sut = settingsView(session: mockSession())
        host(sut)
        visit(sut) { view in
            try view.find(button: "Test Connection").tap()
        }
        XCTAssertTrue(awaitText(sut, "Connected — 3 limits reported"))
    }

    @MainActor
    func testTestConnectionFailureSurfacesTheError() throws {
        UserDefaults.standard.set(CredentialSource.manual.rawValue, forKey: SettingsKeys.credentialSource)
        _ = CredentialsProvider.saveManualToken("tok", service: Self.keychainService)
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401,
                             httpVersion: nil, headerFields: nil)!, Data())
        }
        let sut = settingsView(session: mockSession())
        host(sut)
        visit(sut) { view in
            try view.find(button: "Test Connection").tap()
        }
        XCTAssertTrue(awaitText(
            sut, "Not authorized — open Claude Code to refresh your login, or set a token in Settings."))
    }

    /// A stored source value this build has never heard of must act like
    /// manual-with-no-token: an inline error, and no network traffic at all.
    func testAnUnknownStoredSourceFallsBackToManualWithoutFetching() throws {
        UserDefaults.standard.set("bogus", forKey: SettingsKeys.credentialSource)
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
        UserDefaults.standard.set("bogus", forKey: SettingsKeys.copilotCredentialSource)
        let requests = Box(0)
        MockURLProtocol.handler = { request in
            requests.value += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 500,
                                    httpVersion: nil, headerFields: nil)!, Data())
        }
        let sut = settingsView(session: mockSession())
        // The per-source controls also read the unknown value and must fall
        // back to the manual arm (a SecureField), not render nothing.
        XCTAssertEqual(try sut.inspect().findAll(ViewType.SecureField.self).count, 2)
        for button in try sut.inspect().findAll(ViewType.Button.self, where: {
            (try? $0.labelView().text().string()) == "Test Connection"
        }) {
            try button.tap()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(requests.value, 0)
    }

    @MainActor
    func testOnAppearNormalizesUnknownStoredValues() throws {
        UserDefaults.standard.set("bogus", forKey: SettingsKeys.credentialSource)
        UserDefaults.standard.set("bogus", forKey: SettingsKeys.copilotCredentialSource)
        UserDefaults.standard.set("bogus", forKey: SettingsKeys.menuBarLabel)
        let sut = settingsView()
        host(sut)
        visit(sut) { _ in }
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.credentialSource),
                       CredentialSource.manual.rawValue)
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.copilotCredentialSource),
                       CopilotCredentialSource.manual.rawValue)
    }

    @MainActor
    func testCopilotForgetClearsItsOwnImport() throws {
        UserDefaults.standard.set(CredentialSource.manual.rawValue, forKey: SettingsKeys.credentialSource)
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
        UserDefaults.standard.set(CopilotCredentialSource.importedFile.rawValue,
                                  forKey: SettingsKeys.copilotCredentialSource)
        let dir = TestFixtures.tempDirectory()
        tempDirs.append(dir)
        let fileURL = dir.appendingPathComponent("apps.json")
        try Data(#"{"github.com:app":{"oauth_token":"gho_x"}}"#.utf8).write(to: fileURL)
        let copilotFile = ImportedCredentialFile(defaultsKey: SettingsKeys.copilotCredentialFile,
                                                 describing: "Copilot config",
                                                 defaults: bookmarks)
        try copilotFile.store(fileURL)

        let sut = settingsView()
        host(sut)
        visit(sut) { view in
            try view.find(button: "Forget").tap()
        }
        XCTAssertFalse(copilotFile.hasImport)
    }

    @MainActor
    func testCopilotTestConnectionFailureReadsAsAFailure() throws {
        UserDefaults.standard.set(CredentialSource.importedFile.rawValue, forKey: SettingsKeys.credentialSource)
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
        UserDefaults.standard.set(CopilotCredentialSource.manual.rawValue,
                                  forKey: SettingsKeys.copilotCredentialSource)
        _ = CredentialsProvider.saveManualToken("gho_bad", service: Self.keychainService,
                                                account: CopilotCredentialsProvider.manualAccount)
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401,
                             httpVersion: nil, headerFields: nil)!, Data())
        }
        let sut = settingsView(session: mockSession())
        host(sut)
        visit(sut) { view in
            let buttons = try view.findAll(ViewType.Button.self, where: {
                (try? $0.labelView().text().string()) == "Test Connection"
            })
            try buttons.last?.tap()
        }
        XCTAssertTrue(awaitText(
            sut, "GitHub token rejected — sign in to Copilot in your editor, or set a token in Settings."))
    }

    @MainActor
    func testCopilotTestConnectionShowsTheVerdict() throws {
        UserDefaults.standard.set(CredentialSource.importedFile.rawValue, forKey: SettingsKeys.credentialSource)
        UserDefaults.standard.set(true, forKey: SettingsKeys.copilotEnabled)
        UserDefaults.standard.set(CopilotCredentialSource.manual.rawValue,
                                  forKey: SettingsKeys.copilotCredentialSource)
        _ = CredentialsProvider.saveManualToken("gho_test", service: Self.keychainService,
                                                account: CopilotCredentialsProvider.manualAccount)
        let body = #"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"credits_used":75,"unlimited":false}}}"#
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let sut = settingsView(session: mockSession())
        host(sut)
        visit(sut) { view in
            // The Claude section's Test Connection comes first; Copilot's is last.
            let buttons = try view.findAll(ViewType.Button.self, where: {
                (try? $0.labelView().text().string()) == "Test Connection"
            })
            XCTAssertEqual(buttons.count, 2)
            try buttons.last?.tap()
        }
        XCTAssertTrue(awaitText(sut, "Connected — 75 of 300 credits used"))
    }
}
