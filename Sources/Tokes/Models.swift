import AppKit
import SwiftUI

enum SettingsKeys {
    static let refreshInterval = "refreshInterval"
    static let showLabel = "showLabel"
    static let credentialSource = "credentialSource"
}

enum CredentialSource: String {
    case claudeCode
    case manual
}

/// One rate-limit bucket as reported by the usage API.
struct UsageLimit: Identifiable, Equatable {
    /// Stable identity across polls, e.g. "session", "weekly_all", "weekly_scoped:Fable"
    let id: String
    let label: String
    let percent: Double
    let severity: String
    let resetsAt: Date?
    /// true for the 5-hour session bucket, false for weekly buckets
    let isSession: Bool

    var chartWindow: TimeInterval {
        isSession ? 6 * 3600 : 7 * 24 * 3600
    }
}

struct UsageSnapshot: Equatable {
    let limits: [UsageLimit]
    let fetchedAt: Date
}

/// A single point of sampled history: limit id -> percent
struct UsageSample: Codable {
    let t: Date
    let v: [String: Double]
}

/// Mutated only on the main thread (poller ticks run on @MainActor).
final class AppState: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var samples: [UsageSample] = []
}

enum SeverityColor {
    static func nsColor(for percent: Double) -> NSColor {
        if percent >= 85 { return .systemRed }
        if percent >= 60 { return .systemOrange }
        return .systemGreen
    }

    static func color(for percent: Double) -> Color {
        Color(nsColor: nsColor(for: percent))
    }
}

enum ResetFormatter {
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
