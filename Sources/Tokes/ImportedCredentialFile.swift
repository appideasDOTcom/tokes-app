import Foundation

/// Failures reading a user-imported credentials file.
enum ImportedFileError: LocalizedError, Equatable {
    case notImported(String)
    case unreadable(String)
    case unparsable(String)

    var errorDescription: String? {
        switch self {
        case .notImported(let what):
            return "No \(what) file imported. Choose one in Settings."
        case .unreadable(let path):
            return "Could not read the imported file (\(path)). Import it again in Settings."
        case .unparsable(let path):
            return "The imported file (\(path)) doesn't contain a usable token."
        }
    }
}

/// A credentials file the user picked in an open panel, remembered as a
/// security-scoped bookmark.
///
/// Why a bookmark rather than a path: under the sandbox, picking a file in the
/// powerbox grants access to *that* file for *this* launch. The bookmark is how
/// that grant is persisted, and re-reading through it on every poll is what lets
/// Tokes follow a token as the owning tool rotates it — which a one-shot copy of
/// the file's contents could not do.
///
/// Unsandboxed the same code runs unchanged; `.withSecurityScope` bookmarks are
/// created and resolved there too, so the direct and App Store builds exercise
/// one implementation rather than two.
final class ImportedCredentialFile {
    /// Bookmark plus the option set it was created with, so resolution matches.
    private struct Stored: Codable {
        let bookmark: Data
        let securityScoped: Bool
    }

    private let defaultsKey: String
    private let defaults: UserDefaults
    /// Human name used in error messages, e.g. "Claude Code credentials".
    private let describing: String

    /// Test seam: how a bookmark is created. Nothing in the app replaces it.
    /// The scoped-versus-plain distinction is the whole of the refresh rule
    /// below and cannot be provoked otherwise — an unsandboxed test process
    /// gets a security-scoped bookmark for any file it can read, so the
    /// fallback arm is unreachable without this.
    var makeBookmark: (URL, URL.BookmarkCreationOptions) throws -> Data = {
        try $0.bookmarkData(options: $1, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Test seam: opening the security scope, which returns false when the
    /// grant is gone (the user moved the file to a place the extension does not
    /// cover, or the extension was revoked). Real for the app, forceable here.
    var beginAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }

    init(defaultsKey: String, describing: String, defaults: UserDefaults = .standard) {
        self.defaultsKey = defaultsKey
        self.describing = describing
        self.defaults = defaults
    }

    private var stored: Stored? {
        get {
            guard let data = defaults.data(forKey: defaultsKey) else { return nil }
            return try? PropertyListDecoder().decode(Stored.self, from: data)
        }
        set {
            guard let newValue, let data = try? PropertyListEncoder().encode(newValue) else {
                defaults.removeObject(forKey: defaultsKey)
                return
            }
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// Whether a file has been imported.
    var hasImport: Bool { stored != nil }

    /// The imported file's path for display, or nil when nothing is imported.
    /// Resolving may fail (file moved or deleted); that surfaces as nil here and
    /// as a thrown error from `read()`.
    var displayPath: String? {
        guard let resolved = try? resolve() else { return nil }
        defer { resolved.endAccess() }
        return resolved.url.path
    }

    /// Remembers `url` as the imported file. Call while any security scope
    /// obtained from the open panel is still open.
    func store(_ url: URL) throws {
        try store(url, requireSecurityScope: false)
    }

    /// The shared body of a first import and a stale-bookmark refresh.
    ///
    /// `requireSecurityScope` is the difference between them, and it matters.
    /// A *first* import may legitimately land on a plain bookmark — some volumes
    /// and some unsandboxed configurations refuse security-scoped ones, and a
    /// plain bookmark still works there. A *refresh* may not: silently replacing
    /// a security-scoped grant with a plain bookmark downgrades access that
    /// survived relaunch into access that does not, and the failure surfaces
    /// much later as an unreadable file with nothing to connect it to. When the
    /// scoped re-save fails the error propagates instead, and `resolve()`'s
    /// `try?` leaves the existing bookmark in place — stale but still scoped,
    /// which is strictly better than fresh but unscoped.
    private func store(_ url: URL, requireSecurityScope: Bool) throws {
        do {
            stored = Stored(bookmark: try makeBookmark(url, .withSecurityScope),
                            securityScoped: true)
        } catch {
            if requireSecurityScope { throw error }
            stored = Stored(bookmark: try makeBookmark(url, []), securityScoped: false)
        }
    }

    /// Forgets the imported file.
    func clear() {
        stored = nil
    }

    /// A resolved URL together with the scope that must be closed after use.
    struct Access {
        let url: URL
        fileprivate let scoped: Bool

        func endAccess() {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Resolves the bookmark and opens its security scope. The caller must
    /// call `endAccess()` on the result.
    func resolve() throws -> Access {
        guard let stored else { throw ImportedFileError.notImported(describing) }
        var isStale = false
        let options: URL.BookmarkResolutionOptions = stored.securityScoped ? .withSecurityScope : []
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: stored.bookmark,
                          options: options,
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        } catch {
            throw ImportedFileError.unreadable(describing)
        }
        let opened = stored.securityScoped ? beginAccess(url) : true
        guard opened else { throw ImportedFileError.unreadable(url.path) }
        if isStale {
            // Refresh the bookmark while we still hold the scope, so the grant
            // survives the file being replaced (rotations rewrite atomically).
            // Never downgrade a scoped grant to a plain one while doing it.
            try? store(url, requireSecurityScope: stored.securityScoped)
        }
        return Access(url: url, scoped: stored.securityScoped)
    }

    /// Reads the imported file's current contents.
    func read() throws -> Data {
        let access = try resolve()
        defer { access.endAccess() }
        guard let data = try? Data(contentsOf: access.url) else {
            throw ImportedFileError.unreadable(access.url.path)
        }
        return data
    }
}

/// The real home directory, which the sandbox hides behind a container redirect.
///
/// Used only to point the open panel somewhere useful — the panel runs out of
/// process in the powerbox, so it can show a directory this process cannot read.
enum RealHome {
    static var url: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

#if canImport(AppKit)
    import AppKit

    extension ImportedCredentialFile {
        /// Runs an open panel and remembers whatever the user picks.
        ///
        /// The panel is the whole point: it is macOS' own consent mechanism, and
        /// the sandbox extension it hands back is what makes reading this file
        /// legitimate rather than a container escape. `showsHiddenFiles` is on
        /// because every file worth importing lives in a dot-directory.
        ///
        /// Returns the chosen URL, or nil if the user cancelled. Storing it is
        /// the caller's job (`SettingsView.importOutcome`) — everything after
        /// the modal returns is then reachable from a test, which the modal
        /// itself never will be.
        @MainActor
        func runImportPanel(title: String, message: String, startingAt directory: URL?) -> URL? {
            let panel = NSOpenPanel()
            panel.title = title
            panel.message = message
            panel.prompt = "Import"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.treatsFilePackagesAsDirectories = true
            if let directory { panel.directoryURL = directory }
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }
#endif
