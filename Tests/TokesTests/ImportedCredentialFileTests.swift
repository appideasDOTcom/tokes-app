import XCTest

@testable import Tokes

/// The user-imported credentials file: bookmark persistence, re-reading after
/// rotation, and the two providers' parsers on top of it. This is the only
/// automatic credential path the App Store build ships, so it carries the weight
/// the Claude Code / editor readers carry in the direct build.
final class ImportedCredentialFileTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    // UUID rather than a fixed name: classes run in separate processes under
    // `swift test --parallel` but share suite files on disk, so a fixed name
    // has two workers writing the same bookmark key.
    private let suite = "com.appideas.tokes.tests.importedfile.\(UUID().uuidString)"
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

/// The security-scoped half of the bookmark, which is the part the App Store
/// build depends on and the part no test could reach before `makeBookmark` and
/// `beginAccess` existed. An unsandboxed test process is granted a
/// security-scoped bookmark for any file it can read, so the fallback and the
/// revoked-grant arms are unreachable without forcing them.
final class ImportedFileBookmarkScopeTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var file: ImportedCredentialFile!
    private let key = "scopeBookmark"

    override func setUp() {
        super.setUp()
        directory = TestFixtures.tempDirectory()
        suite = "com.appideas.tokes.tests.bookmarkscope.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        file = ImportedCredentialFile(defaultsKey: key, describing: "test credentials",
                                      defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeSuite(named: suite)
        super.tearDown()
    }

    @discardableResult
    private func write(_ body: String, to name: String = "creds.json") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        return url
    }

    /// Rejects security-scoped bookmark creation, the way a volume that does
    /// not support them does, and records every option set it was asked for.
    private func refuseSecurityScope() -> () -> [URL.BookmarkCreationOptions] {
        let box = OptionsBox()
        file.makeBookmark = { url, options in
            box.append(options)
            if options.contains(.withSecurityScope) {
                throw CocoaError(.fileWriteUnsupportedScheme)
            }
            return try url.bookmarkData(options: options,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return { box.all }
    }

    private final class OptionsBox {
        private let lock = NSLock()
        private var seen: [URL.BookmarkCreationOptions] = []
        func append(_ o: URL.BookmarkCreationOptions) { lock.lock(); seen.append(o); lock.unlock() }
        var all: [URL.BookmarkCreationOptions] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    // MARK: - first import

    /// A first import may legitimately fall back to a plain bookmark, and the
    /// file must stay readable through it — resolution then passes no options
    /// and opens no scope.
    func testAFirstImportFallsBackToAPlainBookmarkAndStillReads() throws {
        let options = refuseSecurityScope()
        let url = try write("{}")

        try file.store(url)

        XCTAssertEqual(options().count, 2, "scoped attempted first, then plain")
        XCTAssertTrue(options()[0].contains(.withSecurityScope))
        XCTAssertFalse(options()[1].contains(.withSecurityScope))
        XCTAssertTrue(file.hasImport)
        XCTAssertEqual(String(data: try file.read(), encoding: .utf8), "{}")
    }

    /// A plain bookmark must not try to open a scope it never obtained —
    /// `startAccessingSecurityScopedResource` on one returns false, which would
    /// read as a revoked grant.
    func testAPlainBookmarkNeverOpensASecurityScope() throws {
        _ = refuseSecurityScope()
        try file.store(try write("{}"))
        var beginAccessCalls = 0
        file.beginAccess = { _ in beginAccessCalls += 1; return false }

        XCTAssertEqual(String(data: try file.read(), encoding: .utf8), "{}")
        XCTAssertEqual(beginAccessCalls, 0, "a plain bookmark has no scope to open")
    }

    // MARK: - the refresh rule

    /// The §4.8 downgrade. An atomic replacement makes the bookmark stale, and
    /// the refresh that follows must not turn a security-scoped grant into a
    /// plain bookmark — that trades access surviving relaunch for access that
    /// does not, and the failure shows up much later with nothing to connect it
    /// to. Failing the re-save leaves the old scoped bookmark in place instead.
    func testAStaleRefreshWillNotDowngradeAScopedGrant() throws {
        let url = try write("v1")
        try file.store(url)
        let scopedBookmark = defaults.data(forKey: key)
        XCTAssertNotNil(scopedBookmark)

        // Replace the file the way a credential writer does, so the bookmark
        // resolves stale on the next read.
        let options = refuseSecurityScope()
        try Data("v2".utf8).write(to: url, options: .atomic)

        XCTAssertEqual(String(data: try file.read(), encoding: .utf8), "v2",
                       "the file must still be readable through the stale bookmark")
        XCTAssertEqual(defaults.data(forKey: key), scopedBookmark,
                       "a failed scoped re-save must leave the scoped bookmark alone")
        XCTAssertFalse(options().contains { !$0.contains(.withSecurityScope) },
                       "the refresh must never fall back to a plain bookmark")
    }

    /// The same path when the re-save succeeds: the bookmark is replaced, and
    /// it is replaced with another scoped one.
    func testAStaleRefreshRewritesTheBookmarkWhenItCan() throws {
        let url = try write("v1")
        try file.store(url)
        let first = defaults.data(forKey: key)

        let box = OptionsBox()
        file.makeBookmark = { url, options in
            box.append(options)
            return try url.bookmarkData(options: options,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        try Data("v2".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(String(data: try file.read(), encoding: .utf8), "v2")

        XCTAssertEqual(box.all.count, 1, "one re-save on the stale read")
        XCTAssertTrue(box.all[0].contains(.withSecurityScope))
        XCTAssertNotEqual(defaults.data(forKey: key), first, "the stale bookmark was replaced")
        // And the replacement is usable on a fresh instance, i.e. across launches.
        let reopened = ImportedCredentialFile(defaultsKey: key, describing: "test credentials",
                                              defaults: defaults)
        XCTAssertEqual(String(data: try reopened.read(), encoding: .utf8), "v2")
    }

    // MARK: - a revoked grant

    /// The grant is gone — the extension no longer covers the file. This is the
    /// arm that tells the user to import again rather than failing silently.
    func testARevokedGrantSurfacesAsUnreadable() throws {
        let url = try write("{}")
        try file.store(url)
        file.beginAccess = { _ in false }

        XCTAssertThrowsError(try file.read()) { error in
            guard case .unreadable(let path) = error as? ImportedFileError else {
                return XCTFail("expected .unreadable, got \(error)")
            }
            // The message names the file, not the generic description — the
            // user needs to know *which* import stopped working.
            XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                           url.resolvingSymlinksInPath().path)
        }
    }

    /// Resolution succeeds and the scope opens, but the bytes cannot be read —
    /// the file is there and the process is not allowed to have it.
    func testAnUnreadableFileSurfacesAsUnreadableRatherThanEmpty() throws {
        let url = try write("{}")
        try file.store(url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: url.path) }

        XCTAssertThrowsError(try file.read()) { error in
            guard case .unreadable = error as? ImportedFileError else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }
}
