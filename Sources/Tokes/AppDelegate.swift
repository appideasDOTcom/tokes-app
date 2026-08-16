import AppKit

/// App lifecycle: wires state, history, poller, and status item together at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var poller: UsagePoller?

    /// Registers factory defaults for user-configurable settings.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            SettingsKeys.refreshInterval: 60.0,
            SettingsKeys.menuBarLabel: MenuBarLabel.off.rawValue,
            SettingsKeys.credentialSource: CredentialSource.claudeCode.rawValue,
            SettingsKeys.copilotEnabled: false,
            SettingsKeys.copilotCredentialSource: CopilotCredentialSource.editor.rawValue,
            SettingsKeys.showScopedWeekly: true,
        ])
    }

    /// Carries the old `showLabel` toggle over to `menuBarLabel`: on became
    /// "highest value", off became no label. Runs once — after this the legacy
    /// key is gone.
    ///
    /// Must run *before* `registerDefaults`: `register(defaults:)` fills the
    /// registration domain, after which `object(forKey:)` returns the factory
    /// default instead of nil and "did the user ever set this?" can no longer
    /// be answered.
    static func migrateSettings(in defaults: UserDefaults = .standard) {
        guard let wasShowing = defaults.object(forKey: SettingsKeys.legacyShowLabel) as? Bool else { return }
        if defaults.object(forKey: SettingsKeys.menuBarLabel) == nil {
            defaults.set(wasShowing ? MenuBarLabel.highest.rawValue : MenuBarLabel.off.rawValue,
                         forKey: SettingsKeys.menuBarLabel)
        }
        defaults.removeObject(forKey: SettingsKeys.legacyShowLabel)
    }

    /// Registers settings defaults and starts polling and the menu bar item.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateSettings()  // before registerDefaults — see its doc comment
        Self.registerDefaults()

        let state = AppState()
        let history = HistoryStore()
        state.samples = history.samples

        let poller = UsagePoller(state: state, history: history)
        self.poller = poller
        controller = StatusItemController(state: state, poller: poller)
        poller.start()
    }

    /// Stops the poll timer and its observers.
    func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
    }
}
