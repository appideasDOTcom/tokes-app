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
    /// The `githubApp` source's pipeline; owns its own auth (see the type),
    /// so the token-provider seam above does not apply to it.
    private let githubFetcher: GitHubBillingFetching
    /// Where the two settings this class reads live. Injectable so a lifecycle
    /// test can drive an interval or Copilot change in its own domain instead
    /// of mutating the process-wide one another test may be reading.
    private let defaults: UserDefaults

    /// `private(set)` rather than `private` so a test can prove that a settings
    /// change produced a *new* timer at the new interval. Nothing outside this
    /// class may hold or invalidate it.
    private(set) var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var currentCopilotEnabled = false
    private var inFlight = false
    /// While set and in the future, Claude polls are skipped entirely (429
    /// backoff). Copilot polling is unaffected.
    private var claudeBackoffUntil: Date?
    private var rateLimitStreak = 0
    /// When each provider last returned fresh data, so a snapshot carrying one
    /// provider's stale limits forward can be stamped with the age of the
    /// oldest data it actually contains — see `tick()`.
    private var lastFetch: [UsageProvider: Date] = [:]
    /// When `refreshIfStale` last let a poll through, which is not the same
    /// question as how old the data is — see the rate floor there.
    private var lastOpportunisticRefresh: Date?

    /// Test seam: the clock every deadline in this class is measured against.
    /// Replacing it is the only way to exercise a backoff window expiring
    /// without the test sleeping for it.
    var now: () -> Date = { Date() }

    /// How long after a wake notification the catch-up poll fires, giving the
    /// network a moment to reconnect. A test seam only — nothing changes it in
    /// the app, and a test that waited the real three seconds for it would be
    /// the slowest in the suite.
    var wakeDelay: TimeInterval = 3

    /// Creates a poller that publishes into `state` and records samples to `history`.
    init(state: AppState, history: HistoryStore,
         client: UsageFetching = UsageClient(),
         credentials: TokenProviding = CredentialsProvider(),
         copilotClient: CopilotUsageFetching = CopilotClient(),
         copilotCredentials: TokenProviding = CopilotCredentialsProvider(),
         githubFetcher: GitHubBillingFetching = GitHubBillingFetcher(),
         defaults: UserDefaults = .standard) {
        self.state = state
        self.history = history
        self.client = client
        self.credentials = credentials
        self.copilotClient = copilotClient
        self.copilotCredentials = copilotCredentials
        self.githubFetcher = githubFetcher
        self.defaults = defaults
    }

    /// User-configured refresh interval in seconds, floored to 10.
    var configuredInterval: TimeInterval {
        let v = defaults.double(forKey: SettingsKeys.refreshInterval)
        return v >= 10 ? v : 60
    }

    /// Whether Copilot monitoring is enabled in Settings.
    var copilotEnabled: Bool {
        defaults.bool(forKey: SettingsKeys.copilotEnabled)
    }

    /// Schedules the timer, polls immediately, and observes wake and settings changes.
    ///
    /// Starts from a clean slate every time. `addObserver` genuinely does not
    /// deduplicate — measured: the same observer/selector/name pair registered
    /// twice is delivered twice — so without the reset a second `start()` would
    /// leave two live registrations. It would *not* double the network traffic,
    /// because `tick()`'s `inFlight` guard coalesces the two resulting polls;
    /// this is hygiene, not a fix for an observed bug. `AppDelegate` calls
    /// `start()` once, but nothing in the type said so.
    func start() {
        stop()
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
        githubFetcher.invalidate()
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
        if let until = claudeBackoffUntil, now() < until {
            return false
        }
        // Data age answers "is this stale?"; it does not answer "should I ask
        // again?". The two agree until a provider gets stuck failing, and then
        // they diverge for good: `fetchedAt` is the age of the *oldest* data in
        // the snapshot, so a Copilot token that expired an hour ago pins it
        // there permanently and the staleness test below is true forever. The
        // popover opens on *hover* (0.15 s dwell — StatusItemController), so
        // without this floor every brush past the menu bar becomes a poll, with
        // no limit, against the endpoint whose 429s `backoffDelay` exists to
        // absorb. The floor is the same interval, measured from the last poll
        // this function actually let through rather than from the data.
        if let last = lastOpportunisticRefresh,
           now().timeIntervalSince(last) < seconds {
            return false
        }
        // Still stale-gated, so opening the popover on fresh data costs nothing.
        // A provider outage means every *eligible* opening retries — the intent
        // is unchanged, the rate is bounded.
        if let fetchedAt = state.snapshot?.fetchedAt,
           now().timeIntervalSince(fetchedAt) <= seconds {
            return false
        }
        lastOpportunisticRefresh = now()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeDelay) { [weak self] in
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

        // The published snapshot is stamped with the age of the *oldest* data
        // it contains, not with "now". A tick where Copilot succeeds and Claude
        // does not carries hour-old Claude numbers forward, and stamping that
        // "just now" would make the popover's "Updated N ago" claim a freshness
        // half the snapshot does not have. `lastFetch` is the exact per-provider
        // time; `state.snapshot?.fetchedAt` covers the first tick after the
        // snapshot was set from outside (tests, and a future restore).
        var oldest: Date?
        let previousFetch = state.snapshot?.fetchedAt
        func stamp(_ date: Date?) {
            guard let date else { return }
            oldest = min(oldest ?? date, date)
        }

        switch claude {
        case .success(let fresh):
            anySuccess = true
            rateLimitStreak = 0
            claudeBackoffUntil = nil
            lastFetch[.claude] = fresh.fetchedAt
            stamp(fresh.fetchedAt)
            limits += fresh.limits
            fresh.limits.forEach { freshValues[$0.id] = $0.percent }
        case .failure(let error):
            // Keep the last Claude limits visible; just surface the error.
            let carried = previousLimits(for: .claude)
            limits += carried
            if !carried.isEmpty { stamp(lastFetch[.claude] ?? previousFetch) }
            if case UsageError.rateLimited(let retryAfter) = error {
                rateLimitStreak += 1
                claudeBackoffUntil = now().addingTimeInterval(
                    Self.backoffDelay(retryAfter: retryAfter, streak: rateLimitStreak))
            }
            errors.append(error.localizedDescription)
            DebugLog.log("Tokes: Claude tick failed: \(error)")
        case nil:
            // Backing off after a 429 — no request made; keep last limits
            // and the banner until the window passes.
            let carried = previousLimits(for: .claude)
            limits += carried
            if !carried.isEmpty { stamp(lastFetch[.claude] ?? previousFetch) }
            errors.append(UsageError.rateLimited(retryAfter: nil).localizedDescription)
        }

        if let copilot {
            switch copilot {
            case .success(let limit):
                anySuccess = true
                lastFetch[.copilot] = now()
                stamp(lastFetch[.copilot])
                limits.append(limit)
                freshValues[limit.id] = limit.percent
            case .failure(let error):
                let carried = previousLimits(for: .copilot)
                limits += carried
                if !carried.isEmpty { stamp(lastFetch[.copilot] ?? previousFetch) }
                errors.append(error.localizedDescription)
                DebugLog.log("Tokes: Copilot tick failed: \(error)")
            }
        }

        // Publish only when something succeeded; on total failure the previous
        // snapshot (and its fetchedAt) stays as-is.
        if anySuccess {
            let fetchedAt = oldest ?? now()
            state.snapshot = UsageSnapshot(limits: limits, fetchedAt: fetchedAt)
            // The sample records what was fetched *this* tick, so it is stamped
            // with now regardless of what stale limits rode along in the
            // snapshot — a history point must sit at the time it was measured.
            history.append(UsageSample(t: now(), v: freshValues))
            state.samples = history.samples
        }
        state.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// How long Claude polling pauses after a 429.
    ///
    /// `Retry-After` is honored but clamped, in both directions, because both
    /// ends are reachable from a server answer alone: a `0` or a past date
    /// (which `Double.init` reads as `0`/negative) would leave no backoff at
    /// all and put Tokes back on the endpoint at the next tick, and a value
    /// like `1e9` would park polling for the life of the process. Absent or
    /// unparsable — including the RFC 9110 HTTP-date form, which Tokes does not
    /// read — it is 90 s doubling per consecutive 429.
    ///
    /// The floor is one poll interval's worth of patience; the ceiling is the
    /// same 15 min the doubling schedule caps at.
    static func backoffDelay(retryAfter: TimeInterval?, streak: Int) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 30), 900) }
        return min(90 * pow(2, Double(max(streak, 1) - 1)), 900)
    }

    /// The current snapshot's limits for one provider (used to carry stale
    /// data through a failed poll).
    private func previousLimits(for provider: UsageProvider) -> [UsageLimit] {
        state.snapshot?.limits.filter { $0.provider == provider } ?? []
    }

    /// Claude fetch wrapped in a Result for concurrent merging; nil while a
    /// 429 backoff window is active (no request is made).
    private func claudeResult() async -> Result<UsageSnapshot, Error>? {
        if let until = claudeBackoffUntil, now() < until { return nil }
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
    /// editor plugin rotated the token. The `githubApp` source dispatches to
    /// its own pipeline instead — it refreshes its own tokens, so the
    /// invalidate-and-retry dance below is already inside it.
    private func fetchCopilotWithRetry() async throws -> UsageLimit {
        if CopilotCredentialSource.current(in: defaults) == .githubApp {
            return try await githubFetcher.fetch()
        }
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
