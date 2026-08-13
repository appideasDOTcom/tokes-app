import Foundation

/// Copilot usage-endpoint failures, with user-facing descriptions.
enum CopilotError: LocalizedError, Equatable {
    case unauthorized
    case http(Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "GitHub token rejected — sign in to Copilot in your editor, or set a token in Settings."
        case .http(let code):
            return "Copilot API returned HTTP \(code)."
        case .decode(let detail):
            return "Could not parse Copilot response (\(detail))."
        }
    }
}

/// Client for GitHub's internal Copilot entitlement endpoint — the same source
/// editor Copilot plugins use for their premium-request quota display.
struct CopilotClient {
    private static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    /// Session used for requests; injectable for tests.
    var session: URLSession = .shared

    /// Fetches the premium-requests quota with the given GitHub token.
    func fetch(token: String) async throws -> UsageLimit {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tokes/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CopilotError.http(0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw CopilotError.unauthorized }
        guard http.statusCode == 200 else { throw CopilotError.http(http.statusCode) }

        return try Self.limit(from: data)
    }

    /// Decodes a Copilot entitlement body into the premium-requests limit.
    static func limit(from data: Data) throws -> UsageLimit {
        let decoded: APIResponse
        do {
            decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            throw CopilotError.decode(error.localizedDescription)
        }
        guard let quota = decoded.quota_snapshots?.premium_interactions else {
            throw CopilotError.decode("no premium_interactions quota in response")
        }

        let percent: Double
        if quota.unlimited == true {
            percent = 0
        } else if let remaining = quota.percent_remaining {
            percent = max(0, min(100, 100 - remaining))
        } else if let entitlement = quota.entitlement, entitlement > 0,
                  let used = quota.credits_used {
            percent = max(0, min(100, used / entitlement * 100))
        } else {
            throw CopilotError.decode("no usable quota fields in response")
        }

        return UsageLimit(
            id: "copilot_premium",
            label: "Copilot Premium",
            percent: percent,
            severity: "normal",
            resetsAt: resetDate(from: decoded),
            isSession: false,
            provider: .copilot,
            detail: detail(for: quota))
    }

    /// "37 of 7,000 credits used", or a plan note when the quota is unlimited.
    private static func detail(for quota: APIQuota) -> String? {
        if quota.unlimited == true { return "Unlimited plan" }
        guard let entitlement = quota.entitlement, let used = quota.credits_used else { return nil }
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = 0
        let usedStr = fmt.string(from: NSNumber(value: used)) ?? String(Int(used))
        let totalStr = fmt.string(from: NSNumber(value: entitlement)) ?? String(Int(entitlement))
        return "\(usedStr) of \(totalStr) credits used"
    }

    /// Parses the reset date: full UTC timestamp preferred, date-only fallback.
    private static func resetDate(from api: APIResponse) -> Date? {
        if let date = APIDate.parse(api.quota_reset_date_utc) { return date }
        guard let s = api.quota_reset_date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: s)
    }
}

// MARK: - Wire format

/// Top-level Copilot entitlement response (fields Tokes reads).
private struct APIResponse: Decodable {
    let quota_snapshots: APIQuotaSnapshots?
    let quota_reset_date: String?
    let quota_reset_date_utc: String?
}

/// The per-feature quota buckets; only premium requests are metered.
private struct APIQuotaSnapshots: Decodable {
    let premium_interactions: APIQuota?
}

/// One quota bucket's counters.
private struct APIQuota: Decodable {
    let entitlement: Double?
    let remaining: Double?
    let credits_used: Double?
    let percent_remaining: Double?
    let unlimited: Bool?
}
