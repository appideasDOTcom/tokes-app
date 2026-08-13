import XCTest

@testable import Tokes

final class APIDateTests: XCTestCase {
    func testParsesFractionalSeconds() throws {
        let date = try XCTUnwrap(APIDate.parse("2026-08-13T12:34:56.789Z"))
        XCTAssertEqual(date.timeIntervalSince1970,
                       utcDate(2026, 8, 13, 12, 34, 56).timeIntervalSince1970 + 0.789,
                       accuracy: 0.001)
    }

    func testParsesPlainInternetDateTime() {
        XCTAssertEqual(APIDate.parse("2026-08-13T12:34:56Z"), utcDate(2026, 8, 13, 12, 34, 56))
    }

    func testParsesMicrosecondPrecision() throws {
        let date = try XCTUnwrap(APIDate.parse("2026-08-13T12:34:56.789123Z"))
        XCTAssertEqual(date.timeIntervalSince1970,
                       utcDate(2026, 8, 13, 12, 34, 56).timeIntervalSince1970 + 0.789,
                       accuracy: 0.01)
    }

    func testParsesTimezoneOffsets() {
        XCTAssertEqual(APIDate.parse("2026-08-13T14:34:56+02:00"), utcDate(2026, 8, 13, 12, 34, 56))
    }

    func testRejectsNilAndGarbage() {
        XCTAssertNil(APIDate.parse(nil))
        XCTAssertNil(APIDate.parse(""))
        XCTAssertNil(APIDate.parse("not a date"))
    }
}

final class UsageResponseMappingTests: XCTestCase {
    private func snapshot(_ json: String) throws -> UsageSnapshot {
        try UsageClient.snapshot(from: Data(json.utf8))
    }

    func testMapsModernLimitsSortedAndLabeled() throws {
        let snap = try snapshot("""
            {"limits":[
              {"kind":"weekly_scoped","percent":19,"severity":"warning","resets_at":"2026-08-20T07:00:00Z",
               "scope":{"model":{"display_name":"Fable"}}},
              {"kind":"weekly_all","percent":18},
              {"kind":"session","percent":24,"severity":"normal","resets_at":"2026-08-13T17:00:00Z"},
              {"kind":"mystery","percent":5}
            ]}
            """)
        XCTAssertEqual(snap.limits.map(\.id), ["session", "weekly_all", "weekly_scoped:Fable"])
        XCTAssertEqual(snap.limits.map(\.label), ["Session (5 hr)", "Weekly (7 day)", "Weekly Fable"])
        XCTAssertEqual(snap.limits.map(\.percent), [24, 18, 19])
        XCTAssertEqual(snap.limits.map(\.isSession), [true, false, false])
        XCTAssertEqual(snap.limits[0].resetsAt, utcDate(2026, 8, 13, 17))
        XCTAssertNil(snap.limits[1].resetsAt)
        XCTAssertEqual(snap.limits[1].severity, "normal")
        XCTAssertEqual(snap.limits[2].severity, "warning")
    }

    func testScopedLimitWithoutModelNameFallsBack() throws {
        let snap = try snapshot(#"{"limits":[{"kind":"weekly_scoped","percent":7}]}"#)
        XCTAssertEqual(snap.limits[0].id, "weekly_scoped:Model")
        XCTAssertEqual(snap.limits[0].label, "Weekly Model")
    }

    func testEntriesMissingPercentAreSkipped() throws {
        let snap = try snapshot(#"{"limits":[{"kind":"session"},{"kind":"weekly_all","percent":3}]}"#)
        XCTAssertEqual(snap.limits.map(\.id), ["weekly_all"])
    }

    func testLegacyFlatFieldsUsedWhenLimitsAbsent() throws {
        let snap = try snapshot("""
            {"five_hour":{"utilization":42,"resets_at":"2026-08-13T17:00:00Z"},
             "seven_day":{"utilization":7}}
            """)
        XCTAssertEqual(snap.limits.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(snap.limits.map(\.percent), [42, 7])
        XCTAssertEqual(snap.limits[0].resetsAt, utcDate(2026, 8, 13, 17))
    }

    func testModernLimitsTakePriorityOverLegacy() throws {
        let snap = try snapshot("""
            {"limits":[{"kind":"session","percent":1}],
             "five_hour":{"utilization":99}}
            """)
        XCTAssertEqual(snap.limits.map(\.percent), [1])
    }

    func testEmptyResponseThrowsDecodeError() {
        XCTAssertThrowsError(try UsageClient.snapshot(from: Data("{}".utf8))) { error in
            XCTAssertEqual(error as? UsageError, .decode("no limits in response"))
        }
    }

    func testMalformedJSONThrowsDecodeError() {
        XCTAssertThrowsError(try UsageClient.snapshot(from: Data("not json".utf8))) { error in
            guard let usage = error as? UsageError, case .decode = usage else {
                return XCTFail("expected decode error, got \(error)")
            }
        }
    }
}

final class UsageClientHTTPTests: XCTestCase {
    private let validBody = Data(#"{"limits":[{"kind":"session","percent":24}]}"#.utf8)

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func respond(status: Int, body: Data? = nil) {
        let payload = body ?? validBody
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
             payload)
        }
    }

    func testFetchSendsOAuthHeadersAndParsesBody() async throws {
        var captured: URLRequest?
        MockURLProtocol.handler = { [validBody] request in
            captured = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    validBody)
        }
        let snapshot = try await UsageClient(session: mockSession()).fetch(token: "test-token")
        XCTAssertEqual(snapshot.limits.map(\.id), ["session"])
        XCTAssertEqual(snapshot.limits.map(\.percent), [24])
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    private func assertFetchThrows(_ expected: UsageError, status: Int,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        respond(status: status)
        do {
            _ = try await UsageClient(session: mockSession()).fetch(token: "t")
            XCTFail("expected error for HTTP \(status)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? UsageError, expected, file: file, line: line)
        }
    }

    func testUnauthorizedStatuses() async {
        await assertFetchThrows(.unauthorized, status: 401)
        await assertFetchThrows(.unauthorized, status: 403)
    }

    func testRateLimitAndServerErrors() async {
        await assertFetchThrows(.rateLimited(retryAfter: nil), status: 429)
        await assertFetchThrows(.http(500), status: 500)
    }

    func testRateLimitParsesRetryAfterHeader() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                             headerFields: ["Retry-After": "30"])!,
             Data())
        }
        do {
            _ = try await UsageClient(session: mockSession()).fetch(token: "t")
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error as? UsageError, .rateLimited(retryAfter: 30))
        }
    }

    func testMalformedBodyOn200ThrowsDecode() async {
        respond(status: 200, body: Data("garbage".utf8))
        do {
            _ = try await UsageClient(session: mockSession()).fetch(token: "t")
            XCTFail("expected error")
        } catch {
            guard let usage = error as? UsageError, case .decode = usage else {
                return XCTFail("expected decode error, got \(error)")
            }
        }
    }

    func testErrorDescriptionsAreUserFacing() {
        XCTAssertEqual(UsageError.http(500).errorDescription, "Usage API returned HTTP 500.")
        XCTAssertNotNil(UsageError.unauthorized.errorDescription)
        XCTAssertNotNil(UsageError.decode("x").errorDescription)
    }
}
