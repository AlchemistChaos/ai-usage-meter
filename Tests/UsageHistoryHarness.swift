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

@main
enum UsageHistoryHarness {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-meter-history-\(UUID().uuidString)")
        let ledger = try UsageLedger.open(at: root.appendingPathComponent("usage.sqlite"))

        let start = ISO8601DateFormatter().date(from: "2026-07-31T08:00:00Z")!
        try ledger.upsert(event: .init(
            externalID: "codex:r1",
            provider: .codex,
            accountID: "codex-a",
            timestamp: start,
            inputTokens: 100,
            outputTokens: 20,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 120,
            source: "codex-sse",
            attribution: .observedActiveSpan))
        try ledger.upsert(event: .init(
            externalID: "codex:r2",
            provider: .codex,
            accountID: "codex-a",
            timestamp: start.addingTimeInterval(3600),
            inputTokens: 50,
            outputTokens: 10,
            cacheWriteTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 60,
            source: "codex-sse",
            attribution: .observedActiveSpan))

        let query = UsageHistoryQuery(ledger: ledger)
        let hourly = try query.series(
            provider: .codex,
            accountID: "codex-a",
            preset: .last24Hours,
            now: ISO8601DateFormatter().date(from: "2026-07-31T12:00:00Z")!)
        expect(hourly.points.count == 24, "24h preset should emit 24 hourly buckets")
        expect(hourly.points.contains(where: { $0.inputTokens == 100 }), "hourly series should include first bucket")
        expect(hourly.points.contains(where: { $0.inputTokens == 50 }), "hourly series should include second bucket")

        let snapshot = try query.snapshot(
            provider: .codex,
            accountID: "codex-a",
            now: ISO8601DateFormatter().date(from: "2026-07-31T12:00:00Z")!)
        expect(snapshot.today.inputTokens == 150, "today total should sum both rows")
        expect(snapshot.last24Hours.inputTokens == 150, "24h total should sum both rows")

        print("PASS: usage history query")
    }
}
