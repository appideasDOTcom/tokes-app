import XCTest

@testable import Tokes

final class HistoryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = TestFixtures.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var fileURL: URL { dir.appendingPathComponent("history.jsonl") }

    private func writeLines(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func line(t: Double, session: Double) -> String {
        #"{"t":\#(t),"v":{"session":\#(session)}}"#
    }

    private func fileLineCount() throws -> Int {
        try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n").filter { !$0.isEmpty }.count
    }

    func testStartsEmptyWithoutFile() {
        XCTAssertTrue(HistoryStore(directory: dir).samples.isEmpty)
    }

    func testAppendPersistsAcrossReload() {
        let t = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        HistoryStore(directory: dir).append(UsageSample(t: t, v: ["session": 24, "weekly_all": 18]))

        let reloaded = HistoryStore(directory: dir)
        XCTAssertEqual(reloaded.samples.count, 1)
        XCTAssertEqual(reloaded.samples[0].t.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(reloaded.samples[0].v, ["session": 24, "weekly_all": 18])
    }

    func testAppendWritesOneLinePerSample() throws {
        let store = HistoryStore(directory: dir)
        store.append(UsageSample(t: Date(), v: ["session": 1]))
        store.append(UsageSample(t: Date(), v: ["session": 2]))
        XCTAssertEqual(store.samples.count, 2)
        XCTAssertEqual(try fileLineCount(), 2)
    }

    func testLoadSortsByTimestamp() throws {
        let now = Date().timeIntervalSince1970
        try writeLines([line(t: now - 60, session: 2), line(t: now - 3600, session: 1)])
        let store = HistoryStore(directory: dir)
        XCTAssertEqual(store.samples.map { $0.v["session"] }, [1, 2])
    }

    func testLoadPrunesOldSamplesAndCompactsFile() throws {
        let now = Date().timeIntervalSince1970
        try writeLines([
            line(t: now - 9 * 24 * 3600, session: 1),  // beyond 8-day retention
            line(t: now - 3600, session: 2),
        ])
        let store = HistoryStore(directory: dir)
        XCTAssertEqual(store.samples.map { $0.v["session"] }, [2])
        XCTAssertEqual(try fileLineCount(), 1)
    }

    func testCorruptLinesAreSkipped() throws {
        let now = Date().timeIntervalSince1970
        try writeLines(["garbage not json", line(t: now - 60, session: 3)])
        let store = HistoryStore(directory: dir)
        XCTAssertEqual(store.samples.map { $0.v["session"] }, [3])
        XCTAssertEqual(try fileLineCount(), 1)  // rewrite dropped the corrupt line
    }

    func testCreatesDirectoryIfMissing() {
        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        HistoryStore(directory: nested).append(UsageSample(t: Date(), v: ["session": 1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("history.jsonl").path))
    }
}
