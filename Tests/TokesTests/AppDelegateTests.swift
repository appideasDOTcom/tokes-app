import XCTest

@testable import Tokes

final class AppDelegateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TokesTests-defaults-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRegisterDefaults() {
        AppDelegate.registerDefaults(in: defaults)

        XCTAssertEqual(defaults.double(forKey: SettingsKeys.refreshInterval), 60)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.menuBarLabel), MenuBarLabel.off.rawValue)
        // The most automatic source this build ships: Claude Code / editor for
        // the direct build, the imported file for the App Store build.
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.credentialSource),
                       CredentialSource.defaultSource().rawValue)
        XCTAssertFalse(defaults.bool(forKey: SettingsKeys.copilotEnabled))
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.copilotCredentialSource),
                       CopilotCredentialSource.defaultSource().rawValue)
        #if TOKES_APP_STORE
            XCTAssertEqual(defaults.string(forKey: SettingsKeys.credentialSource), "importedFile")
            XCTAssertEqual(defaults.string(forKey: SettingsKeys.copilotCredentialSource), "githubApp")
        #else
            XCTAssertEqual(defaults.string(forKey: SettingsKeys.credentialSource), "claudeCode")
            XCTAssertEqual(defaults.string(forKey: SettingsKeys.copilotCredentialSource), "editor")
        #endif
        XCTAssertTrue(defaults.bool(forKey: SettingsKeys.showScopedWeekly))
    }

    func testMigrationCarriesTheOldToggleOver() {
        defaults.set(true, forKey: SettingsKeys.legacyShowLabel)
        AppDelegate.migrateSettings(in: defaults)

        XCTAssertEqual(defaults.string(forKey: SettingsKeys.menuBarLabel),
                       MenuBarLabel.highest.rawValue)
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyShowLabel))
    }

    func testMigrationOfTheOffToggleLeavesTheLabelOff() {
        defaults.set(false, forKey: SettingsKeys.legacyShowLabel)
        AppDelegate.migrateSettings(in: defaults)

        XCTAssertEqual(defaults.string(forKey: SettingsKeys.menuBarLabel), MenuBarLabel.off.rawValue)
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyShowLabel))
    }

    func testMigrationLeavesAnUntouchedInstallAtItsDefault() {
        AppDelegate.migrateSettings(in: defaults)
        XCTAssertNil(defaults.object(forKey: SettingsKeys.menuBarLabel))

        AppDelegate.registerDefaults(in: defaults)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.menuBarLabel), MenuBarLabel.off.rawValue)
    }

    func testMigrationNeverOverwritesAnExplicitChoice() {
        defaults.set(MenuBarLabel.copilot.rawValue, forKey: SettingsKeys.menuBarLabel)
        defaults.set(true, forKey: SettingsKeys.legacyShowLabel)

        AppDelegate.migrateSettings(in: defaults)

        XCTAssertEqual(defaults.string(forKey: SettingsKeys.menuBarLabel),
                       MenuBarLabel.copilot.rawValue)
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyShowLabel))
    }

    func testMigrationIsIdempotent() {
        defaults.set(true, forKey: SettingsKeys.legacyShowLabel)
        AppDelegate.migrateSettings(in: defaults)
        defaults.set(MenuBarLabel.session.rawValue, forKey: SettingsKeys.menuBarLabel)

        AppDelegate.migrateSettings(in: defaults)  // a later launch

        XCTAssertEqual(defaults.string(forKey: SettingsKeys.menuBarLabel),
                       MenuBarLabel.session.rawValue)
    }
}
