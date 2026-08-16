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
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.credentialSource),
                       CredentialSource.claudeCode.rawValue)
        XCTAssertFalse(defaults.bool(forKey: SettingsKeys.copilotEnabled))
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.copilotCredentialSource),
                       CopilotCredentialSource.editor.rawValue)
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
