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
    static func main() async {
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
            fableStatuslineSnapshot?.windows.map(\.label) == ["5h", "Weekly"],
            "statusline seven_day should remain all-models weekly usage")

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
            "Fable statusline usage should not duplicate cached scoped Fable")
        expect(
            mergedFable.windows.first(where: { $0.label == "Weekly" })?.usedPercent == 48,
            "Fable statusline refresh should update generic Weekly usage")
        expect(
            mergedFable.windows.first(where: { $0.label == "Fable wk" })?.usedPercent == 57,
            "statusline refresh should preserve cached scoped Fable usage")

        let usageEndpointWindows = [
            UsageWindow(
                label: "5h",
                usedPercent: 51,
                windowMinutes: 300,
                resetsAt: capturedAt.addingTimeInterval(2 * 60 * 60)),
            UsageWindow(
                label: "Weekly",
                usedPercent: 58,
                windowMinutes: 10_080,
                resetsAt: capturedAt.addingTimeInterval(4 * 60 * 60)),
            UsageWindow(
                label: "Fable wk",
                usedPercent: 89,
                windowMinutes: 10_080,
                resetsAt: capturedAt.addingTimeInterval(4 * 60 * 60)),
        ]
        let mergedLiveUsage = ClaudeProvider.mergeUsageEndpointWindows(
            usageEndpointWindows,
            into: fableStatuslineSnapshot!)
        expect(
            mergedLiveUsage.windows.map(\.label) == ["5h", "Weekly", "Fable wk"],
            "live usage endpoint merge should retain standard and scoped windows")
        expect(
            mergedLiveUsage.windows.first(where: { $0.label == "Fable wk" })?.usedPercent == 89,
            "live usage endpoint should replace stale scoped Fable usage")

        // Per-account statusline readings: keyed by the account UUID the
        // capture hook recorded, never by whoever is logged in now.
        let byAccount = FileManager.default.temporaryDirectory
            .appending(path: "aimeter-by-account-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: byAccount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: byAccount) }
        func writeReading(_ name: String, _ body: String, modified: Date) {
            let url = byAccount.appending(path: name)
            try! Data(body.utf8).write(to: url)
            try! FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
        let readAt = Date(timeIntervalSince1970: 1_790_690_000)
        writeReading(
            "uuid-a.json",
            #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1790703600}}}"#,
            modified: readAt)
        writeReading(
            "uuid-b.json",
            #"{"rate_limits":{"seven_day":{"used_percentage":34,"resets_at":1791252000}}}"#,
            modified: readAt.addingTimeInterval(-3_600))
        writeReading("uuid-c.json", #"{"model":"no limits yet"}"#, modified: readAt)
        writeReading("uuid-d.json.123", #"{"rate_limits":{}}"#, modified: readAt)
        writeReading("notes.txt", "not json", modified: readAt)

        let readings = ClaudeProvider.statuslineSnapshotsByAccount(directory: byAccount)
        expect(Set(readings.keys) == ["uuid-a", "uuid-b"],
               "only complete per-account readings should be returned, keyed by UUID")
        expect(readings["uuid-a"]?.windows.first?.usedPercent == 12,
               "account A should keep its own reading")
        expect(readings["uuid-b"]?.windows.first?.label == "Weekly",
               "account B should keep its own reading")
        expect(readings["uuid-b"]?.capturedAt == readAt.addingTimeInterval(-3_600),
               "reading age should come from when the hook wrote it")
        expect(ClaudeProvider.statuslineSnapshotsByAccount(
                   directory: byAccount.appending(path: "missing")).isEmpty,
               "a missing by-account directory should mean no readings")

        // Active account: a dead AI Meter chain must fall back to Claude
        // Code's own (read-only) credential instead of failing.
        let cliToken = ClaudeProvider.ProfileToken(
            accessToken: "cli", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3_600), accountUuid: nil)
        let meterToken = ClaudeProvider.ProfileToken(
            accessToken: "meter", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3_600), accountUuid: nil)
        let dead: () async throws -> ClaudeProvider.ProfileToken = {
            throw ClaudeProvider.OAuthRefreshError.rejected("Refresh token expired")
        }
        let offline: () async throws -> ClaudeProvider.ProfileToken = {
            throw URLError(.notConnectedToInternet)
        }
        let fellBack = try? await ClaudeProvider.activeUsageToken(
            profileToken: dead, claudeCodeToken: { cliToken })
        expect(fellBack?.accessToken == "cli",
               "a dead AI Meter chain should fall back to Claude Code's credential")

        let preferred = try? await ClaudeProvider.activeUsageToken(
            profileToken: { meterToken }, claudeCodeToken: { cliToken })
        expect(preferred?.accessToken == "meter",
               "a working AI Meter chain should stay the first choice")

        let noProfile = try? await ClaudeProvider.activeUsageToken(
            profileToken: nil, claudeCodeToken: { cliToken })
        expect(noProfile?.accessToken == "cli",
               "no saved profile should use Claude Code's credential")

        var offlineError: Error?
        do {
            _ = try await ClaudeProvider.activeUsageToken(
                profileToken: offline, claudeCodeToken: { cliToken })
        } catch { offlineError = error }
        expect((offlineError as? URLError)?.code == .notConnectedToInternet,
               "network failures are not auth failures and must not be masked")

        var bothDead: Error?
        do {
            _ = try await ClaudeProvider.activeUsageToken(
                profileToken: dead,
                claudeCodeToken: { throw URLError(.userAuthenticationRequired) })
        } catch { bothDead = error }
        expect(bothDead.map(ClaudeProvider.isAuthenticationFailure) == true,
               "when both credentials are dead the auth failure should surface")

        // Per-account outcome: a statusline reading keeps the account healthy
        // even when AI Meter's own login is dead; without one, a dead login
        // asks for reconnect and other failures are reported as-is.
        let now = Date(timeIntervalSince1970: 1_790_695_000)
        let reading = CodexProvider.Snapshot(
            windows: [UsageWindow(label: "5h", usedPercent: 40, windowMinutes: 300,
                                  resetsAt: now.addingTimeInterval(3_600))],
            plan: nil, capturedAt: now.addingTimeInterval(-120))
        let endpoint = [
            UsageWindow(label: "5h", usedPercent: 41, windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3_600)),
            UsageWindow(label: "Fable wk", usedPercent: 7, windowMinutes: 10_080,
                        resetsAt: now.addingTimeInterval(86_400)),
        ]
        let authDead = ClaudeProvider.OAuthRefreshError.rejected("Refresh token expired")

        let coveredDead = ClaudeProvider.accountUsage(
            statusline: reading, endpoint: .failure(authDead), cached: nil, now: now)
        expect(coveredDead.snapshot?.windows.first?.usedPercent == 40,
               "a dead login must not hide the statusline reading")
        expect(coveredDead.failure == nil && !coveredDead.needsReconnect,
               "an account covered by the statusline must not show a dead-login error")

        let coveredLive = ClaudeProvider.accountUsage(
            statusline: reading, endpoint: .success(endpoint), cached: nil, now: now)
        expect(coveredLive.snapshot?.windows.map(\.label) == ["5h", "Fable wk"],
               "a live endpoint should add model-scoped windows to the reading")
        expect(coveredLive.snapshot?.windows.first?.usedPercent == 41,
               "a live endpoint reading should replace the older statusline value")

        let uncoveredLive = ClaudeProvider.accountUsage(
            statusline: nil, endpoint: .success(endpoint), cached: nil, now: now)
        expect(uncoveredLive.snapshot?.capturedAt == now && uncoveredLive.failure == nil,
               "an endpoint-only account should be read live")

        let uncoveredDead = ClaudeProvider.accountUsage(
            statusline: nil, endpoint: .failure(authDead), cached: nil, now: now)
        expect(uncoveredDead.snapshot == nil && uncoveredDead.needsReconnect,
               "an endpoint-only account with a dead login should ask to reconnect")
        expect(uncoveredDead.failure == ClaudeProvider.reconnectAccountMessage,
               "a dead login should use the reconnect copy")

        let uncoveredOffline = ClaudeProvider.accountUsage(
            statusline: nil, endpoint: .failure(URLError(.notConnectedToInternet)),
            cached: nil, now: now)
        expect(uncoveredOffline.failure != nil && !uncoveredOffline.needsReconnect,
               "a network failure is not a reason to reconnect")

        print("PASS: Claude provider usage parsing")
    }
}
