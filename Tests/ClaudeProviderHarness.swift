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

        let rejected = ClaudeProvider.OAuthRefreshError.rejected("Refresh token expired")
        expect(
            rejected.localizedDescription
                == "AI Meter connection expired. Reconnect this Claude account.",
            "expired Claude profile refresh tokens should use reconnect copy")

        let credentialJSON = """
        {
          "claudeAiOauth": {
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "expiresAt": 1787169600000
          }
        }
        """
        let token = ClaudeProvider.decodeProfileToken(
            data: Data(credentialJSON.utf8))
        expect(token?.accessToken == "access-token",
               "Claude Code credential tokens should parse access tokens")
        expect(token?.refreshToken == "refresh-token",
               "Claude Code credential tokens should parse refresh tokens")
        expect(token?.expiresAt == Date(timeIntervalSince1970: 1_787_169_600),
               "Claude Code credential tokens should parse millisecond expiries")

        let capturedAt = Date(timeIntervalSince1970: 1_787_168_552)
        let statusline = """
        {
          "model": {"display_name": "Claude Sonnet"},
          "rate_limits": {
            "five_hour": {
              "used_percentage": 42,
              "resets_at": 1787170000
            },
            "seven_day": {
              "used_percentage": 18,
              "resets_at": "2026-08-25T09:59:59.851Z"
            }
          }
        }
        """
        let statuslineSnapshot = ClaudeProvider.decodeStatuslineSnapshot(
            data: Data(statusline.utf8),
            capturedAt: capturedAt)
        expect(statuslineSnapshot?.capturedAt == capturedAt,
               "statusline snapshots should retain capture time")
        expect(statuslineSnapshot?.windows.map(\.label) == ["5h", "Weekly"],
               "statusline rate limits should expose 5h and weekly windows")
        expect(statuslineSnapshot?.windows.first?.usedPercent == 42,
               "statusline 5h used percentage should be parsed")
        expect(
            statuslineSnapshot?.windows.first?.resetsAt
                == Date(timeIntervalSince1970: 1_787_170_000),
            "statusline Unix reset timestamps should become Dates")

        let pastBoundaryStatusline = """
        {
          "rate_limits": {
            "five_hour": {
              "used_percentage": 22,
              "resets_at": 1786900200
            }
          }
        }
        """
        let normalisedStatusline = ClaudeProvider.decodeStatuslineSnapshot(
            data: Data(pastBoundaryStatusline.utf8),
            capturedAt: Date(timeIntervalSince1970: 1_787_168_814))
        expect(
            normalisedStatusline?.windows.first?.resetsAt
                == Date(timeIntervalSince1970: 1_787_170_200),
            "fresh statusline 5h boundaries in the past should advance to the next reset")

        let fableStatusline = """
        {
          "model": {"id": "claude-fable-5", "display_name": "Fable 5"},
          "rate_limits": {
            "five_hour": {
              "used_percentage": 11,
              "resets_at": 1787184000
            },
            "seven_day": {
              "used_percentage": 48,
              "resets_at": 1787652000
            }
          }
        }
        """
        let fableStatuslineSnapshot = ClaudeProvider.decodeStatuslineSnapshot(
            data: Data(fableStatusline.utf8),
            capturedAt: capturedAt)
        expect(
            fableStatuslineSnapshot?.windows.map(\.label) == ["5h", "Fable wk"],
            "Fable statuslines should label seven_day as Fable weekly usage")

        let cachedFable = CachedSnapshot(
            accountID: "claude:active",
            capturedAt: capturedAt.addingTimeInterval(-60),
            plan: nil,
            windows: [
                .init(
                    label: "5h",
                    usedPercent: 99,
                    windowMinutes: 300,
                    resetsAt: capturedAt.addingTimeInterval(60)),
                .init(
                    label: "Weekly",
                    usedPercent: 27,
                    windowMinutes: 10_080,
                    resetsAt: capturedAt.addingTimeInterval(24 * 60 * 60)),
                .init(
                    label: "Fable wk",
                    usedPercent: 57,
                    windowMinutes: 10_080,
                    resetsAt: capturedAt.addingTimeInterval(6 * 24 * 60 * 60)),
            ])
        let merged = ClaudeProvider.mergeStatuslineSnapshot(
            statuslineSnapshot!,
            preservingModelWindowsFrom: cachedFable,
            now: capturedAt)
        expect(
            merged.windows.map(\.label) == ["5h", "Weekly", "Fable wk"],
            "statusline refresh should preserve cached model-scoped Claude windows")
        expect(
            merged.windows.first(where: { $0.label == "5h" })?.usedPercent == 42,
            "statusline 5h should replace stale cached 5h")
        expect(
            merged.windows.first(where: { $0.label == "Fable wk" })?.usedPercent == 57,
            "cached Fable should survive statusline refresh")

        let mergedFable = ClaudeProvider.mergeStatuslineSnapshot(
            fableStatuslineSnapshot!,
            preservingModelWindowsFrom: cachedFable,
            now: capturedAt)
        expect(
            mergedFable.windows.filter { $0.label == "Fable wk" }.count == 1,
            "fresh Fable statusline usage should replace cached Fable instead of duplicating it")
        expect(
            mergedFable.windows.first(where: { $0.label == "Weekly" })?.usedPercent == 27,
            "Fable statusline refresh should preserve cached generic Weekly usage")
        expect(
            mergedFable.windows.first(where: { $0.label == "Fable wk" })?.usedPercent == 48,
            "fresh Fable statusline usage should win over cached Fable")

        print("PASS: Claude provider usage parsing")
    }
}
