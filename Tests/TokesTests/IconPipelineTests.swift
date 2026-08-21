import Foundation
import XCTest

/// Guards the app icon build pipeline. The icon ships as an Icon Composer
/// package that `scripts/build.sh` compiles with `actool`; the failure modes
/// here are all silent ones — a bundle that builds and signs cleanly while
/// carrying no icon at all. See the `build.app_icon` contract and CLAUDE.md.
final class IconPipelineTests: XCTestCase {
    /// Repo root, derived from this file's location rather than the cwd.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TokesTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static var iconPackage: URL {
        repoRoot.appendingPathComponent("packaging/icon/Tokes.icon")
    }

    // MARK: - Source package

    func testIconPackageHasExpectedContents() {
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: Self.iconPackage.path),
                      "packaging/icon/Tokes.icon is missing — build.sh cannot produce an icon")
        XCTAssertTrue(fm.fileExists(atPath: Self.iconPackage.appendingPathComponent("icon.json").path))
        XCTAssertTrue(fm.fileExists(atPath: Self.iconPackage.appendingPathComponent("Assets/ring.svg").path))
    }

    /// An .appiconset next to a .icon under the same --app-icon name is ignored
    /// *silently* by actool: the build still succeeds and the output is
    /// byte-identical, so a well-meaning addition looks like it worked.
    func testNoAssetCatalogShadowsTheIconPackage() throws {
        let iconDir = Self.repoRoot.appendingPathComponent("packaging/icon")
        let contents = try FileManager.default.subpathsOfDirectory(atPath: iconDir.path)
        let shadowing = contents.filter { $0.hasSuffix(".appiconset") || $0.hasSuffix(".xcassets") }
        XCTAssertTrue(shadowing.isEmpty,
                      "actool silently ignores these when a .icon is present: \(shadowing)")
    }

    /// The ring's meaning is carried by its gaps, which close at 16px if the
    /// wall is thinned. The designer's contract fixes the floor at 5.6 units on
    /// a 32-unit grid; their measure_marks.py remains authoritative for geometry
    /// generally, this is only a tripwire for an incoming regression.
    func testRingWallMeetsContractMinimum() throws {
        let svg = try String(contentsOf: Self.iconPackage.appendingPathComponent("Assets/ring.svg"),
                             encoding: .utf8)
        // Arc commands look like: A14.0000,14.0000 / A8.4000,8.4000
        let pattern = try NSRegularExpression(pattern: "A([0-9]+\\.[0-9]+),")
        let radii = pattern.matches(in: svg, range: NSRange(svg.startIndex..., in: svg))
            .compactMap { Range($0.range(at: 1), in: svg).flatMap { Double(svg[$0]) } }
        XCTAssertFalse(radii.isEmpty, "no arc radii found in ring.svg")
        let wall = radii.max()! - radii.min()!
        // tolerance folded into the bound: the floor is exact, the parse is float
        XCTAssertGreaterThanOrEqual(wall, 5.6 - 0.001,
                                    "ring wall \(wall) is below the 5.6-unit contract floor")
    }

    // MARK: - Build script

    /// actool runs as a persistent XPC service that can carry a stale working
    /// directory between invocations, so relative paths resolve against some
    /// earlier directory. Absolute paths are the fix; this guards the fix.
    func testBuildScriptPassesAbsolutePathsToActool() throws {
        let script = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/build.sh"),
                                encoding: .utf8)
        XCTAssertTrue(script.contains("xcrun actool \"$ROOT/packaging/icon/Tokes.icon\""),
                      "actool's input path must stay absolute")
        XCTAssertTrue(script.contains("--compile \"$ROOT/$APP/Contents/Resources\""),
                      "actool's output path must stay absolute")
    }

    // MARK: - Compilation

    func testActoolCompilesPackageIntoBothShippingForms() throws {
        guard let actool = Self.findActool() else {
            throw XCTSkip("actool unavailable — Xcode command line tools not installed")
        }
        let out = TestFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: out) }
        let partialPlist = out.appendingPathComponent("partial.plist")

        let result = Self.run(actool, [
            Self.iconPackage.path,
            "--compile", out.path,
            "--app-icon", "Tokes",
            "--include-all-app-icons",
            "--output-partial-info-plist", partialPlist.path,
            "--platform", "macosx",
            "--target-device", "mac",
            "--minimum-deployment-target", Self.minimumDeploymentTarget(),
            "--output-format", "human-readable-text",
            "--errors", "--warnings",
        ])
        XCTAssertEqual(result.status, 0, "actool failed:\n\(result.output)")

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("Assets.car").path),
                      "no Assets.car — the macOS 26 layered rendition is missing")
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("Tokes.icns").path),
                      "no Tokes.icns — the legacy rendition for macOS 14/15 is missing")

        // Without both keys the bundle builds and signs cleanly but shows no icon.
        let plist = try XCTUnwrap(NSDictionary(contentsOf: partialPlist) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "Tokes")
        XCTAssertEqual(plist["CFBundleIconName"] as? String, "Tokes")

        // 16/32/128/256 is the complete correct set — Apple's own system apps
        // ship exactly these four and rely on Assets.car above 256.
        let icns = try Data(contentsOf: out.appendingPathComponent("Tokes.icns"))
        XCTAssertEqual(Self.icnsTypeCodes(icns), ["ic04", "ic07", "ic11", "ic13"])
    }

    // MARK: - Helpers

    private static func findActool() -> URL? {
        let result = run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["--find", "actool"])
        guard result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Mirrors build.sh: the deployment target comes from Info.plist so the
    /// plist stays the single source of truth.
    private static func minimumDeploymentTarget() -> String {
        let plist = NSDictionary(contentsOf: repoRoot.appendingPathComponent("scripts/Info.plist"))
        return (plist?["LSMinimumSystemVersion"] as? String) ?? "14.0"
    }

    private static func run(_ tool: URL, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Walks the .icns table of contents and returns its four-char type codes.
    private static func icnsTypeCodes(_ data: Data) -> [String] {
        guard data.count > 8, data.prefix(4) == Data("icns".utf8) else { return [] }
        let total = Int(data[4...7].reduce(0) { $0 << 8 | UInt32($1) })
        var offset = 8
        var codes: [String] = []
        while offset + 8 <= min(total, data.count) {
            let code = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let length = Int(data[(offset + 4)...(offset + 7)].reduce(0) { $0 << 8 | UInt32($1) })
            guard length >= 8 else { break }
            codes.append(code)
            offset += length
        }
        return codes.sorted()
    }
}
