import Foundation

/// Prints exactly what the app can and cannot read, so credential and usage
/// detection can be verified from the terminal.
enum Diagnostics {
    static func run() {
        print("=== AI Meter diagnostics ===\n")

        print("[Codex] active credential: \(ProfileStore.activeCredentialPath(.codex).path())")
        if let id = CodexProvider.identity(at: ProfileStore.activeCredentialPath(.codex)) {
            print("  email:      \(id.email ?? "—")")
            print("  plan:       \(id.plan ?? "—")")
            print("  account_id: \(id.accountID)")
        } else {
            print("  no readable Codex credential")
        }

        print("\n[Codex] usage from \(CodexProvider.logsDB.lastPathComponent):")
        if let snap = CodexProvider.latestSnapshot() {
            print("  captured: \(snap.capturedAt)")
            print("  plan:     \(snap.plan ?? "—")")
            for w in snap.windows {
                print(String(format: "  %-8@ %5.1f%% used, %d min window, resets in %@",
                             w.label as NSString, w.usedPercent, w.windowMinutes,
                             w.resetsInDescription as NSString))
            }
        } else {
            print("  no rate-limit headers found in recent logs")
        }

        print("\n[Codex] saved profiles: \(ProfileStore.listProfiles(.codex))")
        print("  active profile: \(ProfileStore.activeProfileName(.codex) ?? "none imported")")

        let probe = ClaudeProvider.probe()
        print("\n[Claude] oauth credential found: \(probe.foundOAuth)")
        print("  \(probe.detail)")
        if let id = ClaudeProvider.identity() {
            print("  email: \(id.email ?? "—")  plan: \(id.plan ?? "—")")
        }
        print("  profiles: \(ClaudeProvider.listProfiles())")

        let w = TokenStats.collectWindows()
        print("\n[Tokens today] in: \(TokenStats.formatCount(w.today.inputTokens))"
              + "  out: \(TokenStats.formatCount(w.today.outputTokens))"
              + "  cacheRead: \(TokenStats.formatCount(w.today.cacheReadTokens))"
              + "  ≈\(TokenStats.formatDollars(w.today.apiEquivalentDollars)) API-equivalent")
        print("[Tokens 7d]    in: \(TokenStats.formatCount(w.week.inputTokens))"
              + "  out: \(TokenStats.formatCount(w.week.outputTokens))"
              + "  ≈\(TokenStats.formatDollars(w.week.apiEquivalentDollars)) API-equivalent")
    }
}

extension Diagnostics {
    /// `--selftest <name>`: import the current login as a profile, switch to it,
    /// and verify the live credential survived intact.
    static func selfTest(name: String) {
        do {
            let live = ProfileStore.activeCredentialPath(.codex)
            let before = try Data(contentsOf: live)
            try ProfileStore.importActive(.codex, as: name)
            print("imported profile '\(name)'")
            print("detected active profile: \(ProfileStore.activeProfileName(.codex) ?? "none")")

            try ProfileStore.activate(.codex, name: name)
            let after = try Data(contentsOf: live)
            print("credential intact after switch: \(before == after)")

            let attrs = try FileManager.default.attributesOfItem(atPath: live.path())
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            print(String(format: "live credential permissions: %o", perms))

            let backups = ProfileStore.backupsRoot.appending(path: "codex")
            let n = (try? FileManager.default.contentsOfDirectory(atPath: backups.path()))?.count ?? 0
            print("backups on disk: \(n)")
        } catch {
            print("FAILED: \(error.localizedDescription)")
        }
    }
}
