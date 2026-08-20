import Foundation
import Security

/// Which channel this build targets. Fixed at compile time by the
/// `TOKES_APP_STORE` define (`scripts/build.sh --app-store`).
///
/// This is deliberately a *compile-time* switch rather than a runtime one: the
/// App Store binary must not merely decline to read other apps' credential
/// stores, it must not contain the code that does. Everything gated on
/// `Capabilities` below is `#if`-excluded from that build, and
/// `scripts/verify-appstore.sh` greps the linked binary to prove it.
enum Distribution: String {
    /// Notarized Developer ID build — Homebrew cask and direct download. Unsandboxed.
    case direct
    /// Mac App Store build. Sandboxed, and held to App Review Guideline 2.5.2.
    case appStore

    static let current: Distribution = {
        #if TOKES_APP_STORE
            .appStore
        #else
            .direct
        #endif
    }()

    var displayName: String {
        switch self {
        case .direct: return "Direct"
        case .appStore: return "App Store"
        }
    }
}

/// What this build is permitted to do.
///
/// The limits here are drawn from App Review Guideline 2.5.2 — "Apps should be
/// self-contained in their bundles, and may not read or write data outside the
/// designated container area, nor may they download, install, or execute code
/// which introduces or changes features or functionality of the app" — *not*
/// from what the sandbox kernel happens to stop. Those two are not the same
/// set, and the difference was measured, not assumed: under a real sandboxed
/// build, reads of `~/.claude/.credentials.json` and
/// `~/.config/github-copilot/apps.json` are denied (errno 257), but spawning
/// `/usr/bin/security` and `SecItemCopyMatching` against Claude Code's own
/// keychain item both *succeed*. Tokes declines the latter two anyway: they
/// read data outside the container, which is what the guideline forbids.
///
/// A user-selected file is different in kind. When someone picks a file in an
/// open panel, macOS extends the container to include it — that is the
/// powerbox's entire purpose — so `.importedFile` is available in both builds.
enum Capabilities {
    /// May read credential stores that belong to other applications: Claude
    /// Code's credentials file and keychain item, Copilot's plugin config.
    static func canReadForeignCredentialStores(_ distribution: Distribution = .current) -> Bool {
        distribution == .direct
    }

    /// May launch helper executables (`/usr/bin/security`, `gh`) to obtain
    /// credentials. Guideline 2.5.2's second clause, and the data they return
    /// lives outside the container regardless.
    static func canRunHelperTools(_ distribution: Distribution = .current) -> Bool {
        distribution == .direct
    }

    /// Where `DebugLog` writes. `/tmp` is unwritable under the sandbox, so the
    /// App Store build logs inside its container instead.
    static func debugLogURL(_ distribution: Distribution = .current) -> URL {
        switch distribution {
        case .direct:
            return URL(fileURLWithPath: "/tmp/tokes-debug.log")
        case .appStore:
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tokes-debug.log")
        }
    }
}

/// Checks the running process against what the build claims, so a mis-signed
/// artifact is loud rather than silently non-compliant (an App Store build that
/// lost its entitlements) or silently broken (a direct build that gained them).
enum SandboxAudit {
    /// Whether the running process actually carries `com.apple.security.app-sandbox`.
    ///
    /// Reads the entitlement off our own code signature rather than inferring it
    /// from the container path, so an unsigned or differently-signed build
    /// answers honestly.
    static var isSandboxed: Bool {
        if let entitled = sandboxEntitlement { return entitled }
        // No readable signature: fall back to the container redirect, which the
        // sandbox applies to $HOME.
        return NSHomeDirectory().contains("/Library/Containers/")
    }

    private static var sandboxEntitlement: Bool? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict["entitlements-dict"] as? [String: Any]
        else { return nil }
        return entitlements["com.apple.security.app-sandbox"] as? Bool
    }

    /// True when the compiled flavor matches how the process is actually running.
    static var flavorMatchesRuntime: Bool {
        mismatch(distribution: .current, sandboxed: isSandboxed) == nil
    }

    /// A description of the mismatch for the running process, or nil when the
    /// build is consistent.
    static func mismatchDescription() -> String? {
        mismatch(distribution: .current, sandboxed: isSandboxed)
    }

    /// Pure form of the check, so every combination is testable rather than only
    /// the one this process happens to be in.
    static func mismatch(distribution: Distribution, sandboxed: Bool) -> String? {
        switch (distribution, sandboxed) {
        case (.appStore, true), (.direct, false):
            return nil
        case (.appStore, false):
            return "App Store build is running without the app-sandbox entitlement — "
                + "the bundle was signed without packaging/appstore/Tokes.entitlements."
        case (.direct, true):
            return "Direct build is running sandboxed — its automatic credential "
                + "sources will fail; build with --app-store for sandboxed signing."
        }
    }
}
