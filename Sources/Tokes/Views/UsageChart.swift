import Charts
import SwiftUI

/// A single (time, percent) chart sample.
struct ChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Line chart of one limit's sampled history. Session charts show the last
/// 6 hours; weekly charts the last 7 days. Y is always 0–100%.
struct UsageChart: View {
    let limitID: String
    let window: TimeInterval
    let isSession: Bool
    let color: Color
    let samples: [UsageSample]
    let currentPercent: Double
    /// Dashed line stroke; distinguishes Copilot charts from Claude's solid lines.
    var dashed = false

    /// This limit's samples within the window, downsampled, plus a "now" point
    /// so the chart is alive from the first poll.
    private var points: [ChartPoint] {
        Self.points(samples: samples, limitID: limitID, window: window,
                    currentPercent: currentPercent)
    }

    /// This limit's samples within the window, downsampled, plus a "now" point.
    ///
    /// Static and taking its clock so the two things the filter is for can be
    /// asserted: dropping samples older than the window, and dropping other
    /// limits' series out of this chart. Every seeded sample in the view smoke
    /// tests is inside the window and carries every limit id, so before this
    /// the `guard` had only ever taken its accept arm.
    static func points(samples: [UsageSample], limitID: String, window: TimeInterval,
                       currentPercent: Double, now: Date = Date()) -> [ChartPoint] {
        let cutoff = now.addingTimeInterval(-window)
        var pts = samples.compactMap { sample -> ChartPoint? in
            guard sample.t >= cutoff, let v = sample.v[limitID] else { return nil }
            return ChartPoint(date: sample.t, value: v)
        }
        pts = downsample(pts, maxCount: 240)
        pts.append(ChartPoint(date: now, value: currentPercent))
        return pts
    }

    var body: some View {
        let now = Date()
        let pts = points
        Chart {
            ForEach(pts) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Usage", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.22), color.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.date), y: .value("Usage", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round,
                                           dash: dashed ? [5, 3] : []))
            }
            if let last = pts.last {
                PointMark(x: .value("Time", last.date), y: .value("Usage", last.value))
                    .foregroundStyle(color)
                    .symbolSize(24)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: now.addingTimeInterval(-window)...now)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                if isSession {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                } else {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .center) {
            if pts.count < 3 {
                Text("Collecting history…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Chunk-averages history down to a renderable point count.
    static func downsample(_ pts: [ChartPoint], maxCount: Int) -> [ChartPoint] {
        // A zero here divides by zero and traps on the Int conversion rather
        // than throwing. The only call site passes 240, but this is a static
        // API the tests drive directly, and a trap is the wrong way to find out.
        guard maxCount > 0 else { return pts }
        guard pts.count > maxCount else { return pts }
        let chunkSize = Int(ceil(Double(pts.count) / Double(maxCount)))
        return stride(from: 0, to: pts.count, by: chunkSize).map { start in
            let chunk = pts[start..<min(start + chunkSize, pts.count)]
            let midDate = chunk[chunk.startIndex + chunk.count / 2].date
            let avg = chunk.reduce(0.0) { $0 + $1.value } / Double(chunk.count)
            return ChartPoint(date: midDate, value: avg)
        }
    }
}
