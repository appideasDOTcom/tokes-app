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
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            stored = Stored(bookmark: bookmark, securityScoped: true)
        } catch {
            // Some volumes (and some unsandboxed configurations) refuse
            // security-scoped bookmarks; a plain one still works there.
            let bookmark = try url.bookmarkData(options: [],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            stored = Stored(bookmark: bookmark, securityScoped: false)
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
        let opened = stored.securityScoped ? url.startAccessingSecurityScopedResource() : true
        guard opened else { throw ImportedFileError.unreadable(url.path) }
        if isStale {
            // Refresh the bookmark while we still hold the scope, so the grant
            // survives the file being replaced (rotations rewrite atomically).
            try? store(url)
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
        /// Returns the chosen path, or nil if the user cancelled.
        @MainActor
        func runImportPanel(title: String, message: String, startingAt directory: URL?) throws -> String? {
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
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            try store(url)
            return url.path
        }
    }
#endif
