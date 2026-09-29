import Foundation

/// The user-run export that bridges Claude Code's keychain-only credential
/// storage to a file Tokes can import.
///
/// macOS Claude Code keeps its sign-in *only* in the keychain (item
/// "Claude Code-credentials") — there is no credentials file and no supported
/// way to make it write one — and Anthropic permits no third-party OAuth for
/// subscription accounts. So the workable shape is: the *user* exports their
/// own credentials with their own terminal, and Tokes imports the resulting
/// file through the open panel like any other. The user is the actor at every
/// step and Tokes never reads another app's credential store, which is what
/// keeps the App Store build inside Guideline 2.5.2.
///
/// Everything Settings shows the user comes from here, so the wording in the
/// UI, the command the hook runs, and the path the import panel expects can
/// never drift apart.
enum ClaudeCodeExport {
    /// Where the export lands: next to Claude Code's own files, so the import
    /// panel — which opens in ~/.claude — shows it immediately.
    static let exportedFileName = "tokes-credentials.json"
    static let exportedFilePath = "~/.claude/tokes-credentials.json"

    /// The one-time export the user runs in Terminal. `security` prompts for
    /// nothing when the caller owns the login keychain; `chmod 600` because
    /// the file holds a live OAuth token.
    static let exportCommand = "security find-generic-password -s \"Claude Code-credentials\" -w > "
        + "~/.claude/tokes-credentials.json && chmod 600 ~/.claude/tokes-credentials.json"

    /// What the optional Claude Code hooks run: the same export,
    /// but it only touches the file when the keychain read *succeeds* — a
    /// plain `>` redirect would truncate a working export to zero bytes the
    /// moment the user is signed out, replacing "token expired" with a
    /// mystifying "file doesn't contain a usable token". `umask 077` so a
    /// hook-created file is owner-only even when the user skipped the export
    /// step (a redirect into an *existing* file keeps its permissions, but a
    /// fresh creation would land at 644). Ends in `true` so a signed-out
    /// session never reports a failing hook.
    static let hookCommand = "umask 077; creds=$(security find-generic-password "
        + "-s \"Claude Code-credentials\" -w 2>/dev/null) && "
        + "printf '%s\\n' \"$creds\" > ~/.claude/tokes-credentials.json; true"

    /// The snippet the user merges into the "hooks" section of
    /// ~/.claude/settings.json, so the file Tokes watches refreshes itself.
    /// Generated rather than hand-written so the JSON escaping of
    /// `hookCommand`'s quotes can't be wrong.
    ///
    /// **`Stop` is the event that matters; `SessionStart` alone is a trap.**
    /// Claude Code refreshes an expired token only *during* an API request,
    /// and both `SessionStart` and `UserPromptSubmit` fire *before* the first
    /// one — so after an overnight expiry they export the dead token and the
    /// file stays stale until some later prompt (measured 2026-09-28: a
    /// restart of Tokes after a fresh session still read `importedExpired`).
    /// `Stop` fires after each reply, when the keychain already holds the
    /// refreshed token. `SessionStart` stays for the case where another
    /// session has already refreshed it, and so a user who merged the old
    /// snippet sees the same entry here.
    static var hookSnippet: String {
        let export: [[String: Any]] = [["type": "command", "command": hookCommand]]
        let object: [String: Any] = [
            "hooks": [
                "SessionStart": [["matcher": "*", "hooks": export]],
                "Stop": [["hooks": export]],
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let json = String(data: data, encoding: .utf8)
        else { return "" }  // unreachable: the object is a fixed literal
        return json
    }
}
