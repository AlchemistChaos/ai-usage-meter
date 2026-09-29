import Foundation
import CryptoKit
import Network

/// The OAuth login flow Claude Code itself uses (PKCE, code-paste variant):
/// open claude.ai/oauth/authorize in the browser, the user approves and gets a
/// "code#state" string to paste back, and we exchange it for tokens at
/// console.anthropic.com. Tokens are stored per profile so every account can be
/// polled for limits independently.
enum ClaudeOAuth {

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Claude Code's registered loopback redirect — same one `claude login` uses.
    static let callbackPort: UInt16 = 54545
    static var redirectURI: String { "http://localhost:\(callbackPort)/callback" }
    /// Paste-flow redirect, kept as fallback if the local port is taken.
    static let pasteRedirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    struct PendingLogin {
        let url: URL
        let verifier: String
        let state: String
        /// True when a localhost listener is waiting for the redirect;
        /// false means the user must paste the code manually.
        let usesCallback: Bool
    }

    /// Build the authorize URL with a fresh PKCE pair. `loginHint` names the
    /// account to sign in as (Claude Code's own login sends the same param).
    static func begin(usesCallback: Bool, loginHint: String? = nil) -> PendingLogin {
        let verifier = randomURLSafe(64)
        let state = randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: usesCallback ? redirectURI : pasteRedirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        if !usesCallback { items.insert(.init(name: "code", value: "true"), at: 0) }
        if let loginHint, !loginHint.isEmpty {
            items.append(.init(name: "login_hint", value: loginHint))
        }
        c.queryItems = items
        return PendingLogin(url: c.url!, verifier: verifier, state: state,
                            usesCallback: usesCallback)
    }

    // MARK: - Loopback callback server (the `claude login` experience)

    /// Minimal one-shot HTTP listener that waits for the OAuth redirect,
    /// hands back code+state, and shows a "you can close this tab" page.
    final class CallbackServer {
        private var listener: NWListener?
        private var connections: [NWConnection] = []
        private let onCode: (String, String) -> Void

        init?(onCode: @escaping (String, String) -> Void) {
            self.onCode = onCode
            guard let port = NWEndpoint.Port(rawValue: callbackPort),
                  let l = try? NWListener(using: .tcp, on: port) else { return nil }
            listener = l
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: .main)
        }

        private func handle(_ conn: NWConnection) {
            connections.append(conn)
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
                [weak self] data, _, _, _ in
                guard let self, let data,
                      let request = String(data: data, encoding: .utf8) else { return }
                self.respond(conn, request: request)
            }
        }

        private func respond(_ conn: NWConnection, request: String) {
            // "GET /callback?code=...&state=... HTTP/1.1"
            var found: (code: String, state: String)?
            if let path = request.split(separator: " ").dropFirst().first,
               path.hasPrefix("/callback"),
               let comps = URLComponents(string: String(path)) {
                let q = { (n: String) in comps.queryItems?.first { $0.name == n }?.value }
                if let code = q("code") { found = (code, q("state") ?? "") }
            }

            let body = found != nil
                ? "<h2>Signed in ✓</h2><p>You can close this tab and return to the menu bar app.</p>"
                : "<h2>Waiting for login…</h2>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
                + "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'>"
                + body + "</body></html>"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            if let f = found { onCode(f.code, f.state) }
        }

        func stop() {
            listener?.cancel()
            listener = nil
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
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

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": login.usesCallback ? redirectURI : pasteRedirectURI,
            "code_verifier": login.verifier,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else {
            let body = errorDescription(from: data)
            throw NSError(domain: "ClaudeOAuth", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Claude login exchange failed: \(body.prefix(180))"])
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

    static func refreshRequest(refreshToken: String) throws -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        return request
    }

    static func decodeRefreshResponse(
        data: Data,
        statusCode: Int,
        existing: TokenSet,
        now: Date = Date()
    ) throws -> TokenSet {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard statusCode == 200,
              let accessToken = object?["access_token"] as? String
        else {
            throw ClaudeProvider.OAuthRefreshError.rejected(errorDescription(from: data))
        }
        let scope = object?["scope"] as? String
        return TokenSet(
            accessToken: accessToken,
            refreshToken: object?["refresh_token"] as? String ?? existing.refreshToken,
            expiresAt: now.addingTimeInterval(
                (object?["expires_in"] as? Double) ?? 3_600),
            scopes: scope?.components(separatedBy: " ") ?? existing.scopes,
            subscriptionType: (object?["account"] as? [String: Any])?["subscription_type"] as? String
                ?? object?["subscription_type"] as? String
                ?? existing.subscriptionType)
    }

    static func refresh(tokens: TokenSet) async throws -> TokenSet {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        let request = try refreshRequest(refreshToken: refreshToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return try decodeRefreshResponse(
            data: data, statusCode: http.statusCode, existing: tokens)
    }

    private static func errorDescription(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return String(data: data, encoding: .utf8) ?? "" }
        if let description = obj["error_description"] as? String {
            return description
        }
        if let error = obj["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let error = obj["error"] as? String {
            return error
        }
        return String(data: data, encoding: .utf8) ?? ""
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
    static func saveProfile(tokens: TokenSet, profile: Profile) throws {
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
        let out = try JSONSerialization.data(withJSONObject: obj)
        try ClaudeProfileStore.saveCredential(
            out,
            identity: .init(
                accountUUID: profile.accountUuid,
                email: profile.email,
                plan: profile.plan),
            origin: .appOAuth)
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
