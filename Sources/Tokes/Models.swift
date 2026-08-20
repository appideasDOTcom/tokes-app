import AppKit
import SwiftUI

/// UserDefaults keys for user-configurable settings.
enum SettingsKeys {
    static let refreshInterval = "refreshInterval"
    static let menuBarLabel = "menuBarLabel"
    static let credentialSource = "credentialSource"
    static let copilotEnabled = "copilotEnabled"
    static let copilotCredentialSource = "copilotCredentialSource"
    static let showScopedWeekly = "showScopedWeekly"
    /// Security-scoped bookmarks for user-imported credentials files.
    static let claudeCredentialFile = "claudeCredentialFileBookmark"
    static let copilotCredentialFile = "copilotCredentialFileBookmark"

    /// Pre-picker on/off toggle for the menu bar text, migrated to `menuBarLabel`.
    static let legacyShowLabel = "showLabel"
}

/// Which measurement the menu bar draws as text beside the icon.
enum MenuBarLabel: String, CaseIterable {
    case off
    case highest
    case session
    case weeklyAll
    case weeklyScoped
    case copilot

    /// Menu title shown in Settings.
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .highest: return "Highest value"
        case .session: return "Session (5 hr)"
        case .weeklyAll: return "Weekly (7 day)"
        case .weeklyScoped: return "Weekly (model-specific)"
        case .copilot: return "Copilot Premium"
        }
    }

    /// The limit this option names, or nil when the snapshot doesn't report it
    /// (Copilot off, plan without a model-scoped weekly, nothing polled yet).
    func limit(in limits: [UsageLimit]) -> UsageLimit? {
        switch self {
        case .off: return nil
        case .highest: return limits.max { $0.percent < $1.percent }
        case .session: return limits.first { $0.id == "session" }
        case .weeklyAll: return limits.first { $0.id == "weekly_all" }
        case .weeklyScoped: return limits.first { $0.isScopedWeekly }
        case .copilot: return limits.first { $0.provider == .copilot }
        }
    }

    /// The options Settings offers: the two always-present Claude limits plus
    /// whichever optional measurements the other toggles have enabled.
    static func available(copilotEnabled: Bool, showScopedWeekly: Bool) -> [MenuBarLabel] {
        var result: [MenuBarLabel] = [.off, .highest, .session, .weeklyAll]
        if showScopedWeekly { result.append(.weeklyScoped) }
        if copilotEnabled { result.append(.copilot) }
        return result
    }

    /// Falls back to "Highest value" when this option is no longer offered,
    /// e.g. Copilot was selected and then turned off.
    func normalized(copilotEnabled: Bool, showScopedWeekly: Bool) -> MenuBarLabel {
        Self.available(copilotEnabled: copilotEnabled, showScopedWeekly: showScopedWeekly)
            .contains(self) ? self : .highest
    }

    /// Reads the stored selection, falling back to `.off` for missing or unknown values.
    static func current(in defaults: UserDefaults = .standard) -> MenuBarLabel {
        MenuBarLabel(rawValue: defaults.string(forKey: SettingsKeys.menuBarLabel) ?? "") ?? .off
    }
}

/// Where the Claude OAuth token comes from.
///
/// `.claudeCode` reads the credential store Claude Code owns, so it is compiled
/// out of the App Store build entirely — see `Capabilities`. The other two are
/// offered by every build: a file the user picks in an open panel is inside the
/// sandbox by macOS' own definition, and the manual token lives in Tokes' own
/// keychain item.
enum CredentialSource: String, CaseIterable {
    case claudeCode
    case importedFile
    case manual

    /// Radio-button title shown in Settings.
    var displayName: String {
        switch self {
        case .claudeCode: return "Use Claude Code sign-in (automatic)"
        case .importedFile: return "Import a Claude Code credentials file"
        case .manual: return "Manual OAuth token"
        }
    }

    /// The sources this build offers, most automatic first.
    static func available(for distribution: Distribution = .current) -> [CredentialSource] {
        switch distribution {
        case .direct: return [.claudeCode, .importedFile, .manual]
        case .appStore: return [.importedFile, .manual]
        }
    }

    /// First-run selection for this build.
    static func defaultSource(for distribution: Distribution = .current) -> CredentialSource {
        available(for: distribution)[0]
    }

    /// Falls back to this build's default when the stored value names a source
    /// this build doesn't offer.
    func normalized(for distribution: Distribution = .current) -> CredentialSource {
        Self.available(for: distribution).contains(self)
            ? self : Self.defaultSource(for: distribution)
    }

    /// Reads the stored selection, normalized to something this build offers.
    static func current(in defaults: UserDefaults = .standard) -> CredentialSource {
        (CredentialSource(rawValue: defaults.string(forKey: SettingsKeys.credentialSource) ?? "")
            ?? defaultSource()).normalized()
    }
}

/// Where the GitHub token comes from. `.editor` reads the Copilot plugin's own
/// config and the `gh` CLI, so it is compiled out of the App Store build for the
/// same reason `CredentialSource.claudeCode` is.
enum CopilotCredentialSource: String, CaseIterable {
    case editor
    case importedFile
    case manual

    /// Radio-button title shown in Settings.
    var displayName: String {
        switch self {
        case .editor: return "Use editor sign-in / gh CLI (automatic)"
        case .importedFile: return "Import a Copilot config file"
        case .manual: return "Manual GitHub token"
        }
    }

    /// The sources this build offers, most automatic first.
    static func available(for distribution: Distribution = .current) -> [CopilotCredentialSource] {
        switch distribution {
        case .direct: return [.editor, .importedFile, .manual]
        case .appStore: return [.importedFile, .manual]
        }
    }

    /// First-run selection for this build.
    static func defaultSource(for distribution: Distribution = .current) -> CopilotCredentialSource {
        available(for: distribution)[0]
    }

    /// Falls back to this build's default when the stored value names a source
    /// this build doesn't offer.
    func normalized(for distribution: Distribution = .current) -> CopilotCredentialSource {
        Self.available(for: distribution).contains(self)
            ? self : Self.defaultSource(for: distribution)
    }

    /// Reads the stored selection, normalized to something this build offers.
    static func current(in defaults: UserDefaults = .standard) -> CopilotCredentialSource {
        (CopilotCredentialSource(rawValue: defaults.string(forKey: SettingsKeys.copilotCredentialSource) ?? "")
            ?? defaultSource()).normalized()
    }
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
