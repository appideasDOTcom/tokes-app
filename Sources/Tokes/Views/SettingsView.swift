import ServiceManagement
import SwiftUI

/// Settings form: Claude and Copilot connections, refresh interval,
/// menu bar label, and launch at login.
///
/// Which credential sources appear is decided by `CredentialSource.available()`,
/// so the App Store build simply never offers the ones it doesn't ship — this
/// view has no build conditionals of its own beyond the one connection test that
/// calls a reader compiled out of that build.
struct SettingsView: View {
    let onCredentialsChanged: () -> Void

    /// The keychain slot the manual-token fields read and write. Injectable so
    /// a test that renders this view does not read the item the installed app
    /// owns — `onAppear` reads both accounts on every render.
    var keychainService = CredentialsProvider.manualService
    /// Domain the imported-file bookmarks live in. Injectable for the same
    /// reason: `onAppear` resolves both bookmarks to show their paths, and a
    /// test has no business resolving the real ones.
    var bookmarkDefaults: UserDefaults = .standard
    /// Session the Test Connection buttons use; injectable for tests.
    var testSession: URLSession = .shared

    @AppStorage(SettingsKeys.refreshInterval) private var refreshInterval: Double = 60
    @AppStorage(SettingsKeys.menuBarLabel) private var menuBarLabel = MenuBarLabel.off.rawValue
    @AppStorage(SettingsKeys.credentialSource) private var credentialSource = CredentialSource.defaultSource().rawValue
    @AppStorage(SettingsKeys.copilotEnabled) private var copilotEnabled = false
    @AppStorage(SettingsKeys.copilotCredentialSource) private var copilotCredentialSource = CopilotCredentialSource.defaultSource().rawValue
    @AppStorage(SettingsKeys.showScopedWeekly) private var showScopedWeekly = true

    @State private var manualToken = ""
    @State private var tokenSaved = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testPassed = false
    @State private var claudeImportPath: String?
    @State private var claudeImportError: String?
    @State private var copilotToken = ""
    @State private var copilotTokenSaved = false
    @State private var copilotTesting = false
    @State private var copilotTestResult: String?
    @State private var copilotTestPassed = false
    @State private var copilotImportPath: String?
    @State private var copilotImportError: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Computed rather than stored so they can pick up `bookmarkDefaults`;
    /// `ImportedCredentialFile` keeps no state of its own beyond that domain,
    /// so rebuilding one per access costs nothing.
    private var claudeFile: ImportedCredentialFile {
        ImportedCredentialFile(defaultsKey: SettingsKeys.claudeCredentialFile,
                               describing: "Claude Code credentials", defaults: bookmarkDefaults)
    }
    private var copilotFile: ImportedCredentialFile {
        ImportedCredentialFile(defaultsKey: SettingsKeys.copilotCredentialFile,
                               describing: "Copilot config", defaults: bookmarkDefaults)
    }

    /// Menu bar options offered for the current Copilot / scoped-weekly toggles.
    private var availableLabels: [MenuBarLabel] {
        MenuBarLabel.available(copilotEnabled: copilotEnabled, showScopedWeekly: showScopedWeekly)
    }

    var body: some View {
        Form {
            Section("Claude Connection") {
                Picker("Credentials", selection: $credentialSource) {
                    ForEach(CredentialSource.available(), id: \.self) { source in
                        Text(source.displayName).tag(source.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                claudeCredentialControls

                HStack(spacing: 8) {
                    Button(testing ? "Testing…" : "Test Connection") { testConnection() }
                        .disabled(testing)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testPassed ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("GitHub Copilot") {
                Toggle("Also monitor Copilot premium requests", isOn: $copilotEnabled)

                if copilotEnabled {
                    Picker("Credentials", selection: $copilotCredentialSource) {
                        ForEach(CopilotCredentialSource.available(), id: \.self) { source in
                            Text(source.displayName).tag(source.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    copilotCredentialControls

                    HStack(spacing: 8) {
                        Button(copilotTesting ? "Testing…" : "Test Connection") { testCopilotConnection() }
                            .disabled(copilotTesting)
                        if let copilotTestResult {
                            Text(copilotTestResult)
                                .font(.caption)
                                .foregroundStyle(copilotTestPassed ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Section("Behavior") {
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                }
                Picker("Show in menu bar", selection: $menuBarLabel) {
                    ForEach(availableLabels, id: \.self) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                Toggle("Show model-specific weekly limit (e.g. Weekly Fable)", isOn: $showScopedWeekly)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                Text("Tokes \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") "
                    + "(\(Distribution.current.displayName))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
        .onAppear {
            normalizeCredentialSources()
            manualToken = CredentialsProvider.readManualToken(service: keychainService) ?? ""
            copilotToken = CredentialsProvider.readManualToken(
                service: keychainService,
                account: CopilotCredentialsProvider.manualAccount) ?? ""
            claudeImportPath = claudeFile.displayPath
            copilotImportPath = copilotFile.displayPath
            normalizeMenuBarLabel()
        }
        // Turning off Copilot or the scoped weekly limit removes its menu bar
        // option; a selection left pointing at it would render the picker blank.
        .onChange(of: copilotEnabled) { _, _ in normalizeMenuBarLabel() }
        .onChange(of: showScopedWeekly) { _, _ in normalizeMenuBarLabel() }
        .onChange(of: credentialSource) { _, _ in
            tokenSaved = false
            testResult = nil
            onCredentialsChanged()
        }
        .onChange(of: copilotCredentialSource) { _, _ in
            copilotTokenSaved = false
            copilotTestResult = nil
            onCredentialsChanged()
        }
    }

    // MARK: - Per-source controls

    @ViewBuilder
    private var claudeCredentialControls: some View {
        switch CredentialSource(rawValue: credentialSource) ?? .manual {
        case .claudeCode:
            Text("Reads the credentials Claude Code keeps in your keychain. macOS may ask you to allow access the first time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .importedFile:
            importControls(
                path: claudeImportPath,
                error: claudeImportError,
                help: "Pick the credentials file Claude Code writes, normally "
                    + "~/.claude/.credentials.json. Tokes re-reads it on every refresh, so a "
                    + "rotated token keeps working. If Claude Code stores your login only in "
                    + "the keychain there is no such file — paste a token instead.",
                importTitle: "Import Claude Code Credentials",
                importMessage: "Choose ~/.claude/.credentials.json",
                directory: RealHome.url.appendingPathComponent(".claude"),
                file: claudeFile,
                setPath: { claudeImportPath = $0 },
                setError: { claudeImportError = $0 })
        case .manual:
            SecureField("OAuth access token", text: $manualToken)
            HStack(spacing: 8) {
                Button("Save Token") {
                    tokenSaved = CredentialsProvider.saveManualToken(manualToken,
                                                                     service: keychainService)
                    onCredentialsChanged()
                }
                .disabled(manualToken.isEmpty)
                if tokenSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var copilotCredentialControls: some View {
        switch CopilotCredentialSource(rawValue: copilotCredentialSource) ?? .manual {
        case .editor:
            Text("Reads the token your editor's Copilot plugin keeps in ~/.config/github-copilot, falling back to the GitHub CLI.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .importedFile:
            importControls(
                path: copilotImportPath,
                error: copilotImportError,
                help: "Pick your Copilot plugin's config file, normally "
                    + "~/.config/github-copilot/apps.json (older plugins write hosts.json). "
                    + "Tokes re-reads it on every refresh.",
                importTitle: "Import Copilot Config",
                importMessage: "Choose ~/.config/github-copilot/apps.json",
                directory: RealHome.url.appendingPathComponent(".config/github-copilot"),
                file: copilotFile,
                setPath: { copilotImportPath = $0 },
                setError: { copilotImportError = $0 })
        case .manual:
            SecureField("GitHub token", text: $copilotToken)
            HStack(spacing: 8) {
                Button("Save Token") {
                    copilotTokenSaved = CredentialsProvider.saveManualToken(
                        copilotToken, service: keychainService,
                        account: CopilotCredentialsProvider.manualAccount)
                    onCredentialsChanged()
                }
                .disabled(copilotToken.isEmpty)
                if copilotTokenSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    /// Import / forget buttons plus the current selection, shared by both providers.
    @ViewBuilder
    private func importControls(path: String?,
                                error: String?,
                                help: String,
                                importTitle: String,
                                importMessage: String,
                                directory: URL,
                                file: ImportedCredentialFile,
                                setPath: @escaping (String?) -> Void,
                                setError: @escaping (String?) -> Void) -> some View {
        Text(help)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
            Button(path == nil ? "Choose File…" : "Choose Another File…") {
                setError(nil)
                do {
                    if let chosen = try file.runImportPanel(title: importTitle,
                                                            message: importMessage,
                                                            startingAt: directory) {
                        setPath(chosen)
                        onCredentialsChanged()
                    }
                } catch {
                    setError(error.localizedDescription)
                }
            }
            if path != nil {
                Button("Forget") {
                    file.clear()
                    setPath(nil)
                    setError(nil)
                    onCredentialsChanged()
                }
            }
        }

        if let path {
            Label(path, systemImage: "doc.badge.gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Normalization

    /// Drops a stored credential source this build doesn't offer back to its
    /// default — settings copied in from a direct build can name `claudeCode`
    /// or `editor`, which the App Store build has no reader for.
    private func normalizeCredentialSources() {
        let claude = (CredentialSource(rawValue: credentialSource) ?? .manual).normalized()
        if claude.rawValue != credentialSource { credentialSource = claude.rawValue }
        let copilot = (CopilotCredentialSource(rawValue: copilotCredentialSource) ?? .manual).normalized()
        if copilot.rawValue != copilotCredentialSource { copilotCredentialSource = copilot.rawValue }
    }

    /// Drops the menu bar selection back to "Highest value" when the measurement
    /// it names is no longer offered.
    private func normalizeMenuBarLabel() {
        let selection = MenuBarLabel(rawValue: menuBarLabel) ?? .off
        let valid = selection.normalized(copilotEnabled: copilotEnabled,
                                         showScopedWeekly: showScopedWeekly)
        if valid.rawValue != menuBarLabel { menuBarLabel = valid.rawValue }
    }

    // MARK: - Connection tests

    /// The outcome of one Test Connection press: what the inline label says and
    /// whether it says it in green.
    struct TestOutcome: Equatable {
        let passed: Bool
        let message: String
    }

    /// Everything a Claude Test Connection press does, minus the `@State`
    /// bookkeeping — resolve a token from the selected source, fetch once, and
    /// turn either result into the line the user reads.
    ///
    /// Extracted from the button because a button in a view that is never
    /// rendered into a window can never be pressed, and this is the only
    /// self-diagnostic the app has. The `session` parameter is why it can be
    /// tested at all: the button used to build `UsageClient()` inline, which
    /// takes `.shared`.
    static func claudeTestOutcome(source: CredentialSource,
                                  pastedToken: String,
                                  file: ImportedCredentialFile,
                                  session: URLSession) async -> TestOutcome {
        do {
            let token: String
            switch source {
            case .manual:
                guard !pastedToken.isEmpty else { throw CredentialError.manualMissing }
                token = pastedToken
            case .importedFile:
                token = try CredentialsProvider.loadImportedToken(from: file).0
            case .claudeCode:
                #if TOKES_APP_STORE
                    throw CredentialError.sourceUnavailable
                #else
                    token = try CredentialsProvider.loadClaudeCodeToken().0
                #endif
            }
            let snapshot = try await UsageClient(session: session).fetch(token: token)
            return TestOutcome(passed: true,
                               message: "Connected — \(snapshot.limits.count) limits reported")
        } catch {
            return TestOutcome(passed: false, message: error.localizedDescription)
        }
    }

    /// The Copilot half of `claudeTestOutcome`, same reasoning.
    static func copilotTestOutcome(source: CopilotCredentialSource,
                                   pastedToken: String,
                                   file: ImportedCredentialFile,
                                   session: URLSession) async -> TestOutcome {
        do {
            let token: String
            switch source {
            case .manual:
                guard !pastedToken.isEmpty else { throw CopilotCredentialError.manualMissing }
                token = pastedToken
            case .importedFile:
                token = try CopilotCredentialsProvider.loadImportedToken(from: file)
            case .editor:
                #if TOKES_APP_STORE
                    throw CopilotCredentialError.sourceUnavailable
                #else
                    token = try CopilotCredentialsProvider().loadEditorToken()
                #endif
            }
            let limit = try await CopilotClient(session: session).fetch(token: token)
            let detail = limit.detail ?? "\(Int(limit.percent.rounded()))% used"
            return TestOutcome(passed: true, message: "Connected — \(detail)")
        } catch {
            return TestOutcome(passed: false, message: error.localizedDescription)
        }
    }

    /// Fetches Copilot usage once with the selected credentials and reports the result inline.
    private func testCopilotConnection() {
        copilotTesting = true
        copilotTestResult = nil
        let source = CopilotCredentialSource(rawValue: copilotCredentialSource) ?? .manual
        let pastedToken = copilotToken
        let file = copilotFile
        let session = testSession
        Task {
            let outcome = await Self.copilotTestOutcome(source: source, pastedToken: pastedToken,
                                                        file: file, session: session)
            await MainActor.run {
                copilotTestPassed = outcome.passed
                copilotTestResult = outcome.message
                copilotTesting = false
            }
        }
    }

    /// Fetches usage once with the selected credentials and reports the result inline.
    private func testConnection() {
        testing = true
        testResult = nil
        let source = CredentialSource(rawValue: credentialSource) ?? .manual
        let pastedToken = manualToken
        let file = claudeFile
        let session = testSession
        Task {
            let outcome = await Self.claudeTestOutcome(source: source, pastedToken: pastedToken,
                                                       file: file, session: session)
            await MainActor.run {
                testPassed = outcome.passed
                testResult = outcome.message
                testing = false
            }
        }
    }
}
