import AppKit

/// Abstraction over the usage client, injectable for tests.
protocol UsageFetching {
    func fetch(token: String) async throws -> UsageSnapshot
}

extension UsageClient: UsageFetching {}

/// Abstraction over credential resolution, injectable for tests.
protocol TokenProviding: AnyObject {
    func accessToken() throws -> String
    func invalidate()
}

extension CredentialsProvider: TokenProviding {}

/// Polls the usage endpoint on a settings-driven interval, updating AppState
/// and recording history samples.
final class UsagePoller {
    private let state: AppState
    private let history: HistoryStore
    private let client: UsageFetching
    private let credentials: TokenProviding

    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var inFlight = false
    private var lastRateLimitedAt: Date?

    /// Creates a poller that publishes into `state` and records samples to `history`.
    init(state: AppState, history: HistoryStore,
         client: UsageFetching = UsageClient(),
         credentials: TokenProviding = CredentialsProvider()) {
        self.state = state
        self.history = history
        self.client = client
        self.credentials = credentials
    }

    /// User-configured refresh interval in seconds, floored to 10.
    var configuredInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.refreshInterval)
        return v >= 10 ? v : 60
    }

    /// Schedules the timer, polls immediately, and observes wake and settings changes.
    func start() {
        schedule()
        refreshNow()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    /// Invalidates the timer and removes observers.
    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    /// Re-resolve credentials on the next poll (e.g. after settings change).
    func credentialsChanged() {
        credentials.invalidate()
        refreshNow()
    }

    /// Triggers an immediate poll on the main actor.
    func refreshNow() {
        Task { @MainActor in
            await self.tick()
        }
    }

    /// Refresh if the current snapshot is stale (used when the popover opens).
    /// Called from the main thread; returns whether a refresh was triggered.
    @discardableResult
    func refreshIfStale(olderThan seconds: TimeInterval = 30) -> Bool {
        // Back off opportunistic refreshes after a 429; the timer keeps its
        // regular cadence.
        if let limited = lastRateLimitedAt, Date().timeIntervalSince(limited) < 90 {
            return false
        }
        if let fetchedAt = state.snapshot?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) <= seconds {
            return false
        }
        refreshNow()
        return true
    }

    /// (Re)creates the repeating poll timer at the configured interval.
    private func schedule() {
        currentInterval = configuredInterval
        timer?.invalidate()
        let t = Timer(timeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        t.tolerance = currentInterval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Polls shortly after wake, giving the network a moment to reconnect.
    @objc private func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshNow()
        }
    }

    /// Reschedules the timer when the refresh-interval setting changes.
    @objc private func defaultsChanged() {
        if configuredInterval != currentInterval {
            DispatchQueue.main.async { [weak self] in self?.schedule() }
        }
    }

    /// One poll: fetch, publish the snapshot, and record a history sample.
    /// On failure the last snapshot stays visible and a message is surfaced.
    @MainActor
    func tick() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        do {
            let snapshot = try await fetchWithRetry()
            state.snapshot = snapshot
            state.errorMessage = nil
            let sample = UsageSample(
                t: snapshot.fetchedAt,
                v: Dictionary(uniqueKeysWithValues: snapshot.limits.map { ($0.id, $0.percent) }))
            history.append(sample)
            state.samples = history.samples
        } catch {
            // Keep the last snapshot visible; just surface the error.
            if case UsageError.http(429) = error {
                lastRateLimitedAt = Date()
                state.errorMessage = "Usage API rate-limited — retrying automatically."
            } else {
                state.errorMessage = error.localizedDescription
            }
            DebugLog.log("Tokes: tick failed: \(error)")
        }
    }

    /// Fetches usage, re-resolving credentials once on 401 in case Claude Code
    /// rotated the token.
    private func fetchWithRetry() async throws -> UsageSnapshot {
        do {
            let token = try credentials.accessToken()
            return try await client.fetch(token: token)
        } catch UsageError.unauthorized {
            credentials.invalidate()
            let token = try credentials.accessToken()
            return try await client.fetch(token: token)
        }
    }
}
