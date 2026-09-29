import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum ClaudeOAuthHarness {
    static func main() throws {
        let request = try ClaudeOAuth.refreshRequest(refreshToken: "refresh-one")
        expect(request.url?.absoluteString == "https://api.anthropic.com/v1/oauth/token",
               "refresh must use Anthropic API endpoint")
        expect(request.httpMethod == "POST", "refresh must use POST")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        expect(body?["grant_type"] == "refresh_token",
               "refresh request must use refresh_token grant")
        expect(body?["refresh_token"] == "refresh-one",
               "refresh request must carry the app-owned token")

        let existing = ClaudeOAuth.TokenSet(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: Date(timeIntervalSince1970: 1),
            scopes: ["user:profile"],
            subscriptionType: "max")
        let response = Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"scope":"user:profile user:inference"}"#.utf8)
        let decoded = try ClaudeOAuth.decodeRefreshResponse(
            data: response,
            statusCode: 200,
            existing: existing,
            now: Date(timeIntervalSince1970: 100))
        expect(decoded.accessToken == "new-access", "rotated access token must be retained")
        expect(decoded.refreshToken == "new-refresh", "rotated refresh token must be retained")
        expect(decoded.expiresAt == Date(timeIntervalSince1970: 3_700),
               "rotated expiry must be calculated from response")
        expect(decoded.scopes == ["user:profile", "user:inference"],
               "rotated scopes must be retained")

        // Reconnect aims the consent page at the broken card's account, the
        // same login_hint parameter Claude Code's own login sends.
        func query(_ url: URL) -> [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
        let hinted = ClaudeOAuth.begin(usesCallback: true, loginHint: "the@chaos.one")
        guard query(hinted.url)["login_hint"] == "the@chaos.one" else {
            fputs("FAIL: Reconnect sign-in does not name the account to sign in as\n", stderr)
            exit(1)
        }
        let plain = ClaudeOAuth.begin(usesCallback: true)
        guard query(plain.url)["login_hint"] == nil else {
            fputs("FAIL: a plain Add account should not force an account\n", stderr)
            exit(1)
        }

        // claude.ai ignores login_hint when the browser is already signed in
        // (a Reconnect for the@chaos.one approved as river@ultima.inc), so a
        // reconnect opens a private window that has no claude.ai session.
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let args = ClaudeOAuth.privateWindowOpenArguments(
            browserApp: chrome, url: hinted.url)
        guard args == ["-na", chrome.path, "--args", "--incognito", hinted.url.absoluteString] else {
            fputs("FAIL: Chrome reconnect does not open a private window: \(args)\n", stderr)
            exit(1)
        }
        guard ClaudeOAuth.privateWindowOpenArguments(
                  browserApp: URL(fileURLWithPath: "/Applications/Safari.app"),
                  url: hinted.url).isEmpty else {
            fputs("FAIL: browsers without a known private-window flag must fall back\n", stderr)
            exit(1)
        }

        print("PASS: app-owned Claude OAuth refresh protocol")
    }
}
