import AppKit
import Foundation
import XCTest

@testable import Tokes

/// Serves canned HTTP responses and records requests for URLSession tests.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// URLSession that routes every request through MockURLProtocol.
func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Builders for common model values and per-test scratch space.
enum TestFixtures {
    static func limit(id: String = "session", label: String? = nil, percent: Double = 10,
                      severity: String = "normal", resetsAt: Date? = nil,
                      isSession: Bool = false) -> UsageLimit {
        UsageLimit(id: id, label: label ?? id, percent: percent, severity: severity,
                   resetsAt: resetsAt, isSession: isSession)
    }

    static func snapshot(percents: [String: Double], fetchedAt: Date = Date()) -> UsageSnapshot {
        let limits = percents.sorted { $0.key < $1.key }.map {
            limit(id: $0.key, percent: $0.value, isSession: $0.key == "session")
        }
        return UsageSnapshot(limits: limits, fetchedAt: fetchedAt)
    }

    static func tempDirectory(_ function: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokesTests-\(function)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// UTC date builder for deterministic date assertions.
func utcDate(_ year: Int, _ month: Int, _ day: Int,
             _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: components)!
}

/// Scripted UsageFetching stand-in: returns queued results and counts calls.
final class MockUsageClient: UsageFetching {
    var results: [Result<UsageSnapshot, Error>] = []
    private(set) var fetchCount = 0
    private(set) var tokens: [String] = []
    var onFetch: (() -> Void)?
    var gate: (() async -> Void)?

    func fetch(token: String) async throws -> UsageSnapshot {
        fetchCount += 1
        tokens.append(token)
        onFetch?()
        if let gate { await gate() }
        guard !results.isEmpty else { throw UsageError.http(599) }
        return try results.removeFirst().get()
    }
}

/// TokenProviding stand-in with a fixed token or scripted failure.
final class MockCredentials: TokenProviding {
    var token = "mock-token"
    var error: Error?
    private(set) var invalidateCount = 0

    func accessToken() throws -> String {
        if let error { throw error }
        return token
    }

    func invalidate() { invalidateCount += 1 }
}

/// Rasterizes an NSImage and samples RGBA pixels (bottom-left origin, point coordinates).
struct Raster {
    private let data: [UInt8]
    private let width: Int
    private let height: Int
    private let scale: Int

    init?(_ image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        width = cg.width
        height = cg.height
        scale = max(1, Int((CGFloat(cg.width) / image.size.width).rounded()))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: cg.width, height: cg.height,
                                      bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        guard drawn else { return nil }
        data = buffer
    }

    func pixel(x: Int, yFromBottom: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let px = x * scale
        let py = (height - 1) - yFromBottom * scale
        let i = (py * width + px) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
}
