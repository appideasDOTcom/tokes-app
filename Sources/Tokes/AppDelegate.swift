import AppKit

/// App lifecycle: wires state, history, poller, and status item together at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var poller: UsagePoller?

    /// Registers settings defaults and starts polling and the menu bar item.
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.refreshInterval: 60.0,
            SettingsKeys.showLabel: false,
            SettingsKeys.credentialSource: CredentialSource.claudeCode.rawValue,
        ])

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
