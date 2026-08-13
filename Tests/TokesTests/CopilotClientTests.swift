import XCTest

@testable import Tokes

/// Mapping of GitHub's copilot_internal/user entitlement body to a UsageLimit.
final class CopilotResponseMappingTests: XCTestCase {
    private func body(quota: String,
                      resetDate: String? = "\"2026-09-01\"",
                      resetDateUTC: String? = "\"2026-09-01T00:00:00.000Z\"") -> Data {
        var fields = ["\"quota_snapshots\": {\"premium_interactions\": \(quota)}"]
        if let resetDate { fields.append("\"quota_reset_date\": \(resetDate)") }
        if let resetDateUTC { fields.append("\"quota_reset_date_utc\": \(resetDateUTC)") }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    private let meteredQuota = """
        {"entitlement": 7000, "remaining": 6962, "credits_used": 37,
         "percent_remaining": 99.4, "unlimited": false, "overage_permitted": false}
        """

    func testMapsMeteredQuota() throws {
        let limit = try CopilotClient.limit(from: body(quota: meteredQuota))

        XCTAssertEqual(limit.id, "copilot_premium")
        XCTAssertEqual(limit.label, "Copilot Premium")
        XCTAssertEqual(limit.percent, 0.6, accuracy: 0.001)
        XCTAssertEqual(limit.provider, .copilot)
        XCTAssertFalse(limit.isSession)
        XCTAssertEqual(limit.detail, "37 of 7,000 credits used")
        XCTAssertEqual(limit.resetsAt, utcDate(2026, 9, 1))
    }

    func testPrefersPercentRemainingOverCreditsMath() throws {
        // 100 - 99.4 = 0.6, not credits_used/entitlement (≈0.53).
        let limit = try CopilotClient.limit(from: body(quota: meteredQuota))
        XCTAssertEqual(limit.percent, 0.6, accuracy: 0.001)
    }

    func testComputesPercentFromCreditsWhenPercentRemainingMissing() throws {
        let quota = "{\"entitlement\": 200, \"credits_used\": 50, \"unlimited\": false}"
        let limit = try CopilotClient.limit(from: body(quota: quota))
        XCTAssertEqual(limit.percent, 25, accuracy: 0.001)
        XCTAssertEqual(limit.detail, "50 of 200 credits used")
    }

    func testUnlimitedQuotaShowsZeroPercent() throws {
        let quota = "{\"entitlement\": 0, \"credits_used\": 0, \"percent_remaining\": 100, \"unlimited\": true}"
        let limit = try CopilotClient.limit(from: body(quota: quota))
        XCTAssertEqual(limit.percent, 0)
        XCTAssertEqual(limit.detail, "Unlimited plan")
    }

    func testFallsBackToDateOnlyReset() throws {
        let limit = try CopilotClient.limit(from: body(quota: meteredQuota, resetDateUTC: nil))
        XCTAssertEqual(limit.resetsAt, utcDate(2026, 9, 1))
    }

    func testNilResetWhenNoDateFields() throws {
        let limit = try CopilotClient.limit(from: body(quota: meteredQuota,
                                                       resetDate: nil, resetDateUTC: nil))
        XCTAssertNil(limit.resetsAt)
    }

    func testMissingQuotaSnapshotsThrowsDecode() {
        XCTAssertThrowsError(try CopilotClient.limit(from: Data("{}".utf8))) { error in
            XCTAssertEqual(error as? CopilotError,
                           .decode("no premium_interactions quota in response"))
        }
    }

    func testUnusableQuotaFieldsThrowsDecode() {
        let quota = "{\"unlimited\": false}"
        XCTAssertThrowsError(try CopilotClient.limit(from: body(quota: quota))) { error in
            XCTAssertEqual(error as? CopilotError,
                           .decode("no usable quota fields in response"))
        }
    }

    func testGarbageBodyThrowsDecode() {
        XCTAssertThrowsError(try CopilotClient.limit(from: Data("not json".utf8))) { error in
            guard case CopilotError.decode = error as! CopilotError else {
                return XCTFail("expected decode error, got \(error)")
            }
        }
    }

    func testErrorDescriptions() {
        XCTAssertTrue(CopilotError.unauthorized.errorDescription!.contains("GitHub token rejected"))
        XCTAssertEqual(CopilotError.http(503).errorDescription, "Copilot API returned HTTP 503.")
        XCTAssertTrue(CopilotError.decode("x").errorDescription!.contains("x"))
    }
}

/// HTTP layer of CopilotClient via MockURLProtocol — no network.
final class CopilotClientHTTPTests: XCTestCase {
    private var client: CopilotClient!

    override func setUp() {
        super.setUp()
        client = CopilotClient(session: mockSession())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func respond(status: Int, body: String,
                         capture: ((URLRequest) -> Void)? = nil) {
        MockURLProtocol.handler = { request in
            capture?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    private let validBody = """
        {"quota_reset_date_utc": "2026-09-01T00:00:00.000Z",
         "quota_snapshots": {"premium_interactions":
           {"entitlement": 7000, "credits_used": 37, "percent_remaining": 99.4, "unlimited": false}}}
        """

    func testSendsGitHubHeaders() async throws {
        var captured: URLRequest?
        respond(status: 200, body: validBody) { captured = $0 }

        _ = try await client.fetch(token: "test-token")

        XCTAssertEqual(captured?.url?.absoluteString, "https://api.github.com/copilot_internal/user")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "token test-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testMapsSuccessBody() async throws {
        respond(status: 200, body: validBody)
        let limit = try await client.fetch(token: "t")
        XCTAssertEqual(limit.percent, 0.6, accuracy: 0.001)
    }

    func test401ThrowsUnauthorized() async {
        respond(status: 401, body: "")
        do {
            _ = try await client.fetch(token: "t")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? CopilotError, .unauthorized)
        }
    }

    func test403ThrowsUnauthorized() async {
        respond(status: 403, body: "")
        do {
            _ = try await client.fetch(token: "t")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? CopilotError, .unauthorized)
        }
    }

    func test500ThrowsHTTP() async {
        respond(status: 500, body: "")
        do {
            _ = try await client.fetch(token: "t")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? CopilotError, .http(500))
        }
    }

    func testGarbage200ThrowsDecode() async {
        respond(status: 200, body: "<!doctype html>")
        do {
            _ = try await client.fetch(token: "t")
            XCTFail("expected throw")
        } catch {
            guard case CopilotError.decode = error as! CopilotError else {
                return XCTFail("expected decode error, got \(error)")
            }
        }
    }
}
