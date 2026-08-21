import Foundation

/// Which billing meter GitHub reported Copilot usage on. AI credits replaced
/// premium requests on 2026-06-01; premium requests remain only for
/// grandfathered annual plans, so a given account has rows on exactly one.
enum CopilotBillingMode: String {
    case aiCredits
    case premiumRequests
}

/// Client for GitHub's documented per-user billing usage reports
/// (`GET /users/{login}/settings/billing/{meter}/usage`) — the sanctioned
/// replacement for the internal `copilot_internal/user` endpoint. The reports
/// carry raw quantities only; entitlement, percentage, and reset date are the
/// caller's to derive (see `GitHubBillingFetcher`).
struct CopilotBillingClient {
    /// Session used for requests; injectable for tests.
    var session: URLSession = .shared

    /// This month's aggregated usage on one meter.
    struct MonthUsage: Equatable {
        let mode: CopilotBillingMode
        /// Total units consumed, including any billed overage.
        let grossQuantity: Double
        /// Dollars billed beyond the included allowance.
        let overageAmount: Double
    }

    /// Fetches the current month's Copilot usage: the AI-credit meter first,
    /// falling back to the legacy premium-request meter, nil when neither has
    /// rows (typically an organization-provided seat, whose billing GitHub
    /// does not expose per user).
    func fetchMonthUsage(token: String, login: String, now: Date) async throws -> MonthUsage? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)

        if let usage = try await fetchMeter("ai_credit", mode: .aiCredits,
                                            token: token, login: login, year: year, month: month) {
            return usage
        }
        return try await fetchMeter("premium_request", mode: .premiumRequests,
                                    token: token, login: login, year: year, month: month)
    }

    /// One meter's report, aggregated; nil when it has no rows or the endpoint
    /// 404s (no billing platform data for this account).
    private func fetchMeter(_ meter: String, mode: CopilotBillingMode, token: String,
                            login: String, year: Int, month: Int) async throws -> MonthUsage? {
        var request = URLRequest(url: Self.usageURL(login: login, meter: meter,
                                                    year: year, month: month))
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tokes/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CopilotError.http(0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw CopilotError.unauthorized }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw CopilotError.http(http.statusCode) }

        let report: UsageReport
        do {
            report = try JSONDecoder().decode(UsageReport.self, from: data)
        } catch {
            throw CopilotError.decode(error.localizedDescription)
        }
        guard let items = report.usageItems, !items.isEmpty else { return nil }
        return MonthUsage(
            mode: mode,
            grossQuantity: items.reduce(0) { $0 + ($1.grossQuantity ?? 0) },
            overageAmount: items.reduce(0) { $0 + ($1.netAmount ?? 0) })
    }

    static func usageURL(login: String, meter: String, year: Int, month: Int) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert("-")
        let safeLogin = login.addingPercentEncoding(withAllowedCharacters: allowed) ?? login
        return URL(string: "https://api.github.com/users/\(safeLogin)/settings/billing/"
            + "\(meter)/usage?year=\(year)&month=\(month)")!
    }

    // MARK: - Wire format

    /// A billing usage report (fields Tokes reads). `netAmount` is the billed
    /// overage in dollars; `grossQuantity` includes allowance-covered units.
    private struct UsageReport: Decodable {
        let usageItems: [Item]?

        struct Item: Decodable {
            let grossQuantity: Double?
            let netAmount: Double?
        }
    }
}

/// Abstraction over the GitHub-App fetch pipeline, injectable for tests.
protocol GitHubBillingFetching: AnyObject {
    func fetch() async throws -> UsageLimit
    func invalidate()
}

/// The `githubApp` credential source's whole pipeline: reads the stored token
/// set, refreshes it when expired (persisting the rotated refresh token before
/// using it), calls the billing report endpoints, and shapes the result into a
/// `UsageLimit` against the configured plan allowance.
///
/// Auth and fetch live in one type because for a self-refreshing OAuth session
/// they are one unit — unlike the other sources, there is no static token a
/// `TokenProviding` could hand the poller.
final class GitHubBillingFetcher: GitHubBillingFetching {
    /// The keychain slot the token set lives in; injectable for tests.
    var keychainService = CredentialsProvider.manualService
    /// Where the plan/allowance settings are read from; injectable for tests.
    var defaults: UserDefaults = .standard
    var deviceAuth = GitHubDeviceAuth()
    var billing = CopilotBillingClient()
    /// Test seam: the clock expiry and reset dates are measured against.
    var now: () -> Date = { Date() }

    private var cached: GitHubAppTokens?

    /// Drops the cached token set so the next poll re-reads the keychain
    /// (e.g. after connecting or disconnecting in Settings).
    func invalidate() {
        cached = nil
    }

    /// One poll: refresh the token if it is (or turns out to be) expired,
    /// fetch the month's report, and shape it.
    func fetch() async throws -> UsageLimit {
        var tokens = try currentTokens()
        if tokens.accessExpired(at: now()) {
            tokens = try await refresh(tokens)
        }
        do {
            return try await fetchUsage(tokens)
        } catch CopilotError.unauthorized {
            tokens = try await refresh(tokens)
            return try await fetchUsage(tokens)
        }
    }

    private func currentTokens() throws -> GitHubAppTokens {
        if let cached { return cached }
        guard let stored = GitHubAppTokens.load(service: keychainService) else {
            throw GitHubAuthError.notConnected
        }
        cached = stored
        return stored
    }

    /// Rotates the token pair. A dead session (no refresh token, refresh token
    /// itself expired, or GitHub rejecting it) surfaces as `notConnected`, the
    /// error Settings answers with a sign-in button.
    private func refresh(_ tokens: GitHubAppTokens) async throws -> GitHubAppTokens {
        guard let refreshToken = tokens.refreshToken else { throw GitHubAuthError.notConnected }
        if let deadline = tokens.refreshExpiresAt, now() >= deadline {
            throw GitHubAuthError.notConnected
        }
        let grant: GitHubDeviceAuth.TokenGrant
        do {
            grant = try await deviceAuth.refresh(refreshToken: refreshToken)
        } catch GitHubAuthError.oauth {
            // GitHub declined the refresh token — the session is dead, not flaky.
            throw GitHubAuthError.notConnected
        }
        let updated = GitHubAppTokens(grant: grant, login: tokens.login, issuedAt: now())
        // Persist before first use: a refresh rotates the refresh token, so a
        // lost write is a lost session.
        guard updated.save(service: keychainService) else { throw GitHubAuthError.storage }
        cached = updated
        return updated
    }

    private func fetchUsage(_ tokens: GitHubAppTokens) async throws -> UsageLimit {
        guard let usage = try await billing.fetchMonthUsage(token: tokens.accessToken,
                                                            login: tokens.login,
                                                            now: now()) else {
            throw GitHubAuthError.noBillingData
        }
        let plan = CopilotPlan.current(in: defaults)
        let custom = defaults.double(forKey: SettingsKeys.copilotCustomAllowance)
        return Self.limit(usage: usage,
                          allowance: plan.allowance(mode: usage.mode, custom: custom),
                          now: now())
    }

    // MARK: - Shaping (pure, testable)

    /// Shapes a month's report into the popover row. The id stays
    /// `copilot_premium` across both meters so the history series survives an
    /// account's migration from premium requests to AI credits.
    static func limit(usage: CopilotBillingClient.MonthUsage, allowance: Double,
                      now: Date) -> UsageLimit {
        let percent = allowance > 0 ? usage.grossQuantity / allowance * 100 : 0
        return UsageLimit(
            id: "copilot_premium",
            label: usage.mode == .aiCredits ? "Copilot Credits" : "Copilot Premium",
            percent: percent,
            severity: "normal",
            resetsAt: nextMonthReset(after: now),
            isSession: false,
            provider: .copilot,
            detail: detail(usage: usage, allowance: allowance))
    }

    /// "412 of 1,500 AI credits used", plus the overage when GitHub billed one.
    static func detail(usage: CopilotBillingClient.MonthUsage, allowance: Double) -> String {
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = 0
        func str(_ value: Double) -> String {
            fmt.string(from: NSNumber(value: value)) ?? String(Int(value))
        }
        let unit = usage.mode == .aiCredits ? "AI credits" : "premium requests"
        var text = "\(str(usage.grossQuantity)) of \(str(allowance)) \(unit) used"
        if usage.overageAmount > 0 {
            text += String(format: " — $%.2f overage", usage.overageAmount)
        }
        return text
    }

    /// Both meters reset at 00:00:00 UTC on the first of each month (documented),
    /// so the reset is derived, not reported.
    static func nextMonthReset(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var start = calendar.dateComponents([.year, .month], from: date)
        start.day = 1
        let firstOfThisMonth = calendar.date(from: start)!
        return calendar.date(byAdding: .month, value: 1, to: firstOfThisMonth)!
    }
}
