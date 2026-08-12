import XCTest

@testable import Tokes

final class UsageChartTests: XCTestCase {
    private func points(_ values: [Double]) -> [ChartPoint] {
        values.enumerated().map {
            ChartPoint(date: Date(timeIntervalSince1970: Double($0.offset) * 60), value: $0.element)
        }
    }

    func testDownsampleIsNoOpUnderLimit() {
        let pts = points([1, 2, 3])
        XCTAssertEqual(UsageChart.downsample(pts, maxCount: 240).map(\.value), [1, 2, 3])
    }

    func testDownsampleAveragesChunks() {
        // 10 points, max 4 → chunks of 3: [0,10,20] [30,40,50] [60,70,80] [90]
        let out = UsageChart.downsample(points([0, 10, 20, 30, 40, 50, 60, 70, 80, 90]), maxCount: 4)
        XCTAssertEqual(out.map(\.value), [10, 40, 70, 90])
    }

    func testDownsampleUsesChunkMidpointDates() {
        let out = UsageChart.downsample(points([0, 10, 20, 30, 40, 50]), maxCount: 2)
        // Chunks of 3; midpoint is the middle sample's date.
        XCTAssertEqual(out.map { $0.date.timeIntervalSince1970 }, [60, 240])
    }

    func testDownsampleKeepsChronologicalOrderAndBound() {
        let out = UsageChart.downsample(points((0..<100).map(Double.init)), maxCount: 10)
        XCTAssertLessThanOrEqual(out.count, 10)
        XCTAssertEqual(out.map(\.date), out.map(\.date).sorted())
    }

    func testChartPointIdentityIsItsDate() {
        let p = ChartPoint(date: Date(timeIntervalSince1970: 42), value: 1)
        XCTAssertEqual(p.id, p.date)
    }
}
