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
    /// What the Launch at login toggle does, and how its current truth is read
    /// back after a failure. Injectable so a test flipping the toggle cannot
    /// register the test runner as a real login item.
    var setLaunchAtLogin: (Bool) throws -> Void = { enable in
        if enable {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
    var launchAtLoginStatus: () -> Bool = { SMAppService.mainApp.status == .enabled }

    /// ViewInspector's live-view hook; dormant outside tests (see Inspection).
    let inspection = Inspection<Self>()

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

    @AppStorage(SettingsKeys.copilotPlan) private var copilotPlan = CopilotPlan.pro.rawValue
    @AppStorage(SettingsKeys.copilotCustomAllowance) private var copilotCustomAllowance = 1500.0
    @StateObject private var githubModel = GitHubConnectModel()

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
                            try setLaunchAtLogin(enable)
                        } catch {
                            launchAtLogin = launchAtLoginStatus()
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
            githubModel.keychainService = keychainService
            githubModel.refreshConnectionState()
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
        .onReceive(inspection.notice) { self.inspection.visit(self, $0) }
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
            claudeImportControls
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

    /// The imported-file source with its export walkthrough.
    ///
    /// Claude Code on macOS keeps its sign-in in the keychain only — there is
    /// no credentials file to pick until the user makes one — so before the
    /// import button this shows the export command (and the optional
    /// SessionStart hook that keeps the export fresh). Both strings come from
    /// `ClaudeCodeExport`, the single source of truth the tests pin.
    @ViewBuilder
    private var claudeImportControls: some View {
        if claudeImportPath == nil {
            Text("Claude Code on macOS keeps your sign-in in the keychain, not in a file — "
                + "so export it to one first, then import that file here. Tokes re-reads the "
                + "file on every refresh and never touches the keychain itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("1. Run this in Terminal to export your Claude Code sign-in:")
                .font(.caption)
            commandRow(ClaudeCodeExport.exportCommand)
            DisclosureGroup {
                claudeHookHelp
            } label: {
                Text("2. Optional: keep the export fresh automatically")
                    .font(.caption)
            }
        }
        importControls(
            path: claudeImportPath,
            error: claudeImportError,
            help: claudeImportPath == nil
                ? "3. Import the exported file — the panel opens in your ~/.claude folder, "
                    + "where the export landed as tokes-credentials.json."
                : "Tokes re-reads this file on every refresh. When the token in it expires, "
                    + "open Claude Code to refresh it (automatic with the hook below) or "
                    + "re-run the export command.",
            importTitle: "Import Claude Code Credentials",
            importMessage: "Choose \(ClaudeCodeExport.exportedFilePath)",
            directory: RealHome.url.appendingPathComponent(".claude"),
            file: claudeFile,
            setPath: { claudeImportPath = $0 },
            setError: { claudeImportError = $0 })
        if claudeImportPath != nil {
            DisclosureGroup {
                Text("Export again after signing in to Claude Code afresh:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                commandRow(ClaudeCodeExport.exportCommand)
                claudeHookHelp
            } label: {
                Text("Export & refresh commands")
                    .font(.caption)
            }
        }
    }

    /// The optional SessionStart hook: what it does and the snippet to merge.
    @ViewBuilder
    private var claudeHookHelp: some View {
        Text("Merge this into the \"hooks\" section of ~/.claude/settings.json. Every new "
            + "Claude Code session then re-exports the current token, so the file Tokes "
            + "watches refreshes itself:")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        commandRow(ClaudeCodeExport.hookSnippet)
    }

    /// A copyable terminal command or snippet: selectable monospaced text with
    /// a Copy button beside it.
    private func commandRow(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var copilotCredentialControls: some View {
        switch CopilotCredentialSource(rawValue: copilotCredentialSource) ?? .manual {
        case .githubApp:
            githubSignInControls
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

    /// The device-flow sign-in, phase by phase. All state and transitions live
    /// in `GitHubConnectModel`; this renders the current phase and forwards
    /// button presses.
    @ViewBuilder
    private var githubSignInControls: some View {
        switch githubModel.phase {
        case .idle:
            Text("Sign in with your GitHub account. Tokes asks for read-only access "
                + "to your plan's billing usage — nothing else — and shows your "
                + "Copilot allowance consumption from GitHub's billing reports.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign in with GitHub…") {
                githubModel.connect(onChange: onCredentialsChanged)
            }
        case .requesting:
            Text("Contacting GitHub…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .awaitingUser(let userCode, let verificationURI):
            Text("Enter this code at \(verificationURI):")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(userCode)
                    .font(.system(.title2, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(userCode, forType: .string)
                }
            }
            HStack(spacing: 8) {
                Button("Open GitHub") {
                    if let url = URL(string: verificationURI) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Cancel") { githubModel.cancel() }
                Text("Waiting for you to authorize…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .connected(let login):
            HStack(spacing: 8) {
                Label("Connected as \(login)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Disconnect") {
                    githubModel.disconnect(onChange: onCredentialsChanged)
                }
            }
            copilotPlanControls
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                githubModel.connect(onChange: onCredentialsChanged)
            }
        }
    }

    /// Plan picker (and the custom allowance field it can reveal). GitHub's
    /// usage reports carry no entitlement and the plan is not queryable, so
    /// the percentage is measured against this selection.
    @ViewBuilder
    private var copilotPlanControls: some View {
        Picker("Plan", selection: $copilotPlan) {
            ForEach(CopilotPlan.allCases, id: \.rawValue) { plan in
                Text(plan.displayName).tag(plan.rawValue)
            }
        }
        if CopilotPlan(rawValue: copilotPlan) == .custom {
            TextField("Included monthly allowance", value: $copilotCustomAllowance,
                      format: .number)
        }
        Text("GitHub's usage report doesn't include your plan's allowance, so "
            + "the percentage is measured against the plan you pick here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                let picked = file.runImportPanel(title: importTitle,
                                                 message: importMessage,
                                                 startingAt: directory)
                switch Self.importOutcome(picked: picked, into: file) {
                case .cancelled:
                    break
                case .imported(let path):
                    setPath(path)
                    onCredentialsChanged()
                case .failed(let message):
                    setError(message)
                }
            }
            if path != nil {
                Button("Forget") {
                    Self.forget(file)
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

    // MARK: - Import / forget

    /// What the Choose File… button did with what the panel returned.
    enum ImportOutcome: Equatable {
        case cancelled
        case imported(path: String)
        case failed(message: String)
    }

    /// Everything the Choose File… button does after the open panel answers.
    ///
    /// Extracted for the same reason the connection tests were: a button in a
    /// view that is never rendered into a window can never be pressed. The
    /// modal itself stays untestable and stays in the view; this is the half
    /// that decides whether an import happened, and it is the half that writes
    /// to storage the credential providers read.
    ///
    /// A failure leaves the previously imported file alone — `store` either
    /// replaces the bookmark or throws before touching it — so the path label
    /// keeps showing the file that still works.
    static func importOutcome(picked: URL?, into file: ImportedCredentialFile) -> ImportOutcome {
        guard let picked else { return .cancelled }
        do {
            try file.store(picked)
            return .imported(path: picked.path)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// What the Forget button does to storage. One line, but the line the
    /// credential providers see: after it, the selected source resolves to
    /// `notImported` rather than to a bookmark nothing points at.
    static func forget(_ file: ImportedCredentialFile) {
        file.clear()
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

    /// The Copilot half of `claudeTestOutcome`, same reasoning. The
    /// `githubApp` source runs its whole pipeline (stored tokens, refresh,
    /// billing report) rather than resolving a token first, because that
    /// pipeline owns its auth.
    static func copilotTestOutcome(source: CopilotCredentialSource,
                                   pastedToken: String,
                                   file: ImportedCredentialFile,
                                   session: URLSession,
                                   keychainService: String = CredentialsProvider.manualService,
                                   defaults: UserDefaults = .standard) async -> TestOutcome {
        do {
            if source == .githubApp {
                let fetcher = GitHubBillingFetcher()
                fetcher.keychainService = keychainService
                fetcher.defaults = defaults
                fetcher.billing = CopilotBillingClient(session: session)
                fetcher.deviceAuth = GitHubDeviceAuth(session: session)
                let limit = try await fetcher.fetch()
                let detail = limit.detail ?? "\(Int(limit.percent.rounded()))% used"
                return TestOutcome(passed: true, message: "Connected — \(detail)")
            }
            let token: String
            switch source {
            case .githubApp:
                // Handled above; the switch still needs the case to stay exhaustive.
                throw CopilotCredentialError.sourceUnavailable
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
        let service = keychainService
        Task {
            let outcome = await Self.copilotTestOutcome(source: source, pastedToken: pastedToken,
                                                        file: file, session: session,
                                                        keychainService: service)
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
