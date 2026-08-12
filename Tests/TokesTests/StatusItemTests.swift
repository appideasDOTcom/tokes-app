import AppKit
import XCTest

@testable import Tokes

final class StatusIconTests: XCTestCase {
    func testIconSizeForThreeBars() {
        let icon = StatusItemController.makeIcon(limits: [
            TestFixtures.limit(id: "a", percent: 10),
            TestFixtures.limit(id: "b", percent: 50),
            TestFixtures.limit(id: "c", percent: 90),
        ])
        XCTAssertEqual(icon.size.width, 23)  // 3×5pt bars + 2×3pt gaps + 2pt margin
        XCTAssertEqual(icon.size.height, 18)
        XCTAssertFalse(icon.isTemplate)
    }

    func testIconAlwaysReservesThreeTracks() {
        XCTAssertEqual(StatusItemController.makeIcon(limits: []).size.width, 23)
    }

    func testIconGrowsWithExtraLimits() {
        let icon = StatusItemController.makeIcon(limits: (0..<4).map {
            TestFixtures.limit(id: "l\($0)", percent: 10)
        })
        XCTAssertEqual(icon.size.width, 31)  // 4 bars + 3 gaps + margin
    }

    func testBarFillColorFollowsSeverity() throws {
        let icon = StatusItemController.makeIcon(limits: [
            TestFixtures.limit(id: "red", percent: 100),
            TestFixtures.limit(id: "orange", percent: 70),
            TestFixtures.limit(id: "green", percent: 10),
        ])
        let raster = try XCTUnwrap(Raster(icon))

        // Bar i spans x = 1 + 8i ..< 6 + 8i; sample near each bar's center.
        let red = raster.pixel(x: 3, yFromBottom: 8)  // 100% fills the track
        XCTAssertGreaterThan(red.r, red.g)
        XCTAssertGreaterThan(red.r, red.b)

        let orange = raster.pixel(x: 11, yFromBottom: 3)
        XCTAssertGreaterThan(orange.r, orange.g)
        XCTAssertGreaterThan(orange.g, orange.b)

        let green = raster.pixel(x: 19, yFromBottom: 2)  // minimum 3pt nub
        XCTAssertGreaterThan(green.g, green.r)

        // Above a 10% fill only the faint track remains.
        let track = raster.pixel(x: 19, yFromBottom: 14)
        XCTAssertLessThan(track.a, 150)
    }

    func testEmptyLimitsDrawOnlyFaintTracks() throws {
        let raster = try XCTUnwrap(Raster(StatusItemController.makeIcon(limits: [])))
        XCTAssertLessThan(raster.pixel(x: 3, yFromBottom: 8).a, 150)
    }
}

final class DebugLogTests: XCTestCase {
    private var logURL: URL!
    private var originalURL: URL!

    override func setUp() {
        super.setUp()
        originalURL = DebugLog.fileURL
        logURL = TestFixtures.tempDirectory().appendingPathComponent("debug.log")
        DebugLog.fileURL = logURL
        UserDefaults.standard.removeObject(forKey: "debugLogging")
    }

    override func tearDown() {
        DebugLog.fileURL = originalURL
        UserDefaults.standard.removeObject(forKey: "debugLogging")
        try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testDisabledByDefault() {
        DebugLog.log("should not appear")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testWritesAndAppendsWhenEnabled() throws {
        UserDefaults.standard.set(true, forKey: "debugLogging")
        DebugLog.log("first entry")
        DebugLog.log("second entry")

        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("first entry"))
        XCTAssertTrue(text.contains("second entry"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }
}
