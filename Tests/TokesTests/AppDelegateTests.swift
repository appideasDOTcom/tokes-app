import XCTest

@testable import Tokes

final class AppDelegateTests: XCTestCase {
    func testRegisterDefaults() {
        let suiteName = "TokesTests-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppDelegate.registerDefaults(in: defaults)

        XCTAssertEqual(defaults.double(forKey: SettingsKeys.refreshInterval), 60)
        XCTAssertFalse(defaults.bool(forKey: SettingsKeys.showLabel))
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.credentialSource),
                       CredentialSource.claudeCode.rawValue)
        XCTAssertFalse(defaults.bool(forKey: SettingsKeys.copilotEnabled))
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.copilotCredentialSource),
                       CopilotCredentialSource.editor.rawValue)
        XCTAssertTrue(defaults.bool(forKey: SettingsKeys.showScopedWeekly))
    }
}
