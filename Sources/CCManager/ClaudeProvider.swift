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

    static let keychainServices = [
        "Claude Code-credentials",
        "Claude Code-credentials-ef2e7502",
        "Claude Code-credentials-f2877ae3",
    ]

    struct Probe {
        let foundOAuth: Bool
        let detail: String
    }

    /// Look for a real subscription credential in the keychain.
    static func probe() -> Probe {
        for service in keychainServices {
            guard let json = readKeychain(service: service),
                  let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
            else { continue }
            if obj["claudeAiOauth"] != nil {
                return Probe(foundOAuth: true, detail: "OAuth credential found in \(service)")
            }
        }
        // Also honour the file-based credential path some installs use.
        let fileURL = ProfileStore.activeCredentialPath(.claude)
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["claudeAiOauth"] != nil {
            return Probe(foundOAuth: true, detail: "OAuth credential found at ~/.claude/.credentials.json")
        }
        return Probe(
            foundOAuth: false,
            detail: "No subscription token found — only MCP tokens are present")
    }

    /// Read a generic password entry from the login keychain.
    private static func readKeychain(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
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
