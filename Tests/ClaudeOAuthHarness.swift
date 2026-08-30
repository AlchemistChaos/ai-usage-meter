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

        print("PASS: app-owned Claude OAuth refresh protocol")
    }
}
