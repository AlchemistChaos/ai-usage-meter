import Foundation
import LocalAuthentication
import Security

/// Claude Code support: the active account can use Claude Code's current
/// credential, while additional accounts are stored as app-owned profiles.
///
/// Identity of the CLI's current login is read (prompt-free) from
/// `~/.claude.json` → `oauthAccount`; usage comes from
/// `GET https://api.anthropic.com/api/oauth/usage`.
enum ClaudeProvider {
    static let reconnectAccountMessage =
        "AI Meter connection expired. Reconnect this Claude account."

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

    enum ProviderError: LocalizedError {
        case authenticationRequired(String)
        case rateLimited(String)
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .authenticationRequired(let message):
                return message.isEmpty
                    ? "Claude OAuth login expired. Re-authenticate this account."
                    : message
            case .rateLimited(let message):
                return message.isEmpty
                    ? "Claude usage is rate limited. Keeping the last reading."
                    : message
            case .requestFailed(let status, let message):
                return message.isEmpty
                    ? "Claude usage request failed with HTTP \(status)."
                    : message
            }
        }
    }

    /// Live poll of Anthropic's OAuth usage endpoint.
    static func fetchUsage(token: String) async throws -> [UsageWindow] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return try decodeUsageResponse(data: data, statusCode: http.statusCode)
    }

    static func decodeUsageResponse(data: Data, statusCode: Int) throws -> [UsageWindow] {
        guard statusCode == 200 else {
            let message = errorMessage(from: data)
            switch statusCode {
            case 401, 403:
                throw ProviderError.authenticationRequired(message)
            case 429:
                throw ProviderError.rateLimited(message)
            default:
                throw ProviderError.requestFailed(statusCode, message)
            }
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

        var windows = [
            window("five_hour", label: "5h", minutes: 300),
            window("seven_day", label: "Weekly", minutes: 10_080),
        ].compactMap { $0 }

        // The `limits` array additionally carries model-scoped caps (e.g. a
        // per-model weekly limit) that can be critical while the overall
        // weekly still looks fine — surface those too.
        if let limits = obj["limits"] as? [[String: Any]] {
            for l in limits {
                guard let kind = l["kind"] as? String,
                      kind != "session", kind != "weekly_all",  // already shown
                      let percent = l["percent"] as? Double,
                      let scope = l["scope"] as? [String: Any]
                else { continue }
                let model = (scope["model"] as? [String: Any])?["display_name"] as? String
                let resets = (l["resets_at"] as? String).flatMap { iso.date(from: $0) }
                let isWeekly = (l["group"] as? String) == "weekly"
                windows.append(UsageWindow(
                    label: "\(model ?? kind) \(isWeekly ? "wk" : "")"
                        .trimmingCharacters(in: .whitespaces),
                    usedPercent: percent,
                    windowMinutes: isWeekly ? 10_080 : 300,
                    resetsAt: resets))
            }
        }
        return windows
    }

    /// Where the capture hook files each reading under the account UUID that
    /// was logged in to the emitting Claude Code config dir at capture time.
    static func statuslineByAccountDirectory() -> URL {
        ProfileStore.root
            .appending(path: "claude-statusline")
            .appending(path: "by-account")
    }

    /// Credential-free usage for every account used in Claude Code, keyed by
    /// account UUID. Nothing here can expire or be revoked.
    static func statuslineSnapshotsByAccount(
        directory: URL = statuslineByAccountDirectory()
    ) -> [String: CodexProvider.Snapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: CodexProvider.Snapshot] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let capturedAt = CodexProvider.modificationDate(at: url),
                  let snapshot = decodeStatuslineSnapshot(data: data, capturedAt: capturedAt)
            else { continue }
            result[url.deletingPathExtension().lastPathComponent] = snapshot
        }
        return result
    }

    static func decodeStatuslineSnapshot(
        data: Data,
        capturedAt: Date
    ) -> CodexProvider.Snapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = obj["rate_limits"] as? [String: Any]
        else { return nil }
        func doubleValue(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            if let value = value as? String { return Double(value) }
            return nil
        }

        func dateValue(_ value: Any?) -> Date? {
            if let seconds = doubleValue(value) {
                let divisor = seconds > 10_000_000_000 ? 1000.0 : 1.0
                return Date(timeIntervalSince1970: seconds / divisor)
            }
            guard let string = value as? String else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: string)
        }

        func window(_ key: String, label: String, minutes: Int) -> UsageWindow? {
            guard let raw = rateLimits[key] as? [String: Any],
                  let used = doubleValue(
                    raw["used_percentage"] ?? raw["utilization"] ?? raw["percent"])
            else { return nil }
            var resetsAt = dateValue(raw["resets_at"])
            let interval = TimeInterval(minutes * 60)
            while let reset = resetsAt,
                  interval > 0,
                  reset <= capturedAt {
                resetsAt = reset.addingTimeInterval(interval)
            }
            return UsageWindow(
                label: label,
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: resetsAt)
        }

        let windows = [
            window("five_hour", label: "5h", minutes: 300),
            window("seven_day", label: "Weekly", minutes: 10_080),
        ].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return .init(windows: windows, plan: nil, capturedAt: capturedAt)
    }

    static func mergeStatuslineSnapshot(
        _ statusline: CodexProvider.Snapshot,
        preservingModelWindowsFrom cached: CachedSnapshot?,
        now: Date = Date()
    ) -> CodexProvider.Snapshot {
        let statuslineLabels = Set(statusline.windows.map(\.label))
        let preserved = cached?.projectedWindows(
            now: now,
            dropsExpiredWindows: true)
            .filter { !statuslineLabels.contains($0.label) } ?? []
        return .init(
            windows: statusline.windows + preserved,
            plan: statusline.plan ?? cached?.plan,
            capturedAt: statusline.capturedAt)
    }

    struct AccountUsage {
        let snapshot: CodexProvider.Snapshot?
        let failure: String?
        let needsReconnect: Bool
    }

    /// One Claude account's reading. A statusline reading needs no login, so
    /// it keeps the account healthy even when AI Meter's own login is dead;
    /// the live endpoint only adds fresher and model-scoped windows.
    static func accountUsage(
        statusline: CodexProvider.Snapshot?,
        endpoint: Result<[UsageWindow], Error>,
        cached: CachedSnapshot?,
        now: Date = Date()
    ) -> AccountUsage {
        switch (statusline, endpoint) {
        case (let reading?, .success(let windows)):
            return .init(
                snapshot: mergeUsageEndpointWindows(windows, into: reading, capturedAt: now),
                failure: nil, needsReconnect: false)
        case (let reading?, .failure):
            return .init(
                snapshot: mergeStatuslineSnapshot(
                    reading, preservingModelWindowsFrom: cached, now: now),
                failure: nil, needsReconnect: false)
        case (nil, .success(let windows)):
            return .init(
                snapshot: .init(windows: windows, plan: nil, capturedAt: now),
                failure: nil, needsReconnect: false)
        case (nil, .failure(let error)):
            let isAuth = isAuthenticationFailure(error)
            return .init(
                snapshot: nil,
                failure: isAuth ? reconnectAccountMessage : error.localizedDescription,
                needsReconnect: isAuth)
        }
    }

    static func mergeUsageEndpointWindows(
        _ endpointWindows: [UsageWindow],
        into snapshot: CodexProvider.Snapshot,
        capturedAt: Date = Date()
    ) -> CodexProvider.Snapshot {
        var endpointByLabel: [String: UsageWindow] = [:]
        for window in endpointWindows {
            endpointByLabel[window.label] = window
        }

        let snapshotLabels = Set(snapshot.windows.map(\.label))
        let merged = snapshot.windows.map { window in
            endpointByLabel[window.label] ?? window
        } + endpointWindows.filter {
            !snapshotLabels.contains($0.label)
        }

        return .init(
            windows: merged,
            plan: snapshot.plan,
            capturedAt: capturedAt)
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        if case ProviderError.authenticationRequired = error { return true }
        if case OAuthRefreshError.rejected = error { return true }
        if let urlError = error as? URLError,
           urlError.code == .userAuthenticationRequired {
            return true
        }
        return false
    }

    private static func errorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        if let message = obj["error_description"] as? String { return message }
        if let message = obj["message"] as? String { return message }
        if let error = obj["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let error = obj["error"] as? String { return error }
        return ""
    }

    // MARK: - Profiles

    static func profilesDir() -> URL { ClaudeProfileStore.profilesDirectory() }

    static func profileFile(_ name: String) -> URL {
        ClaudeProfileStore.credentialURL(accountUUID: name)
    }

    static func listProfiles() -> [String] {
        ClaudeProfileStore.list().map(\.identity.accountUUID)
    }

    struct StoredProfile {
        let name: String
        let accountUuid: String?
        let email: String?
        let plan: String?
    }

    static func storedProfile(_ name: String) -> StoredProfile {
        guard let record = ClaudeProfileStore.record(accountUUID: name)
        else { return StoredProfile(name: name, accountUuid: nil, email: nil, plan: nil) }
        return StoredProfile(
            name: name,
            accountUuid: record.identity.accountUUID,
            email: record.identity.email,
            plan: record.identity.plan)
    }

    // MARK: - Per-profile tokens (multi-account polling)

    /// Claude Code's public OAuth client id, needed for the refresh grant.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let claudeCodeKeychainService = "Claude Code-credentials"

    struct ProfileToken {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let accountUuid: String?
        var isExpired: Bool { expiresAt.map { $0 <= Date().addingTimeInterval(60) } ?? false }
    }

    enum OAuthRefreshError: LocalizedError {
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let message):
                return message.localizedCaseInsensitiveContains("expired")
                    ? ClaudeProvider.reconnectAccountMessage
                    : "AI Meter connection was rejected. Reconnect this Claude account."
            }
        }
    }

    static func profileToken(_ name: String) -> ProfileToken? {
        guard let data = try? Data(contentsOf: profileFile(name)) else { return nil }
        return decodeProfileToken(data: data)
    }

    static func decodeProfileToken(data: Data) -> ProfileToken? {
        guard
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

    static func claudeCodeCredentialsFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.credentials.json")
    }

    static func claudeCodeToken() -> ProfileToken? {
        if let keychainData = claudeCodeKeychainData(),
           let token = decodeProfileToken(data: keychainData) {
            return token
        }
        guard let data = try? Data(contentsOf: claudeCodeCredentialsFile()) else {
            return nil
        }
        return decodeProfileToken(data: data)
    }

    static func freshClaudeCodeToken() throws -> ProfileToken {
        guard let token = claudeCodeToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        guard !token.isExpired else {
            throw URLError(.userAuthenticationRequired)
        }
        return token
    }

    private static func claudeCodeKeychainData() -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Token for the active account: AI Meter's own chain first, then Claude
    /// Code's current credential (read-only, never refreshed) when that chain
    /// is dead. Only auth failures fall back; network errors surface as-is.
    static func activeUsageToken(
        profileToken: (() async throws -> ProfileToken)?,
        claudeCodeToken: () throws -> ProfileToken
    ) async throws -> ProfileToken {
        guard let profileToken else { return try claudeCodeToken() }
        do {
            return try await profileToken()
        } catch where isAuthenticationFailure(error) {
            guard let fallback = try? claudeCodeToken() else { throw error }
            return fallback
        }
    }

    /// Refresh only credentials created by AI Meter's independent OAuth flow.
    /// Legacy credentials may share Claude Code's refresh-token chain and stay
    /// strictly read-only.
    static func usableToken(for name: String) async throws -> ProfileToken {
        guard let tok = profileToken(name) else { throw CCError.missingProfile(name) }
        guard tok.isExpired else { return tok }
        guard let record = ClaudeProfileStore.record(accountUUID: name),
              record.origin == .appOAuth
        else { throw URLError(.userAuthenticationRequired) }

        let existing = ClaudeOAuth.TokenSet(
            accessToken: tok.accessToken,
            refreshToken: tok.refreshToken,
            expiresAt: tok.expiresAt ?? .distantPast,
            scopes: profileScopes(name),
            subscriptionType: nil)
        let refreshed = try await ClaudeOAuth.refresh(tokens: existing)
        guard var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: record.credentialURL)) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        var oauth = object["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = refreshed.accessToken
        oauth["refreshToken"] = refreshed.refreshToken ?? ""
        oauth["expiresAt"] = refreshed.expiresAt.timeIntervalSince1970 * 1_000
        oauth["scopes"] = refreshed.scopes
        object["claudeAiOauth"] = oauth
        let data = try JSONSerialization.data(withJSONObject: object)
        try ClaudeProfileStore.saveCredential(
            data,
            identity: record.identity,
            origin: .appOAuth)
        guard let persisted = profileToken(name) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return persisted
    }

    private static func profileScopes(_ name: String) -> [String] {
        guard let data = try? Data(contentsOf: profileFile(name)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any]
        else { return [] }
        if let scopes = oauth["scopes"] as? [String] { return scopes }
        if let scope = oauth["scope"] as? String {
            return scope.components(separatedBy: " ")
        }
        return []
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
