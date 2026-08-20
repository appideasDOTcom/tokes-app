import XCTest

@testable import Tokes

/// The Settings import / forget flow, end to end into the credential providers.
///
/// No test can press a SwiftUI button — `NSHostingController` fires `.onAppear`
/// and nothing else — so the buttons' bodies were extracted to
/// `SettingsView.importOutcome` and `SettingsView.forget`. What stays in the
/// view is the open panel (a modal, permanently out of reach) and three lines
/// of `@State` assignment. What is tested here is everything those buttons
/// actually change: the bookmark the providers read on every poll.
final class SettingsImportTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var claudeFile: ImportedCredentialFile!
    private var copilotFile: ImportedCredentialFile!

    override func setUp() {
        super.setUp()
        directory = TestFixtures.tempDirectory()
        suite = "com.appideas.tokes.tests.settingsimport.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        // The same two files SettingsView builds, in a test-only domain.
        claudeFile = ImportedCredentialFile(defaultsKey: SettingsKeys.claudeCredentialFile,
                                            describing: "Claude Code credentials",
                                            defaults: defaults)
        copilotFile = ImportedCredentialFile(defaultsKey: SettingsKeys.copilotCredentialFile,
                                             describing: "Copilot config", defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeSuite(named: suite)
        super.tearDown()
    }

    @discardableResult
    private func write(_ body: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        return url
    }

    private func claudeJSON(_ token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":1786600000000}}"#
    }

    private func copilotJSON(_ token: String) -> String {
        #"{"github.com:Iv1.x":{"oauth_token":"\#(token)"}}"#
    }

    /// A provider wired exactly as the app wires it, pointed at the imported
    /// file — so these assertions run through the code a poll runs through,
    /// not through the file object directly.
    private func claudeProvider() -> CredentialsProvider {
        let provider = CredentialsProvider()
        provider.defaults = defaults
        provider.importedFile = claudeFile
        defaults.set(CredentialSource.importedFile.rawValue, forKey: SettingsKeys.credentialSource)
        return provider
    }

    private func copilotProvider() -> CopilotCredentialsProvider {
        let provider = CopilotCredentialsProvider()
        provider.defaults = defaults
        provider.importedFile = copilotFile
        defaults.set(CopilotCredentialSource.importedFile.rawValue,
                     forKey: SettingsKeys.copilotCredentialSource)
        return provider
    }

    // MARK: - import

    func testImportingAFileMakesItTheTokenTheAppPolls() throws {
        let url = try write(claudeJSON("tok-imported"), to: "creds.json")

        let outcome = SettingsView.importOutcome(picked: url, into: claudeFile)

        XCTAssertEqual(outcome, .imported(path: url.path))
        XCTAssertEqual(try claudeProvider().accessToken(), "tok-imported")
    }

    func testTheCopilotButtonImportsIntoTheCopilotSlot() throws {
        let url = try write(copilotJSON("gh-imported"), to: "apps.json")

        XCTAssertEqual(SettingsView.importOutcome(picked: url, into: copilotFile),
                       .imported(path: url.path))

        XCTAssertEqual(try copilotProvider().accessToken(), "gh-imported")
        // Two buttons that differ only in which file they write; a crossed
        // wire here would import Copilot's config as Claude's credentials.
        XCTAssertFalse(claudeFile.hasImport)
    }

    /// Choosing a second file replaces the first, rather than layering.
    func testImportingAgainReplacesThePreviousFile() throws {
        let first = try write(claudeJSON("tok-first"), to: "first.json")
        let second = try write(claudeJSON("tok-second"), to: "second.json")

        _ = SettingsView.importOutcome(picked: first, into: claudeFile)
        let outcome = SettingsView.importOutcome(picked: second, into: claudeFile)

        XCTAssertEqual(outcome, .imported(path: second.path))
        XCTAssertEqual(try claudeProvider().accessToken(), "tok-second")
    }

    /// A file that is not credentials still imports — the bookmark is stored
    /// and the *parse* is what fails, on the next poll and in Test Connection.
    /// Rejecting it at import time would need Settings to know both formats.
    func testAFileWithoutATokenImportsButFailsToParse() throws {
        let url = try write(#"{"something":"else"}"#, to: "wrong.json")

        XCTAssertEqual(SettingsView.importOutcome(picked: url, into: claudeFile),
                       .imported(path: url.path))
        XCTAssertThrowsError(try claudeProvider().accessToken()) { error in
            // Bookmark resolution canonicalizes /var -> /private/var.
            guard case .unparsable(let path) = error as? ImportedFileError else {
                return XCTFail("expected .unparsable, got \(error)")
            }
            XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                           url.resolvingSymlinksInPath().path)
        }
    }

    // MARK: - cancel and failure

    func testCancellingThePanelChangesNothing() throws {
        let url = try write(claudeJSON("tok-kept"), to: "creds.json")
        _ = SettingsView.importOutcome(picked: url, into: claudeFile)

        XCTAssertEqual(SettingsView.importOutcome(picked: nil, into: claudeFile), .cancelled)

        XCTAssertEqual(try claudeProvider().accessToken(), "tok-kept",
                       "a cancelled panel must not disturb the current import")
    }

    /// When the bookmark cannot be written the button reports why and leaves
    /// the working import in place — the alternative is a Settings pane
    /// showing a new path that nothing can read.
    func testAFailedImportKeepsTheWorkingOneAndSaysWhy() throws {
        let good = try write(claudeJSON("tok-good"), to: "good.json")
        _ = SettingsView.importOutcome(picked: good, into: claudeFile)

        claudeFile.makeBookmark = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let bad = try write(claudeJSON("tok-bad"), to: "bad.json")
        let outcome = SettingsView.importOutcome(picked: bad, into: claudeFile)

        guard case .failed(let message) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertFalse(message.isEmpty)
        claudeFile.makeBookmark = {
            try $0.bookmarkData(options: $1, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        XCTAssertEqual(try claudeProvider().accessToken(), "tok-good")
    }

    // MARK: - forget

    func testForgettingLeavesTheProviderWithAnActionableError() throws {
        let url = try write(claudeJSON("tok-1"), to: "creds.json")
        _ = SettingsView.importOutcome(picked: url, into: claudeFile)
        XCTAssertEqual(try claudeProvider().accessToken(), "tok-1")

        SettingsView.forget(claudeFile)

        XCTAssertFalse(claudeFile.hasImport)
        XCTAssertNil(defaults.data(forKey: SettingsKeys.claudeCredentialFile))
        XCTAssertThrowsError(try claudeProvider().accessToken()) { error in
            XCTAssertEqual(error as? ImportedFileError, .notImported("Claude Code credentials"))
            XCTAssertTrue(error.localizedDescription.contains("Settings"),
                          "the message has to say where to fix it")
        }
    }

    func testForgettingOneProviderLeavesTheOtherImported() throws {
        _ = SettingsView.importOutcome(picked: try write(claudeJSON("c"), to: "c.json"),
                                       into: claudeFile)
        _ = SettingsView.importOutcome(picked: try write(copilotJSON("g"), to: "g.json"),
                                       into: copilotFile)

        SettingsView.forget(claudeFile)

        XCTAssertFalse(claudeFile.hasImport)
        XCTAssertTrue(copilotFile.hasImport)
        XCTAssertEqual(try copilotProvider().accessToken(), "g")
    }

    /// Forgetting when nothing is imported is a no-op, not a crash — the
    /// button is hidden in that state, but the state is reachable by forgetting
    /// twice before the view redraws.
    func testForgettingTwiceIsHarmless() throws {
        _ = SettingsView.importOutcome(picked: try write(claudeJSON("c"), to: "c.json"),
                                       into: claudeFile)
        SettingsView.forget(claudeFile)
        SettingsView.forget(claudeFile)
        XCTAssertFalse(claudeFile.hasImport)
    }
}
