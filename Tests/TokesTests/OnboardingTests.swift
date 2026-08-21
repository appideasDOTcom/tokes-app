import AppKit
import SwiftUI
import ViewInspector
import XCTest

@testable import Tokes

/// The Claude Code export commands are the product here: the App Store build's
/// only automatic Claude path is the file the *user* exports, so the command
/// Settings tells them to run — and the hook that keeps it fresh — are tested
/// functionally, against a stubbed `security`, not just as strings.
final class ClaudeCodeExportTests: XCTestCase {
    private var home: URL!
    private var bin: URL!

    /// The credentials file inside the stand-in home directory.
    private var exported: URL {
        home.appendingPathComponent(".claude/tokes-credentials.json")
    }

    private let fixtureJSON = #"{"claudeAiOauth":{"accessToken":"tok-stub","expiresAt":4102444800000}}"#

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = TestFixtures.tempDirectory()
        bin = TestFixtures.tempDirectory()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: bin)
        super.tearDown()
    }

    /// Puts a fake `security` first on PATH, so the commands run for real
    /// without touching the login keychain.
    private func installStubSecurity(_ script: String) throws {
        let url = bin.appendingPathComponent("security")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Runs a command the way the user's shell (or Claude Code's hook runner)
    /// would, with HOME pointed at the stand-in so `~` lands in the sandbox.
    private func run(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path + ":/usr/bin:/bin"
        environment["HOME"] = home.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - The strings themselves

    func testExportCommandNamesTheRealKeychainItemAndDestination() {
        XCTAssertTrue(ClaudeCodeExport.exportCommand.contains("-s \"Claude Code-credentials\""),
                      "must read the item Claude Code actually writes")
        XCTAssertTrue(ClaudeCodeExport.exportCommand.contains("-w"))
        XCTAssertTrue(ClaudeCodeExport.exportCommand.contains(ClaudeCodeExport.exportedFilePath))
        XCTAssertTrue(ClaudeCodeExport.exportCommand.contains("chmod 600"),
                      "the file holds a live OAuth token")
    }

    /// The hook and the export must write the same file, and it must be the
    /// one the import panel's help names — three strings that would otherwise
    /// drift apart silently.
    func testExportHookAndDocumentedPathAllAgree() {
        XCTAssertEqual(ClaudeCodeExport.exportedFilePath, "~/.claude/tokes-credentials.json")
        XCTAssertTrue(ClaudeCodeExport.exportedFilePath.hasSuffix(ClaudeCodeExport.exportedFileName))
        XCTAssertTrue(ClaudeCodeExport.hookCommand.contains(ClaudeCodeExport.exportedFilePath))
    }

    func testHookSnippetIsValidJSONWiringTheHookCommand() throws {
        let data = Data(ClaudeCodeExport.hookSnippet.utf8)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStart.count, 1)
        XCTAssertEqual(sessionStart[0]["matcher"] as? String, "*")
        let inner = try XCTUnwrap(sessionStart[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.count, 1)
        XCTAssertEqual(inner[0]["type"] as? String, "command")
        XCTAssertEqual(inner[0]["command"] as? String, ClaudeCodeExport.hookCommand)
    }

    // MARK: - Running them

    func testExportCommandWritesAParseableOwnerOnlyFile() throws {
        try installStubSecurity("echo '\(fixtureJSON)'")

        XCTAssertEqual(try run(ClaudeCodeExport.exportCommand), 0)

        let parsed = CredentialsProvider.parseClaudeCredentials(try Data(contentsOf: exported))
        XCTAssertEqual(parsed?.0, "tok-stub")
        let attrs = try FileManager.default.attributesOfItem(atPath: exported.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testHookCommandRefreshesTheFileOnSuccess() throws {
        try Data(#"{"claudeAiOauth":{"accessToken":"tok-old"}}"#.utf8).write(to: exported)
        try installStubSecurity("echo '\(fixtureJSON)'")

        XCTAssertEqual(try run(ClaudeCodeExport.hookCommand), 0)

        let parsed = CredentialsProvider.parseClaudeCredentials(try Data(contentsOf: exported))
        XCTAssertEqual(parsed?.0, "tok-stub", "the hook must pick up the rotated token")
    }

    /// A user can install the hook without ever running the manual export —
    /// the file the hook then *creates* must still be owner-only.
    func testHookCommandCreatesAFreshFileOwnerOnly() throws {
        try installStubSecurity("echo '\(fixtureJSON)'")

        XCTAssertEqual(try run(ClaudeCodeExport.hookCommand), 0)

        let attrs = try FileManager.default.attributesOfItem(atPath: exported.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    /// The trap the hook's shape exists to avoid: a plain `>` redirect
    /// truncates the working export to zero bytes the moment the user is
    /// signed out, replacing "token expired" with "file doesn't contain a
    /// usable token". The hook may only touch the file when the keychain read
    /// succeeds — and must still exit 0, so it never reads as a failing hook.
    func testHookCommandLeavesTheFileAloneWhenSignedOut() throws {
        try Data(fixtureJSON.utf8).write(to: exported)
        try installStubSecurity("exit 1")

        XCTAssertEqual(try run(ClaudeCodeExport.hookCommand), 0,
                       "a signed-out session must not report a failing hook")

        XCTAssertEqual(String(data: try Data(contentsOf: exported), encoding: .utf8), fixtureJSON,
                       "a failed keychain read must not clobber the working export")
    }
}

/// The staleness gate on the imported file: a recorded expiry in the past
/// fails at load, with a message that says what to do, rather than surfacing
/// as the server's bare 401.
final class ImportedCredentialExpiryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private let suite = "com.appideas.tokes.tests.importexpiry.\(UUID().uuidString)"
    private var file: ImportedCredentialFile!

    override func setUp() {
        super.setUp()
        directory = TestFixtures.tempDirectory()
        defaults = UserDefaults(suiteName: suite)
        file = ImportedCredentialFile(defaultsKey: "expiryBookmark", describing: "test credentials",
                                      defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Imports a credentials fixture whose expiry is `expiresAtMs` (absent when nil).
    private func importFixture(expiresAtMs: Double?) throws {
        let body: String
        if let expiresAtMs {
            body = #"{"claudeAiOauth":{"accessToken":"tok-x","expiresAt":\#(expiresAtMs)}}"#
        } else {
            body = #"{"claudeAiOauth":{"accessToken":"tok-x"}}"#
        }
        let url = directory.appendingPathComponent("creds.json")
        try Data(body.utf8).write(to: url)
        try file.store(url)
    }

    func testAnExpiredImportFailsWithGuidanceRatherThanA401() throws {
        try importFixture(expiresAtMs: 1_000_000)  // expiry at t=1000s
        let now = Date(timeIntervalSince1970: 2_000)

        XCTAssertThrowsError(try CredentialsProvider.loadImportedToken(from: file, now: now)) { error in
            XCTAssertEqual(error as? CredentialError, .importedExpired)
            let message = (error as? CredentialError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("Claude Code"), "the fix must be named: \(message)")
            XCTAssertTrue(message.contains("Settings"), "and where to find it: \(message)")
        }
    }

    func testExpiryExactlyNowCountsAsExpired() throws {
        try importFixture(expiresAtMs: 2_000_000)
        XCTAssertThrowsError(try CredentialsProvider.loadImportedToken(
            from: file, now: Date(timeIntervalSince1970: 2_000)))
    }

    func testAFutureExpiryPassesThrough() throws {
        try importFixture(expiresAtMs: 3_000_000)
        let (token, expiry) = try CredentialsProvider.loadImportedToken(
            from: file, now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(token, "tok-x")
        XCTAssertEqual(expiry?.timeIntervalSince1970 ?? 0, 3_000, accuracy: 0.001)
    }

    /// A hand-made token file with no recorded expiry is legitimate — only a
    /// *known-past* expiry may fail the load.
    func testAMissingExpiryIsNotTreatedAsExpired() throws {
        try importFixture(expiresAtMs: nil)
        let (token, expiry) = try CredentialsProvider.loadImportedToken(from: file, now: Date())
        XCTAssertEqual(token, "tok-x")
        XCTAssertNil(expiry)
    }
}

/// First-run detection: decided from the persistent domain by name, because
/// the registration domain is process-global — `registerDefaults` anywhere in
/// this process makes every key read as set through `object(forKey:)`.
final class FirstRunTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TokesTests-firstrun-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAFreshInstallIsAFirstRun() {
        XCTAssertTrue(AppDelegate.isFirstRun(domainName: suiteName))
    }

    func testTheMarkerEndsFirstRunForGood() {
        defaults.set(true, forKey: SettingsKeys.didCompleteFirstRun)
        XCTAssertFalse(AppDelegate.isFirstRun(domainName: suiteName))
    }

    /// An upgrade install predates the marker key entirely — any persisted
    /// configuration is the evidence that keeps Settings from popping open
    /// once after the update.
    func testAnyPersistedConfigurationCountsAsAPriorRun() {
        let evidence: [(String, Any)] = [
            (SettingsKeys.credentialSource, CredentialSource.manual.rawValue),
            (SettingsKeys.copilotEnabled, true),
            (SettingsKeys.menuBarLabel, MenuBarLabel.session.rawValue),
            (SettingsKeys.legacyShowLabel, false),
            (SettingsKeys.claudeCredentialFile, Data([1, 2, 3])),
            (SettingsKeys.copilotCredentialFile, Data([4, 5, 6])),
        ]
        for (key, value) in evidence {
            defaults.set(value, forKey: key)
            XCTAssertFalse(AppDelegate.isFirstRun(domainName: suiteName), key)
            defaults.removeObject(forKey: key)
        }
        XCTAssertTrue(AppDelegate.isFirstRun(domainName: suiteName), "evidence fully removed")
    }

    /// The trap the persistent-domain read exists for: registration is
    /// volatile and process-global, so factory defaults must never read as
    /// user configuration.
    func testRegisteredFactoryDefaultsDoNotCountAsConfiguration() {
        AppDelegate.registerDefaults(in: defaults)
        XCTAssertTrue(AppDelegate.isFirstRun(domainName: suiteName))
    }
}

/// The popover's first-run affordance: with nothing polled and an error, the
/// way into Settings is a labeled button, not just the gear icon.
@MainActor
final class PopoverOnboardingTests: XCTestCase {
    private final class Counter {
        var count = 0
    }

    private func popover(state: AppState, onSettings: @escaping () -> Void = {}) -> PopoverView {
        PopoverView(state: state, onHoverChanged: { _ in }, onSettings: onSettings,
                    onRefresh: {}, onQuit: {})
    }

    /// The presence case is asserted on the rendered view. This is also the
    /// only state ViewInspector can traverse: a snapshot brings `UsageChart`,
    /// whose Charts-framework internals SIGTRAP when a `find` evaluates their
    /// GeometryReader outside a live rendering context.
    func testASetupErrorWithNothingPolledOffersSettings() throws {
        let state = AppState()
        state.errorMessage = CredentialError.notFound.errorDescription
        let counter = Counter()
        let view = popover(state: state, onSettings: { counter.count += 1 })

        let button = try view.inspect().find(button: "Open Settings…")
        try button.tap()
        XCTAssertEqual(counter.count, 1)
    }

    /// The absence cases are pinned on the view's own decision function —
    /// inspecting a snapshot-bearing popover crashes in Charts (see above),
    /// and the condition is exactly what these cases are about: once data has
    /// flowed, an error is a hiccup, not a setup problem.
    func testAnErrorAfterDataFlowsKeepsTheCompactBanner() {
        let snapshot = UsageSnapshot(limits: [
            TestFixtures.limit(id: "session", label: "Session (5 hr)", percent: 24,
                               resetsAt: Date().addingTimeInterval(3600), isSession: true)
        ], fetchedAt: Date())

        XCTAssertFalse(PopoverView.offersSettingsShortcut(snapshot: snapshot,
                                                          error: "Usage API rate-limited"))
        XCTAssertFalse(PopoverView.offersSettingsShortcut(snapshot: snapshot, error: nil))
        XCTAssertFalse(PopoverView.offersSettingsShortcut(snapshot: nil, error: nil))
        XCTAssertTrue(PopoverView.offersSettingsShortcut(snapshot: nil, error: "no credentials"))
    }
}

/// The Settings walkthrough for the imported-file source: the export command
/// (and its Copy button) must actually render where a user with no file yet
/// will see them.
@MainActor
final class SettingsClaudeGuidanceTests: XCTestCase {
    static let keychainService = "com.appideas.tokes.tests"
    private var bookmarksName: String!
    private var bookmarks: UserDefaults!

    override func setUp() {
        super.setUp()
        bookmarksName = "com.appideas.tokes.tests.guidance.\(UUID().uuidString)"
        bookmarks = UserDefaults(suiteName: bookmarksName)
        UserDefaults.standard.set(CredentialSource.importedFile.rawValue,
                                  forKey: SettingsKeys.credentialSource)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.credentialSource)
        UserDefaults.standard.removePersistentDomain(forName: bookmarksName)
        super.tearDown()
    }

    private func settingsView() -> SettingsView {
        SettingsView(onCredentialsChanged: {}, keychainService: Self.keychainService,
                     bookmarkDefaults: bookmarks)
    }

    func testTheWalkthroughShowsTheExportCommandBeforeAnyImport() throws {
        let view = settingsView()
        XCTAssertNoThrow(try view.inspect().find(text: ClaudeCodeExport.exportCommand))
        XCTAssertNoThrow(try view.inspect().find(button: "Choose File…"))
    }

    func testTheHookSnippetIsReachableFromTheWalkthrough() throws {
        let view = settingsView()
        XCTAssertNoThrow(try view.inspect().find(text: ClaudeCodeExport.hookSnippet))
    }
}
