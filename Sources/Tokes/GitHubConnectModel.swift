import Foundation

/// Drives the Settings "Sign in with GitHub" flow: request a device code, show
/// it, poll until GitHub answers, persist the token set. Lives outside the view
/// so the whole state machine is testable without rendering anything — the
/// view binds to `phase` and forwards button presses.
@MainActor
final class GitHubConnectModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requesting
        /// Waiting for the user to enter `userCode` at `verificationURI`.
        case awaitingUser(userCode: String, verificationURI: String)
        case connected(login: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var auth = GitHubDeviceAuth()
    /// The keychain slot the token set is saved to; injectable for tests.
    var keychainService = CredentialsProvider.manualService
    /// Test seam: the clock the code-expiry deadline is measured against.
    var now: () -> Date = { Date() }
    /// Test seam: how the poll loop waits between attempts. The default really
    /// sleeps; a test substitutes an immediate return and counts calls.
    var sleeper: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var pollTask: Task<Void, Never>?

    /// Nonisolated so `@StateObject private var githubModel = GitHubConnectModel()`
    /// can build one outside a main-actor context; every default above is a
    /// plain value.
    nonisolated init() {}

    /// Reflects whatever the keychain currently holds (used on appear, and
    /// after cancel — an aborted sign-in leaves any previous session intact).
    func refreshConnectionState() {
        if let stored = GitHubAppTokens.load(service: keychainService) {
            phase = .connected(login: stored.login)
        } else {
            phase = .idle
        }
    }

    /// Starts the device flow; `onChange` fires once tokens are saved so the
    /// host can kick the poller.
    func connect(onChange: @escaping () -> Void) {
        guard pollTask == nil else { return }
        phase = .requesting
        pollTask = Task {
            await run(onChange: onChange)
            pollTask = nil
        }
    }

    /// Abandons an in-progress sign-in.
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        refreshConnectionState()
    }

    /// Waits for an in-flight sign-in task to settle; used by tests, harmless
    /// (returns immediately) when nothing is running.
    func settle() async {
        await pollTask?.value
    }

    /// Signs out: clears the stored token set.
    func disconnect(onChange: () -> Void) {
        pollTask?.cancel()
        pollTask = nil
        GitHubAppTokens.clear(service: keychainService)
        phase = .idle
        onChange()
    }

    private func run(onChange: @escaping () -> Void) async {
        do {
            let code = try await auth.requestCode()
            phase = .awaitingUser(userCode: code.userCode, verificationURI: code.verificationURI)
            var interval = max(code.interval, 1)
            let deadline = now().addingTimeInterval(code.expiresIn)
            while now() < deadline, !Task.isCancelled {
                await sleeper(interval)
                guard !Task.isCancelled else { return }
                switch try await auth.pollOnce(deviceCode: code.deviceCode) {
                case .pending:
                    continue
                case .slowDown(let slower):
                    interval = max(slower, interval)
                case .denied:
                    phase = .failed("Sign-in was denied on GitHub.")
                    return
                case .expired:
                    phase = .failed("The code expired before it was entered — try again.")
                    return
                case .authorized(let grant):
                    // The login is required, not decorative: the billing URLs
                    // address the user by username.
                    let login = try await auth.fetchLogin(accessToken: grant.accessToken)
                    let tokens = GitHubAppTokens(grant: grant, login: login, issuedAt: now())
                    guard tokens.save(service: keychainService) else {
                        phase = .failed(GitHubAuthError.storage.localizedDescription)
                        return
                    }
                    phase = .connected(login: login)
                    onChange()
                    return
                }
            }
            // Only the deadline may report expiry — a cancelled task also exits
            // the loop, but `cancel()` has already set the phase it wants.
            if !Task.isCancelled, case .awaitingUser = phase {
                phase = .failed("The code expired before it was entered — try again.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
