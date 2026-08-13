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
        let cutoff = Date().addingTimeInterval(-window)
        var pts = samples.compactMap { sample -> ChartPoint? in
            guard sample.t >= cutoff, let v = sample.v[limitID] else { return nil }
            return ChartPoint(date: sample.t, value: v)
        }
        pts = Self.downsample(pts, maxCount: 240)
        pts.append(ChartPoint(date: Date(), value: currentPercent))
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
                    .foregroundStyle(.tertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                if isSession {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                } else {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
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
