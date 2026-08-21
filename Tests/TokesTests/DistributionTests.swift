import XCTest

@testable import Tokes

/// The distribution/capability layer. Every assertion here is written against
/// an explicit `Distribution` rather than `.current`, so both flavors' rules are
/// checked whichever configuration the suite is compiled in — and the handful
/// that *do* read `.current` prove the compile flag is wired to the value.
final class DistributionCapabilityTests: XCTestCase {
    func testDirectBuildMayReadForeignCredentialStores() {
        XCTAssertTrue(Capabilities.canReadForeignCredentialStores(.direct))
        XCTAssertTrue(Capabilities.canRunHelperTools(.direct))
    }

    /// Guideline 2.5.2: no reading data outside the container. This is the whole
    /// compliance claim, reduced to two booleans.
    func testAppStoreBuildMayNotReadForeignCredentialStores() {
        XCTAssertFalse(Capabilities.canReadForeignCredentialStores(.appStore))
        XCTAssertFalse(Capabilities.canRunHelperTools(.appStore))
    }

    func testDebugLogStaysOutOfTmpForTheAppStoreBuild() {
        XCTAssertEqual(Capabilities.debugLogURL(.direct).path, "/tmp/tokes-debug.log")
        // /tmp is unwritable under the sandbox; the container's temp dir is not.
        XCTAssertFalse(Capabilities.debugLogURL(.appStore).path.hasPrefix("/tmp/"))
        XCTAssertEqual(Capabilities.debugLogURL(.appStore).lastPathComponent, "tokes-debug.log")
    }

    /// `Distribution.current` must follow the compile flag, not a default.
    func testCurrentFlavorMatchesCompileFlag() {
        #if TOKES_APP_STORE
            XCTAssertEqual(Distribution.current, .appStore)
            XCTAssertFalse(Capabilities.canReadForeignCredentialStores())
            XCTAssertFalse(Capabilities.canRunHelperTools())
        #else
            XCTAssertEqual(Distribution.current, .direct)
            XCTAssertTrue(Capabilities.canReadForeignCredentialStores())
            XCTAssertTrue(Capabilities.canRunHelperTools())
        #endif
    }
}

/// The build-vs-runtime consistency check, over all four combinations.
final class SandboxAuditTests: XCTestCase {
    func testConsistentCombinationsReportNoMismatch() {
        XCTAssertNil(SandboxAudit.mismatch(distribution: .appStore, sandboxed: true))
        XCTAssertNil(SandboxAudit.mismatch(distribution: .direct, sandboxed: false))
    }

    func testAppStoreBuildWithoutSandboxIsReported() {
        let message = SandboxAudit.mismatch(distribution: .appStore, sandboxed: false)
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("app-sandbox"))
    }

    func testDirectBuildInsideSandboxIsReported() {
        let message = SandboxAudit.mismatch(distribution: .direct, sandboxed: true)
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("sandboxed"))
    }

    /// The test binary is never sandboxed, so this pins the detector's negative
    /// case; the positive case is covered by scripts/verify-appstore.sh, which
    /// runs a real sandboxed bundle.
    func testDetectorReportsUnsandboxedForTheTestRunner() {
        XCTAssertFalse(SandboxAudit.isSandboxed)
    }
}

/// Which credential sources each flavor offers.
final class CredentialSourceAvailabilityTests: XCTestCase {
    func testDirectBuildOffersEveryClaudeSource() {
        XCTAssertEqual(CredentialSource.available(for: .direct), [.claudeCode, .importedFile, .manual])
        XCTAssertEqual(CredentialSource.defaultSource(for: .direct), .claudeCode)
    }

    func testAppStoreBuildDropsTheClaudeCodeReader() {
        XCTAssertEqual(CredentialSource.available(for: .appStore), [.importedFile, .manual])
        XCTAssertFalse(CredentialSource.available(for: .appStore).contains(.claudeCode))
        XCTAssertEqual(CredentialSource.defaultSource(for: .appStore), .importedFile)
    }

    func testDirectBuildOffersEveryCopilotSource() {
        XCTAssertEqual(CopilotCredentialSource.available(for: .direct),
                       [.githubApp, .editor, .importedFile, .manual])
        // The default stays `.editor`, not the recommended sign-in: existing
        // direct-build installs work with zero setup on it, and flipping their
        // default to a source that needs a sign-in would break them.
        XCTAssertEqual(CopilotCredentialSource.defaultSource(for: .direct), .editor)
    }

    func testAppStoreBuildDropsTheEditorReader() {
        XCTAssertEqual(CopilotCredentialSource.available(for: .appStore),
                       [.githubApp, .importedFile, .manual])
        XCTAssertFalse(CopilotCredentialSource.available(for: .appStore).contains(.editor))
        XCTAssertEqual(CopilotCredentialSource.defaultSource(for: .appStore), .githubApp)
    }

    /// Settings carried in from a direct build must not leave the App Store
    /// build pointing at a reader it doesn't ship.
    func testUnavailableSourceNormalizesToThisBuildsDefault() {
        XCTAssertEqual(CredentialSource.claudeCode.normalized(for: .appStore), .importedFile)
        XCTAssertEqual(CopilotCredentialSource.editor.normalized(for: .appStore), .githubApp)
    }

    func testAvailableSourcesAreLeftAlone() {
        for source in CredentialSource.available(for: .appStore) {
            XCTAssertEqual(source.normalized(for: .appStore), source)
        }
        for source in CredentialSource.available(for: .direct) {
            XCTAssertEqual(source.normalized(for: .direct), source)
        }
        for source in CopilotCredentialSource.available(for: .appStore) {
            XCTAssertEqual(source.normalized(for: .appStore), source)
        }
    }

    func testEverySourceHasADistinctTitle() {
        let claude = Set(CredentialSource.allCases.map(\.displayName))
        XCTAssertEqual(claude.count, CredentialSource.allCases.count)
        let copilot = Set(CopilotCredentialSource.allCases.map(\.displayName))
        XCTAssertEqual(copilot.count, CopilotCredentialSource.allCases.count)
    }
}

/// Reading the stored selection out of UserDefaults.
final class CredentialSourceDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "com.appideas.tokes.tests.credentialsource.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testUnknownStoredValueFallsBackToThisBuildsDefault() {
        defaults.set("nonsense", forKey: SettingsKeys.credentialSource)
        XCTAssertEqual(CredentialSource.current(in: defaults), CredentialSource.defaultSource())
        defaults.set("nonsense", forKey: SettingsKeys.copilotCredentialSource)
        XCTAssertEqual(CopilotCredentialSource.current(in: defaults), CopilotCredentialSource.defaultSource())
    }

    func testStoredValueThisBuildDoesNotOfferIsNormalized() {
        defaults.set(CredentialSource.claudeCode.rawValue, forKey: SettingsKeys.credentialSource)
        XCTAssertTrue(CredentialSource.available().contains(CredentialSource.current(in: defaults)))
        defaults.set(CopilotCredentialSource.editor.rawValue, forKey: SettingsKeys.copilotCredentialSource)
        XCTAssertTrue(CopilotCredentialSource.available().contains(CopilotCredentialSource.current(in: defaults)))
    }

    func testManualIsAlwaysHonored() {
        defaults.set(CredentialSource.manual.rawValue, forKey: SettingsKeys.credentialSource)
        XCTAssertEqual(CredentialSource.current(in: defaults), .manual)
        defaults.set(CopilotCredentialSource.manual.rawValue, forKey: SettingsKeys.copilotCredentialSource)
        XCTAssertEqual(CopilotCredentialSource.current(in: defaults), .manual)
    }

    /// Registered factory defaults must name a source this build ships.
    func testRegisteredDefaultSourcesAreAvailableInThisBuild() {
        let fresh = UserDefaults(suiteName: suite + ".fresh")!
        UserDefaults.standard.removePersistentDomain(forName: suite + ".fresh")
        AppDelegate.registerDefaults(in: fresh)
        XCTAssertTrue(CredentialSource.available().contains(CredentialSource.current(in: fresh)))
        XCTAssertTrue(CopilotCredentialSource.available().contains(CopilotCredentialSource.current(in: fresh)))
        UserDefaults.standard.removePersistentDomain(forName: suite + ".fresh")
    }
}
