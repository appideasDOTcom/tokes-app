import XCTest

@testable import Tokes

/// The user-imported credentials file: bookmark persistence, re-reading after
/// rotation, and the two providers' parsers on top of it. This is the only
/// automatic credential path the App Store build ships, so it carries the weight
/// the Claude Code / editor readers carry in the direct build.
final class ImportedCredentialFileTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private let suite = "com.appideas.tokes.tests.importedfile"
    private var file: ImportedCredentialFile!

    override func setUp() {
        super.setUp()
        directory = TestFixtures.tempDirectory()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        file = ImportedCredentialFile(defaultsKey: "testBookmark", describing: "test credentials",
                                      defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    @discardableResult
    private func write(_ body: String, to name: String = "creds.json") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        return url
    }

    private func claudeCredentials(token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":1786600000000}}"#
    }

    // MARK: - Bookmark lifecycle

    func testNothingImportedByDefault() {
        XCTAssertFalse(file.hasImport)
        XCTAssertNil(file.displayPath)
        XCTAssertThrowsError(try file.read()) { error in
            XCTAssertEqual(error as? ImportedFileError, .notImported("test credentials"))
        }
    }

    func testStoreThenReadRoundTrips() throws {
        let url = try write(claudeCredentials(token: "tok-1"))
        try file.store(url)

        XCTAssertTrue(file.hasImport)
        // Bookmark resolution returns the canonical path (/var -> /private/var).
        XCTAssertEqual(file.displayPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       url.resolvingSymlinksInPath().path)
        XCTAssertEqual(String(data: try file.read(), encoding: .utf8), claudeCredentials(token: "tok-1"))
    }

    /// The reason a bookmark is stored rather than the file's contents: the tool
    /// that owns the file rotates the token, and Tokes has to follow it.
    func testRereadPicksUpARotatedToken() throws {
        let url = try write(claudeCredentials(token: "tok-1"))
        try file.store(url)
        XCTAssertEqual(try CredentialsProvider.loadImportedToken(from: file).0, "tok-1")

        try write(claudeCredentials(token: "tok-2"))
        XCTAssertEqual(try CredentialsProvider.loadImportedToken(from: file).0, "tok-2")
    }

    /// Credential writers replace the file rather than truncating it, which
    /// gives the new contents a new inode. The bookmark has to survive that.
    func testRereadSurvivesAnAtomicReplacement() throws {
        let url = try write(claudeCredentials(token: "tok-1"))
        try file.store(url)
        XCTAssertEqual(try CredentialsProvider.loadImportedToken(from: file).0, "tok-1")

        try Data(claudeCredentials(token: "tok-rotated").utf8).write(to: url, options: .atomic)
        XCTAssertEqual(try CredentialsProvider.loadImportedToken(from: file).0, "tok-rotated")
    }

    func testBookmarkPersistsAcrossInstances() throws {
        let url = try write(claudeCredentials(token: "tok-1"))
        try file.store(url)

        let reopened = ImportedCredentialFile(defaultsKey: "testBookmark", describing: "test credentials",
                                              defaults: defaults)
        XCTAssertTrue(reopened.hasImport)
        XCTAssertEqual(try CredentialsProvider.loadImportedToken(from: reopened).0, "tok-1")
    }

    func testClearForgetsTheFile() throws {
        try file.store(try write(claudeCredentials(token: "tok-1")))
        file.clear()

        XCTAssertFalse(file.hasImport)
        XCTAssertNil(defaults.data(forKey: "testBookmark"))
        XCTAssertThrowsError(try file.read())
    }

    func testDeletedFileSurfacesAnActionableError() throws {
        let url = try write(claudeCredentials(token: "tok-1"))
        try file.store(url)
        try FileManager.default.removeItem(at: url)

        XCTAssertThrowsError(try file.read()) { error in
            guard let error = error as? ImportedFileError else {
                return XCTFail("expected ImportedFileError, got \(error)")
            }
            XCTAssertTrue(error.errorDescription!.contains("Settings"))
        }
    }

    func testTwoProvidersKeepSeparateBookmarks() throws {
        let claude = ImportedCredentialFile(defaultsKey: SettingsKeys.claudeCredentialFile,
                                            describing: "Claude", defaults: defaults)
        let copilot = ImportedCredentialFile(defaultsKey: SettingsKeys.copilotCredentialFile,
                                             describing: "Copilot", defaults: defaults)
        try claude.store(try write(claudeCredentials(token: "claude-tok"), to: "claude.json"))
        try copilot.store(try write(#"{"github.com:Iv1.x":{"oauth_token":"gh-tok"}}"#, to: "apps.json"))

        XCTAssertEqual(try CredentialsProvider.loadImportedToken(from: claude).0, "claude-tok")
        XCTAssertEqual(try CopilotCredentialsProvider.loadImportedToken(from: copilot), "gh-tok")
    }

    // MARK: - Parsing on top of the imported file

    func testClaudeTokenAndExpiryComeThrough() throws {
        try file.store(try write(claudeCredentials(token: "tok-1")))
        let (token, expiry) = try CredentialsProvider.loadImportedToken(from: file)
        XCTAssertEqual(token, "tok-1")
        XCTAssertEqual(expiry?.timeIntervalSince1970 ?? 0, 1_786_600_000, accuracy: 0.001)
    }

    func testWrongFileTypeIsRejectedRatherThanMisread() throws {
        try file.store(try write(#"{"some":"other json"}"#))
        XCTAssertThrowsError(try CredentialsProvider.loadImportedToken(from: file)) { error in
            guard let error = error as? ImportedFileError else {
                return XCTFail("expected ImportedFileError, got \(error)")
            }
            XCTAssertTrue(error.errorDescription!.contains("usable token"))
        }
        XCTAssertThrowsError(try CopilotCredentialsProvider.loadImportedToken(from: file))
    }

    func testCopilotHostsJsonShapeAlsoParses() throws {
        try file.store(try write(#"{"github.com":{"oauth_token":"gho_hosts"}}"#))
        XCTAssertEqual(try CopilotCredentialsProvider.loadImportedToken(from: file), "gho_hosts")
    }

    func testErrorDescriptionsAreUserFacing() {
        XCTAssertNotNil(ImportedFileError.notImported("x").errorDescription)
        XCTAssertNotNil(ImportedFileError.unreadable("/x").errorDescription)
        XCTAssertNotNil(ImportedFileError.unparsable("/x").errorDescription)
        XCTAssertNotNil(CredentialError.sourceUnavailable.errorDescription)
    }

    /// The open panel is pointed at the real home, which the sandbox hides from
    /// `homeDirectoryForCurrentUser`. Unsandboxed the two agree.
    func testRealHomeIsAnAbsoluteUsersPath() {
        XCTAssertTrue(RealHome.url.path.hasPrefix("/"))
        XCTAssertFalse(RealHome.url.path.isEmpty)
    }
}
