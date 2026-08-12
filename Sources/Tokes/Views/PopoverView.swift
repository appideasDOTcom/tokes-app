import SwiftUI

/// Popover content: header actions, optional error banner, a section per limit,
/// and a footer.
struct PopoverView: View {
    @ObservedObject var state: AppState
    let onHoverChanged: (Bool) -> Void
    let onSettings: () -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = state.errorMessage {
                errorBanner(error)
            }
            if let snapshot = state.snapshot {
                ForEach(snapshot.limits) { limit in
                    LimitSection(limit: limit, samples: state.samples)
                }
            } else if state.errorMessage == nil {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Connecting…").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 24)
            }
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onHover(perform: onHoverChanged)
    }

    /// Title row with refresh, settings, and quit buttons.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Tokes")
        }
    }

    /// "Updated N ago" caption and app name.
    private var footer: some View {
        HStack {
            if let snapshot = state.snapshot {
                Text("Updated ")
                    .font(.caption2).foregroundStyle(.tertiary)
                + Text(snapshot.fetchedAt, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
                + Text(" ago")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("Tokes")
                .font(.caption2).foregroundStyle(.quaternary)
        }
    }

    /// Inline warning banner for fetch errors.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One limit: severity dot, label, percent, history chart, and reset countdown.
struct LimitSection: View {
    let limit: UsageLimit
    let samples: [UsageSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(SeverityColor.color(for: limit.percent))
                    .frame(width: 7, height: 7)
                Text(limit.label)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
            }
            UsageChart(
                limitID: limit.id,
                window: limit.chartWindow,
                isSession: limit.isSession,
                color: SeverityColor.color(for: limit.percent),
                samples: samples,
                currentPercent: limit.percent)
                .frame(height: 64)
            if let resetsAt = limit.resetsAt {
                Text(ResetFormatter.resetsIn(resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
