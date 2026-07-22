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
    _ operation: () throws -> Void
) {
    do {
        try operation()
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    } catch {}
}

@main
enum CodexRateLimitClientHarness {
    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let snapshot = try await CodexRateLimitClient.fetchSnapshot()
            for window in snapshot.windows {
                print("LIVE: \(window.label) \(window.usedPercent)% used")
            }
            return
        }

        expect(CodexRateLimitClient.appServerArguments
               == ["app-server", "--listen", "stdio://"],
               "client should launch the stdio app-server transport")

        let requests = String(
            decoding: CodexRateLimitClient.requestPayload(), as: UTF8.self)
        let requestLines = requests.split(separator: "\n")
        expect(requestLines.count == 2,
               "app-server exchange should contain two requests")
        expect(requestLines[0].contains(#""id":1"#)
               && requestLines[0].contains(#""method":"initialize""#),
               "first request should initialize the app server")
        expect(requestLines[1].contains(#""id":2"#)
               && requestLines[1].contains(
                   #""method":"account/rateLimits/read""#),
               "second request should fetch account rate limits")

        let capturedAt = Date(timeIntervalSince1970: 1_784_730_000)
        let response = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":76,"windowDurationMins":10080,"resetsAt":1785258211},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"pro","rateLimitReachedType":null},"rateLimitsByLimitId":{},"rateLimitResetCredits":null}}"#
        let snapshot = try CodexRateLimitClient.decodeSnapshot(
            from: Data(response.utf8), capturedAt: capturedAt)
        expect(snapshot?.capturedAt == capturedAt,
               "snapshot should retain its capture time")
        expect(snapshot?.plan == "pro", "plan type should be retained")
        expect(snapshot?.windows.count == 1,
               "null secondary window should be omitted")
        expect(snapshot?.windows.first?.label == "Weekly",
               "10,080 minutes should be labelled Weekly")
        expect(snapshot?.windows.first?.windowMinutes == 10_080,
               "window duration should be retained")
        expect(snapshot?.windows.first?.usedPercent == 76,
               "used percentage should be retained")
        expect(snapshot?.windows.first?.remainingPercent == 24,
               "remaining percentage should match current Codex status")
        expect(snapshot?.windows.first?.resetsAt
               == Date(timeIntervalSince1970: 1_785_258_211),
               "Unix reset timestamp should become a Date")

        let stream = """
        {"id":1,"result":{"userAgent":"test"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
        \(response)

        """
        let streamSnapshot = try CodexRateLimitClient.decodeSnapshot(
            fromStream: Data(stream.utf8), capturedAt: capturedAt)
        expect(streamSnapshot?.windows.first?.usedPercent == 76,
               "stream decoding should select response ID 2")

        let notification = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":75}}}}"#
        let notificationSnapshot = try CodexRateLimitClient.decodeSnapshot(
            from: Data(notification.utf8), capturedAt: capturedAt)
        expect(notificationSnapshot == nil,
            "notifications should not be mistaken for the requested response")

        let initializeResponse = #"{"id":1,"result":{"userAgent":"test"}}"#
        let initializeSnapshot = try CodexRateLimitClient.decodeSnapshot(
            from: Data(initializeResponse.utf8), capturedAt: capturedAt)
        expect(initializeSnapshot == nil,
            "initialize response should be ignored")

        expectThrows("malformed JSON should throw") {
            _ = try CodexRateLimitClient.decodeSnapshot(
                from: Data("{".utf8), capturedAt: capturedAt)
        }

        let errorResponse = #"{"id":2,"error":{"code":-32000,"message":"not authenticated"}}"#
        expectThrows("matching JSON-RPC errors should throw") {
            _ = try CodexRateLimitClient.decodeSnapshot(
                from: Data(errorResponse.utf8), capturedAt: capturedAt)
        }

        print("PASS: Codex app-server rate-limit parsing")
    }
}
