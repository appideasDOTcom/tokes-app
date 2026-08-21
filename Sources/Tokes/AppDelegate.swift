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
            SettingsKeys.credentialSource: CredentialSource.defaultSource().rawValue,
            SettingsKeys.copilotEnabled: false,
            SettingsKeys.copilotCredentialSource: CopilotCredentialSource.defaultSource().rawValue,
            SettingsKeys.copilotPlan: CopilotPlan.pro.rawValue,
            SettingsKeys.copilotCustomAllowance: 1500.0,
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

    /// Whether this launch is the app's first ever, decided from the
    /// *persistent* domain read by name — not `object(forKey:)`, because the
    /// registration domain is process-global and volatile: once anything has
    /// called `register(defaults:)`, every key reads as set through every
    /// `UserDefaults` instance and "did the user ever set this?" can no longer
    /// be asked that way. Any persisted configuration counts as evidence of a
    /// prior run, so an upgrade install that predates the marker key is never
    /// mistaken for a fresh one.
    static func isFirstRun(domainName: String = Bundle.main.bundleIdentifier
        ?? CredentialsProvider.manualService) -> Bool {
        let persisted = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]
        guard (persisted[SettingsKeys.didCompleteFirstRun] as? Bool) != true else { return false }
        let priorRunEvidence = [
            SettingsKeys.credentialSource, SettingsKeys.copilotEnabled,
            SettingsKeys.menuBarLabel, SettingsKeys.legacyShowLabel,
            SettingsKeys.claudeCredentialFile, SettingsKeys.copilotCredentialFile,
        ]
        return !priorRunEvidence.contains { persisted[$0] != nil }
    }

    /// Registers settings defaults and starts polling and the menu bar item.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let firstRun = Self.isFirstRun()  // before registerDefaults — see its doc comment
        Self.migrateSettings()  // before registerDefaults — see its doc comment
        Self.registerDefaults()
        UserDefaults.standard.set(true, forKey: SettingsKeys.didCompleteFirstRun)

        DebugLog.log("Tokes launched — \(Distribution.current.displayName) build, "
            + "sandboxed=\(SandboxAudit.isSandboxed)")
        if let mismatch = SandboxAudit.mismatchDescription() {
            // A mis-signed artifact: loud in the log rather than silently
            // non-compliant (App Store) or silently broken (direct).
            NSLog("Tokes: %@", mismatch)
            DebugLog.log(mismatch)
        }

        let state = AppState()
        let history = HistoryStore()
        state.samples = history.samples

        let poller = UsagePoller(state: state, history: history)
        self.poller = poller
        controller = StatusItemController(state: state, poller: poller)
        poller.start()

        // A fresh install has nothing to poll and nothing to draw — open
        // Settings so the first thing the user sees is the way in, not a
        // menu bar item reporting a credentials error.
        if firstRun {
            controller?.openSettings()
        }
    }

    /// Stops the poll timer and its observers.
    func applicationWillTerminate(_ notification: Notification) {
        poller?.stop()
    }
}
