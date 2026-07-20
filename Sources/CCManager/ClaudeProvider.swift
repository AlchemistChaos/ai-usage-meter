import Foundation

/// Claude Code support: identity, live usage, and account switching.
///
/// Where things live (verified 2026-07-20):
///   • Credential: login keychain, service "Claude Code-credentials". That
///     service holds SEVERAL items — MCP-token-only items plus the real one
///     whose JSON contains `claudeAiOauth` (access/refresh token, plan tier).
///     A single-item lookup can land on the wrong one, so we enumerate all.
///   • Identity: `~/.claude.json` → `oauthAccount` (email, plan, org).
///   • Usage: `GET https://api.anthropic.com/api/oauth/usage` with the OAuth
///     bearer token — returns five_hour and seven_day utilization + reset times.
///
/// Keychain reads prompt for the login password once; because the app is
/// Developer-ID signed with a stable identity, "Always Allow" sticks.
enum ClaudeProvider {

    static let keychainService = "Claude Code-credentials"

    // MARK: - Credential

    struct Credential {
        /// Full JSON blob as stored (preserved for profile snapshots).
        let raw: Data
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        /// Keychain account attribute of the item that holds the OAuth blob,
        /// needed to update that same item when switching.
        let keychainAccount: String
    }

    /// In-memory cache so the keychain is touched once per launch, not per tick.
    private static var cachedCredential: Credential?
    private static var credentialLoadAttempted = false

    static func credential(forceReload: Bool = false) -> Credential? {
        if forceReload { cachedCredential = nil; credentialLoadAttempted = false }
        if credentialLoadAttempted { return cachedCredential }
        credentialLoadAttempted = true

        // Step 1: list item attributes only — this never triggers the password
        // dialog and tells us which accounts exist under the service.
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var listResult: CFTypeRef?
        guard SecItemCopyMatching(listQuery as CFDictionary, &listResult) == errSecSuccess,
              let items = listResult as? [[String: Any]]
        else { return nil }

        // Step 2: fetch data per item, so one denied item can't sink the rest.
        // Real credentials have been observed under the local username; try
        // those first to keep it to a single approval dialog.
        let all = items.compactMap { $0[kSecAttrAccount as String] as? String }
        let accounts = all.filter { $0 == NSUserName() } + all.filter { $0 != NSUserName() }
        for account in accounts {
            let dataQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var dataResult: CFTypeRef?
            guard SecItemCopyMatching(dataQuery as CFDictionary, &dataResult) == errSecSuccess,
                  let data = dataResult as? Data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = obj["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String
            else { continue }
            let expiresMs = oauth["expiresAt"] as? Double
            cachedCredential = Credential(
                raw: data,
                accessToken: token,
                expiresAt: expiresMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                subscriptionType: oauth["subscriptionType"] as? String,
                keychainAccount: account)
            return cachedCredential
        }
        return nil
    }

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

    // MARK: - Profiles / switching

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

    /// Snapshot the live keychain credential (plus identity) into a named profile.
    static func importActive(as name: String) throws {
        guard let cred = credential(forceReload: true) else {
            throw CCError.notLoggedIn(.claude)
        }
        guard var obj = try JSONSerialization.jsonObject(with: cred.raw) as? [String: Any] else {
            throw CCError.notLoggedIn(.claude)
        }
        // Stash identity alongside the token so the profile row can show
        // email/plan without activating it.
        if let id = identity() {
            obj["_ccmanagerIdentity"] = [
                "accountUuid": id.accountUuid,
                "email": id.email ?? "",
                "plan": id.plan ?? "",
            ]
        }
        let dest = profileFile(name)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: obj)
        try out.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: dest.path())
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

    /// Make a stored profile the live credential by updating the keychain item
    /// in place. Claude Code reads the keychain on each launch, so running
    /// sessions keep their old account until restarted.
    static func activate(name: String) throws {
        guard let data = try? Data(contentsOf: profileFile(name)),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CCError.missingProfile(name) }
        obj.removeValue(forKey: "_ccmanagerIdentity")

        guard let live = credential(forceReload: true) else {
            throw CCError.notLoggedIn(.claude)
        }

        // Only swap the OAuth block; keep the live item's MCP tokens and any
        // other keys intact — they belong to this machine, not the account.
        if let liveObj = try? JSONSerialization.jsonObject(with: live.raw) as? [String: Any] {
            var merged = liveObj
            merged["claudeAiOauth"] = obj["claudeAiOauth"]
            obj = merged
        }

        // Back up the current blob before overwriting it.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = ProfileStore.backupsRoot
            .appending(path: "claude").appending(path: "credentials-\(stamp).json")
        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try live.raw.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: backup.path())

        let newData = try JSONSerialization.data(withJSONObject: obj)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: live.keychainAccount,
        ]
        let update: [String: Any] = [kSecValueData as String: newData]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain update failed (status \(status))"])
        }
        _ = credential(forceReload: true)
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
        if let cred = credential() {
            let plan = cred.subscriptionType ?? "?"
            let exp = cred.expiresAt.map { $0 > Date() ? "valid" : "EXPIRED" } ?? "?"
            return Probe(foundOAuth: true,
                         detail: "OAuth credential in keychain (plan \(plan), token \(exp))")
        }
        return Probe(foundOAuth: false,
                     detail: "No claudeAiOauth item found in keychain")
    }
}
