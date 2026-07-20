import Foundation
import CryptoKit

/// The OAuth login flow Claude Code itself uses (PKCE, code-paste variant):
/// open claude.ai/oauth/authorize in the browser, the user approves and gets a
/// "code#state" string to paste back, and we exchange it for tokens at
/// console.anthropic.com. Tokens are stored per profile so every account can be
/// polled for limits independently.
enum ClaudeOAuth {

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    struct PendingLogin {
        let url: URL
        let verifier: String
        let state: String
    }

    /// Build the authorize URL with a fresh PKCE pair.
    static func begin() -> PendingLogin {
        let verifier = randomURLSafe(64)
        let state = randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
        c.queryItems = [
            .init(name: "code", value: "true"),  // code-paste flow, no local server
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return PendingLogin(url: c.url!, verifier: verifier, state: state)
    }

    struct TokenSet {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
        let scopes: [String]
        let subscriptionType: String?
    }

    /// Exchange the pasted "code#state" for tokens.
    static func exchange(pasted: String, login: PendingLogin) async throws -> TokenSet {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        let code = String(parts[0])
        let state = parts.count > 1 ? String(parts[1]) : login.state

        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": login.verifier,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ClaudeOAuth", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Login code rejected: \(body.prefix(120))"])
        }
        let account = obj["account"] as? [String: Any]
        return TokenSet(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            expiresAt: Date().addingTimeInterval((obj["expires_in"] as? Double) ?? 3600),
            scopes: (obj["scope"] as? String)?.components(separatedBy: " ") ?? [],
            subscriptionType: account?["subscription_type"] as? String
                ?? obj["subscription_type"] as? String)
    }

    struct Profile {
        let accountUuid: String
        let email: String?
        let plan: String?
    }

    /// Ask who this token belongs to, so the profile can be labelled.
    static func fetchProfile(token: String) async throws -> Profile {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["account"] as? [String: Any],
              let uuid = account["uuid"] as? String
        else { throw URLError(.badServerResponse) }

        var plan: String?
        if let org = obj["organization"] as? [String: Any] {
            if let type = org["organization_type"] as? String {
                plan = type.replacingOccurrences(of: "claude_", with: "")
            }
            if let tier = org["rate_limit_tier"] as? String,
               let mult = tier.split(separator: "_").last, mult.hasSuffix("x") {
                plan = "\(plan ?? "") \(mult)".trimmingCharacters(in: .whitespaces)
            }
        }
        return Profile(accountUuid: uuid, email: account["email"] as? String, plan: plan)
    }

    /// Save a fresh login as a stored profile (same shape as imported ones).
    static func saveProfile(name: String, tokens: TokenSet, profile: Profile) throws {
        let obj: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": tokens.accessToken,
                "refreshToken": tokens.refreshToken ?? "",
                "expiresAt": tokens.expiresAt.timeIntervalSince1970 * 1000,
                "scopes": tokens.scopes,
                "subscriptionType": tokens.subscriptionType ?? "",
            ],
            "_ccmanagerIdentity": [
                "accountUuid": profile.accountUuid,
                "email": profile.email ?? "",
                "plan": profile.plan ?? "",
            ],
        ]
        let dest = ClaudeProvider.profileFile(name)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: obj)
        try out.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: dest.path())
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return Data(buf).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
