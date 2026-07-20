import Foundation

/// Claude Code support.
///
/// Status: identity and usage are NOT yet readable on this machine, and the app
/// says so rather than inventing numbers.
///
/// What was checked (2026-07-20):
///   • Keychain services `Claude Code-credentials`, `-ef2e7502`, `-f2877ae3`
///     all contain only an `mcpOAuth` object — MCP server tokens. None carry a
///     `claudeAiOauth` block, so there is no subscription token to read or swap.
///   • `~/.claude/.claude.json` holds only `userID` / `machineID` — no account,
///     plan, or email.
///   • Nothing under `~/.claude` records `anthropic-ratelimit-*` headers, so
///     there is no local usage trail equivalent to Codex's logs_2.sqlite.
///
/// The moment a `claudeAiOauth` entry does appear, `probe()` will find it and the
/// rest of the app treats Claude exactly like Codex.
enum ClaudeProvider {

    struct Probe {
        let foundOAuth: Bool
        let detail: String
    }

    /// Check for a file-based subscription credential. Deliberately never reads
    /// the keychain: every third-party keychain access pops a macOS password
    /// dialog, and the entries were verified to hold only MCP tokens anyway.
    static func probe() -> Probe {
        let fileURL = ProfileStore.activeCredentialPath(.claude)
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["claudeAiOauth"] != nil {
            return Probe(foundOAuth: true, detail: "OAuth credential found at ~/.claude/.credentials.json")
        }
        return Probe(
            foundOAuth: false,
            detail: "No file-based credential; run `claude` login in a terminal to create one")
    }

    /// Accounts we can describe today. Until a credential is readable this is a
    /// single honest placeholder rather than fabricated usage bars.
    static func accounts() -> [Account] {
        let probe = probe()
        guard probe.foundOAuth else {
            return [Account(
                provider: .claude,
                profileName: "not-detected",
                email: nil,
                plan: nil,
                isActive: false,
                windows: [],
                status: .noData(reason: probe.detail))]
        }
        // A credential exists but we have no usage source for it yet.
        return ProfileStore.listProfiles(.claude).map { name in
            Account(
                provider: .claude,
                profileName: name,
                email: nil,
                plan: nil,
                isActive: false,
                windows: [],
                status: .noData(reason: "credential found; usage source not wired up"))
        }
    }
}
