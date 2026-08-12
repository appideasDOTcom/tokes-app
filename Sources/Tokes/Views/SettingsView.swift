import ServiceManagement
import SwiftUI

/// Settings form: credential source, connection test, refresh interval,
/// menu bar label, and launch at login.
struct SettingsView: View {
    let onCredentialsChanged: () -> Void

    @AppStorage(SettingsKeys.refreshInterval) private var refreshInterval: Double = 60
    @AppStorage(SettingsKeys.showLabel) private var showLabel = false
    @AppStorage(SettingsKeys.credentialSource) private var credentialSource = CredentialSource.claudeCode.rawValue

    @State private var manualToken = ""
    @State private var tokenSaved = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testPassed = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Claude Connection") {
                Picker("Credentials", selection: $credentialSource) {
                    Text("Use Claude Code sign-in (automatic)").tag(CredentialSource.claudeCode.rawValue)
                    Text("Manual OAuth token").tag(CredentialSource.manual.rawValue)
                }
                .pickerStyle(.radioGroup)

                if credentialSource == CredentialSource.claudeCode.rawValue {
                    Text("Reads the credentials Claude Code keeps in your keychain. macOS may ask you to allow access the first time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("OAuth access token", text: $manualToken)
                    HStack(spacing: 8) {
                        Button("Save Token") {
                            tokenSaved = CredentialsProvider.saveManualToken(manualToken)
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

            Section("Behavior") {
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                }
                Toggle("Show highest usage as text in menu bar", isOn: $showLabel)
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
                Text("Tokes \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") — Claude token usage in your menu bar. Tracks the three plan limits shown in Claude Code: Session (5 hr), Weekly (7 day), and the weekly model-scoped limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
        .onAppear {
            manualToken = CredentialsProvider.readManualToken() ?? ""
        }
        .onChange(of: credentialSource) { _, _ in
            tokenSaved = false
            testResult = nil
            onCredentialsChanged()
        }
    }

    /// Fetches usage once with the selected credentials and reports the result inline.
    private func testConnection() {
        testing = true
        testResult = nil
        let source = CredentialSource(rawValue: credentialSource) ?? .claudeCode
        let pastedToken = manualToken
        Task {
            do {
                let token: String
                switch source {
                case .manual:
                    guard !pastedToken.isEmpty else { throw CredentialError.manualMissing }
                    token = pastedToken
                case .claudeCode:
                    token = try CredentialsProvider.loadClaudeCodeToken().0
                }
                let snapshot = try await UsageClient().fetch(token: token)
                await MainActor.run {
                    testPassed = true
                    testResult = "Connected — \(snapshot.limits.count) limits reported"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testPassed = false
                    testResult = error.localizedDescription
                    testing = false
                }
            }
        }
    }
}
