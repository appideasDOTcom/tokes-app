import Foundation

enum UsageError: LocalizedError {
    case unauthorized
    case http(Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Not authorized — open Claude Code to refresh your login, or set a token in Settings."
        case .http(let code):
            return "Usage API returned HTTP \(code)."
        case .decode(let detail):
            return "Could not parse usage response (\(detail))."
        }
    }
}

/// Client for Anthropic's OAuth usage endpoint — the same source the
/// Claude Code VS Code extension uses for its Account & Usage panel.
struct UsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.http(0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }

        let decoded: APIResponse
        do {
            decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }

        let limits = Self.mapLimits(decoded)
        guard !limits.isEmpty else { throw UsageError.decode("no limits in response") }
        return UsageSnapshot(limits: limits, fetchedAt: Date())
    }

    /// Maps the API's `limits` array to the three session boundaries shown in
    /// VS Code (session, weekly all-models, weekly model-scoped), with a
    /// fallback to the legacy flat fields if `limits` is ever absent.
    private static func mapLimits(_ api: APIResponse) -> [UsageLimit] {
        var result: [UsageLimit] = []
        if let apiLimits = api.limits, !apiLimits.isEmpty {
            for l in apiLimits {
                guard let kind = l.kind, let percent = l.percent else { continue }
                switch kind {
                case "session":
                    result.append(UsageLimit(
                        id: "session", label: "Session (5 hr)", percent: percent,
                        severity: l.severity ?? "normal",
                        resetsAt: APIDate.parse(l.resets_at), isSession: true))
                case "weekly_all":
                    result.append(UsageLimit(
                        id: "weekly_all", label: "Weekly (7 day)", percent: percent,
                        severity: l.severity ?? "normal",
                        resetsAt: APIDate.parse(l.resets_at), isSession: false))
                case "weekly_scoped":
                    let model = l.scope?.model?.display_name ?? "Model"
                    result.append(UsageLimit(
                        id: "weekly_scoped:\(model)", label: "Weekly \(model)", percent: percent,
                        severity: l.severity ?? "normal",
                        resetsAt: APIDate.parse(l.resets_at), isSession: false))
                default:
                    continue
                }
            }
        }
        if result.isEmpty {
            if let w = api.five_hour, let u = w.utilization {
                result.append(UsageLimit(id: "session", label: "Session (5 hr)", percent: u,
                                         severity: "normal", resetsAt: APIDate.parse(w.resets_at), isSession: true))
            }
            if let w = api.seven_day, let u = w.utilization {
                result.append(UsageLimit(id: "weekly_all", label: "Weekly (7 day)", percent: u,
                                         severity: "normal", resetsAt: APIDate.parse(w.resets_at), isSession: false))
            }
        }
        // Stable display order: session, weekly_all, then scoped buckets.
        let rank: (UsageLimit) -> Int = { l in
            if l.id == "session" { return 0 }
            if l.id == "weekly_all" { return 1 }
            return 2
        }
        return result.sorted { rank($0) < rank($1) }
    }
}

enum APIDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let micro: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s) ?? micro.date(from: s)
    }
}

// MARK: - Wire format

private struct APIResponse: Decodable {
    let limits: [APILimit]?
    let five_hour: APIWindow?
    let seven_day: APIWindow?
}

private struct APIWindow: Decodable {
    let utilization: Double?
    let resets_at: String?
}

private struct APILimit: Decodable {
    let kind: String?
    let group: String?
    let percent: Double?
    let severity: String?
    let resets_at: String?
    let scope: APIScope?
}

private struct APIScope: Decodable {
    let model: APIModel?
}

private struct APIModel: Decodable {
    let display_name: String?
}
