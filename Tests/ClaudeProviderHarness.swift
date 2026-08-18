import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func expectThrows(
    _ message: String,
    _ operation: () throws -> Void,
    verify: (Error) -> Bool
) {
    do {
        try operation()
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    } catch {
        expect(verify(error), message)
    }
}

@main
enum ClaudeProviderHarness {
    static func main() {
        let ok = """
        {
          "five_hour": {"utilization": 0.0, "resets_at": null},
          "seven_day": {"utilization": 63.0, "resets_at": "2026-08-19T10:59:59.757681+00:00"},
          "limits": [
            {"kind": "session", "group": "session", "percent": 0, "resets_at": null, "scope": {}},
            {"kind": "weekly_all", "group": "weekly", "percent": 63, "resets_at": "2026-08-19T10:59:59.757681+00:00", "scope": {}},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 100, "resets_at": "2026-08-19T10:59:59.757898+00:00", "scope": {"model": {"display_name": "Fable"}}}
          ]
        }
        """
        let windows = try! ClaudeProvider.decodeUsageResponse(
            data: Data(ok.utf8),
            statusCode: 200)
        expect(windows.map(\.label) == ["5h", "Weekly", "Fable wk"],
               "usage decoder should retain standard and model-scoped windows")

        let rateLimited = """
        {"error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}
        """
        expectThrows(
            "429 usage polling should be a transient provider error, not an auth failure",
            {
                _ = try ClaudeProvider.decodeUsageResponse(
                    data: Data(rateLimited.utf8),
                    statusCode: 429)
            },
            verify: { error in
                !ClaudeProvider.isAuthenticationFailure(error)
                    && error.localizedDescription.contains("Rate limited")
            })

        let expired = """
        {"type":"error","error":{"type":"authentication_error","message":"OAuth access token has expired. Re-authenticate to continue."}}
        """
        expectThrows(
            "401 usage polling should be classified as an auth failure",
            {
                _ = try ClaudeProvider.decodeUsageResponse(
                    data: Data(expired.utf8),
                    statusCode: 401)
            },
            verify: { error in
                ClaudeProvider.isAuthenticationFailure(error)
                    && error.localizedDescription.contains("Re-authenticate")
            })

        print("PASS: Claude provider usage parsing")
    }
}
