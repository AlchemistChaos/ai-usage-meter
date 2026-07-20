import Foundation

/// Claude Code support: accounts are added via the in-app OAuth login and
/// stored as app-owned profiles — the macOS keychain is never touched.
///
/// Identity of the CLI's current login is read (prompt-free) from
/// `~/.claude.json` → `oauthAccount`; usage comes from
/// `GET https://api.anthropic.com/api/oauth/usage` per stored token.
enum ClaudeProvider {

    // MARK: - Identity

    struct Identity {
        let accountUuid: String
        let email: String?
        let plan: String?
    }

    /// Who the current login belongs to, read (prompt-free) from ~/.claude.json.
    static func identity() -> Identity? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oa = obj["oauthAccount"] as? [String: Any],
              let uuid = oa["accountUuid"] as? String
        else { return nil }
        var plan: String?
        if let type = oa["organizationType"] as? String {
            // e.g. "claude_max" (+ rate tier "default_claude_max_5x" → "max 5x")
            plan = type.replacingOccurrences(of: "claude_", with: "")
            if let tier = oa["organizationRateLimitTier"] as? String,
               let mult = tier.split(separator: "_").last, mult.hasSuffix("x") {
                plan = "\(plan!) \(mult)"
            }
        }
        return Identity(
            accountUuid: uuid,
            email: oa["emailAddress"] as? String,
            plan: plan)
    }

    // MARK: - Usage

    /// Live poll of Anthropic's OAuth usage endpoint.
    static func fetchUsage(token: String) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw URLError(.cannotParseResponse) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func window(_ key: String, label: String, minutes: Int) -> UsageWindow? {
            guard let w = obj[key] as? [String: Any],
                  let used = w["utilization"] as? Double else { return nil }
            let resets = (w["resets_at"] as? String).flatMap { iso.date(from: $0) }
            return UsageWindow(
                label: label, usedPercent: used,
                windowMinutes: minutes, resetsAt: resets)
        }

        return [
            window("five_hour", label: "5h", minutes: 300),
            window("seven_day", label: "Weekly", minutes: 10_080),
        ].compactMap { $0 }
    }

    // MARK: - Profiles

    static func profilesDir() -> URL { ProfileStore.profilesDir(.claude) }

    static func profileFile(_ name: String) -> URL {
        profilesDir().appending(path: name).appending(path: "credentials.json")
    }

    static func listProfiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profilesDir().path())) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .filter { FileManager.default.fileExists(atPath: profileFile($0).path()) }
            .sorted()
    }

    struct StoredProfile {
        let name: String
        let accountUuid: String?
        let email: String?
        let plan: String?
    }

    static func storedProfile(_ name: String) -> StoredProfile {
        guard let data = try? Data(contentsOf: profileFile(name)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["_ccmanagerIdentity"] as? [String: String]
        else { return StoredProfile(name: name, accountUuid: nil, email: nil, plan: nil) }
        return StoredProfile(
            name: name,
            accountUuid: id["accountUuid"],
            email: id["email"].flatMap { $0.isEmpty ? nil : $0 },
            plan: id["plan"].flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - Per-profile tokens (multi-account polling)

    /// Claude Code's public OAuth client id, needed for the refresh grant.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    struct ProfileToken {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let accountUuid: String?
        var isExpired: Bool { expiresAt.map { $0 <= Date().addingTimeInterval(60) } ?? false }
    }

    static func profileToken(_ name: String) -> ProfileToken? {
        guard let data = try? Data(contentsOf: profileFile(name)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        return ProfileToken(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            accountUuid: (obj["_ccmanagerIdentity"] as? [String: String])?["accountUuid"])
    }

    /// Get a working access token for a stored profile, refreshing via OAuth
    /// if it has expired. A refresh rotates the refresh token too, so the new
    /// pair is persisted back into the profile file immediately — losing it
    /// would strand the account.
    static func freshToken(for name: String) async throws -> ProfileToken {
        guard let tok = profileToken(name) else { throw CCError.missingProfile(name) }
        guard tok.isExpired else { return tok }
        guard let refresh = tok.refreshToken else {
            throw URLError(.userAuthenticationRequired)
        }

        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": oauthClientID,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = obj["access_token"] as? String
        else { throw URLError(.userAuthenticationRequired) }

        let newRefresh = obj["refresh_token"] as? String ?? refresh
        let expiresAt = Date().addingTimeInterval((obj["expires_in"] as? Double) ?? 3600)

        // Persist the rotated pair into the profile file.
        if var stored = try? JSONSerialization.jsonObject(
            with: Data(contentsOf: profileFile(name))) as? [String: Any],
           var oauth = stored["claudeAiOauth"] as? [String: Any] {
            oauth["accessToken"] = newAccess
            oauth["refreshToken"] = newRefresh
            oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
            stored["claudeAiOauth"] = oauth
            if let out = try? JSONSerialization.data(withJSONObject: stored) {
                try? out.write(to: profileFile(name), options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: profileFile(name).path())
            }
        }

        return ProfileToken(
            accessToken: newAccess, refreshToken: newRefresh,
            expiresAt: expiresAt, accountUuid: tok.accountUuid)
    }

    // MARK: - Probe (diagnostics)

    struct Probe {
        let foundOAuth: Bool
        let detail: String
    }

    static func probe() -> Probe {
        let n = listProfiles().count
        return Probe(foundOAuth: n > 0, detail: "\(n) logged-in account(s) stored by the app")
    }
}
