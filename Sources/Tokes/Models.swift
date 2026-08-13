import AppKit
import SwiftUI

/// UserDefaults keys for user-configurable settings.
enum SettingsKeys {
    static let refreshInterval = "refreshInterval"
    static let showLabel = "showLabel"
    static let credentialSource = "credentialSource"
    static let copilotEnabled = "copilotEnabled"
    static let copilotCredentialSource = "copilotCredentialSource"
    static let showScopedWeekly = "showScopedWeekly"
}

/// Source of the OAuth token: Claude Code's stored credentials or a manually pasted token.
enum CredentialSource: String {
    case claudeCode
    case manual
}

/// Source of the GitHub token: editor Copilot sign-in / gh CLI, or a manually pasted token.
enum CopilotCredentialSource: String {
    case editor
    case manual
}

/// The service a usage limit belongs to; drives grouping and visual separation.
enum UsageProvider: String, CaseIterable, Codable {
    case claude
    case copilot

    /// Group heading shown in the popover.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .copilot: return "GitHub Copilot"
        }
    }
}

/// One rate-limit bucket as reported by a usage API.
struct UsageLimit: Identifiable, Equatable {
    /// Stable identity across polls, e.g. "session", "weekly_all", "copilot_premium"
    let id: String
    let label: String
    let percent: Double
    let severity: String
    let resetsAt: Date?
    /// true for the 5-hour session bucket, false for weekly/monthly buckets
    let isSession: Bool
    /// Which service reported this limit.
    let provider: UsageProvider
    /// Optional caption, e.g. Copilot's "37 of 7,000 credits used".
    let detail: String?

    /// Creates a limit; provider defaults to Claude and detail to none.
    init(id: String, label: String, percent: Double, severity: String,
         resetsAt: Date?, isSession: Bool,
         provider: UsageProvider = .claude, detail: String? = nil) {
        self.id = id
        self.label = label
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.isSession = isSession
        self.provider = provider
        self.detail = detail
    }

    /// Time span the limit's chart displays: 6 hours for session, 7 days otherwise.
    var chartWindow: TimeInterval {
        isSession ? 6 * 3600 : 7 * 24 * 3600
    }

    /// true for the per-model weekly bucket (e.g. "Weekly Fable"), which not
    /// every plan reports and the Settings toggle can hide.
    var isScopedWeekly: Bool {
        id.hasPrefix("weekly_scoped")
    }
}

/// The full set of limits from one successful poll.
struct UsageSnapshot: Equatable {
    let limits: [UsageLimit]
    let fetchedAt: Date
}

/// A single point of sampled history: limit id -> percent
struct UsageSample: Codable {
    let t: Date
    let v: [String: Double]
}

/// Observable state shared by the poller and the UI. Mutated only on the
/// main thread (poller ticks run on @MainActor).
final class AppState: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var samples: [UsageSample] = []
}

/// Maps a usage percentage to its severity color: green < 60, orange < 85, red ≥ 85.
enum SeverityColor {
    /// AppKit color for the given percentage.
    static func nsColor(for percent: Double) -> NSColor {
        if percent >= 85 { return .systemRed }
        if percent >= 60 { return .systemOrange }
        return .systemGreen
    }

    /// SwiftUI color for the given percentage.
    static func color(for percent: Double) -> Color {
        Color(nsColor: nsColor(for: percent))
    }
}

/// Formats reset timestamps as short countdowns, e.g. "resets in 1d 2h".
enum ResetFormatter {
    /// Human-readable countdown from `now` until `date`.
    static func resetsIn(_ date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resetting…" }
        let minutes = Int(seconds / 60)
        let days = minutes / (60 * 24)
        let hours = (minutes % (60 * 24)) / 60
        let mins = minutes % 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(mins)m" }
        return "resets in \(mins)m"
    }
}
