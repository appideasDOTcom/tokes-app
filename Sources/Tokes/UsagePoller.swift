import AppKit

/// Abstraction over the Claude usage client, injectable for tests.
protocol UsageFetching {
    func fetch(token: String) async throws -> UsageSnapshot
}

extension UsageClient: UsageFetching {}

/// Abstraction over the Copilot usage client, injectable for tests.
protocol CopilotUsageFetching {
    func fetch(token: String) async throws -> UsageLimit
}

extension CopilotClient: CopilotUsageFetching {}

/// Abstraction over credential resolution, injectable for tests.
protocol TokenProviding: AnyObject {
    func accessToken() throws -> String
    func invalidate()
}

extension CredentialsProvider: TokenProviding {}

/// Polls the usage endpoints on a settings-driven interval, updating AppState
/// and recording history samples. Claude is always polled; Copilot only when
/// enabled in Settings.
final class UsagePoller {
    private let state: AppState
    private let history: HistoryStore
    private let client: UsageFetching
    private let credentials: TokenProviding
    private let copilotClient: CopilotUsageFetching
    private let copilotCredentials: TokenProviding

    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var currentCopilotEnabled = false
    private var inFlight = false
    /// While set and in the future, Claude polls are skipped entirely (429
    /// backoff). Copilot polling is unaffected.
    private var claudeBackoffUntil: Date?
    private var rateLimitStreak = 0

    /// Creates a poller that publishes into `state` and records samples to `history`.
    init(state: AppState, history: HistoryStore,
         client: UsageFetching = UsageClient(),
         credentials: TokenProviding = CredentialsProvider(),
         copilotClient: CopilotUsageFetching = CopilotClient(),
         copilotCredentials: TokenProviding = CopilotCredentialsProvider()) {
        self.state = state
        self.history = history
        self.client = client
        self.credentials = credentials
        self.copilotClient = copilotClient
        self.copilotCredentials = copilotCredentials
    }

    /// User-configured refresh interval in seconds, floored to 10.
    var configuredInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.refreshInterval)
        return v >= 10 ? v : 60
    }

    /// Whether Copilot monitoring is enabled in Settings.
    var copilotEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.copilotEnabled)
    }

    /// Schedules the timer, polls immediately, and observes wake and settings changes.
    func start() {
        currentCopilotEnabled = copilotEnabled
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
        copilotCredentials.invalidate()
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
        // No opportunistic refreshes during a 429 backoff.
        if let until = claudeBackoffUntil, Date() < until {
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

    /// Reschedules on interval changes; re-polls when Copilot is toggled.
    @objc private func defaultsChanged() {
        if configuredInterval != currentInterval {
            DispatchQueue.main.async { [weak self] in self?.schedule() }
        }
        if copilotEnabled != currentCopilotEnabled {
            currentCopilotEnabled = copilotEnabled
            DispatchQueue.main.async { [weak self] in self?.refreshNow() }
        }
    }

    /// One poll: fetch all enabled providers concurrently, publish the merged
    /// snapshot, and record a history sample of the fresh values. A failed
    /// provider keeps its last-known limits visible and surfaces a message.
    @MainActor
    func tick() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        async let claudeTask = claudeResult()
        async let copilotTask = copilotResult(enabled: copilotEnabled)
        let claude = await claudeTask
        let copilot = await copilotTask

        var limits: [UsageLimit] = []
        var freshValues: [String: Double] = [:]
        var errors: [String] = []
        var anySuccess = false
        var fetchedAt = Date()

        switch claude {
        case .success(let fresh):
            anySuccess = true
            rateLimitStreak = 0
            claudeBackoffUntil = nil
            fetchedAt = fresh.fetchedAt
            limits += fresh.limits
            fresh.limits.forEach { freshValues[$0.id] = $0.percent }
        case .failure(let error):
            // Keep the last Claude limits visible; just surface the error.
            limits += previousLimits(for: .claude)
            if case UsageError.rateLimited(let retryAfter) = error {
                rateLimitStreak += 1
                // Honor Retry-After; otherwise 90 s doubling per consecutive
                // 429, capped at 15 min.
                let delay = retryAfter
                    ?? min(90 * pow(2, Double(rateLimitStreak - 1)), 900)
                claudeBackoffUntil = Date().addingTimeInterval(delay)
            }
            errors.append(error.localizedDescription)
            DebugLog.log("Tokes: Claude tick failed: \(error)")
        case nil:
            // Backing off after a 429 — no request made; keep last limits
            // and the banner until the window passes.
            limits += previousLimits(for: .claude)
            errors.append(UsageError.rateLimited(retryAfter: nil).localizedDescription ?? "")
        }

        if let copilot {
            switch copilot {
            case .success(let limit):
                anySuccess = true
                limits.append(limit)
                freshValues[limit.id] = limit.percent
            case .failure(let error):
                limits += previousLimits(for: .copilot)
                errors.append(error.localizedDescription)
                DebugLog.log("Tokes: Copilot tick failed: \(error)")
            }
        }

        // Publish only when something succeeded; on total failure the previous
        // snapshot (and its fetchedAt) stays as-is.
        if anySuccess {
            state.snapshot = UsageSnapshot(limits: limits, fetchedAt: fetchedAt)
            let sample = UsageSample(t: fetchedAt, v: freshValues)
            history.append(sample)
            state.samples = history.samples
        }
        state.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// The current snapshot's limits for one provider (used to carry stale
    /// data through a failed poll).
    private func previousLimits(for provider: UsageProvider) -> [UsageLimit] {
        state.snapshot?.limits.filter { $0.provider == provider } ?? []
    }

    /// Claude fetch wrapped in a Result for concurrent merging; nil while a
    /// 429 backoff window is active (no request is made).
    private func claudeResult() async -> Result<UsageSnapshot, Error>? {
        if let until = claudeBackoffUntil, Date() < until { return nil }
        do {
            return .success(try await fetchWithRetry())
        } catch {
            return .failure(error)
        }
    }

    /// Copilot fetch wrapped in a Result; nil when monitoring is disabled.
    private func copilotResult(enabled: Bool) async -> Result<UsageLimit, Error>? {
        guard enabled else { return nil }
        do {
            return .success(try await fetchCopilotWithRetry())
        } catch {
            return .failure(error)
        }
    }

    /// Fetches Claude usage, re-resolving credentials once on 401 in case
    /// Claude Code rotated the token.
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

    /// Fetches Copilot usage, re-reading credentials once on 401 in case the
    /// editor plugin rotated the token.
    private func fetchCopilotWithRetry() async throws -> UsageLimit {
        do {
            let token = try copilotCredentials.accessToken()
            return try await copilotClient.fetch(token: token)
        } catch CopilotError.unauthorized {
            copilotCredentials.invalidate()
            let token = try copilotCredentials.accessToken()
            return try await copilotClient.fetch(token: token)
        }
    }
}
