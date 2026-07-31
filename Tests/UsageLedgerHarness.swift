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
enum UsageLedgerHarness {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-meter-usage-ledger-\(UUID().uuidString)")
        let ledger = try UsageLedger.open(at: root.appendingPathComponent("usage.sqlite"))

        try ledger.upsert(event: .init(
            externalID: "claude:session-1:event-1",
            provider: .claude,
            accountID: "claude-account-a",
            timestamp: Date(timeIntervalSince1970: 1_785_000_000),
            inputTokens: 100,
            outputTokens: 25,
            cacheWriteTokens: 10,
            cacheReadTokens: 5,
            totalTokens: 140,
            source: "claude-transcript",
            attribution: .observedActiveSpan))
        try ledger.upsert(event: .init(
            externalID: "claude:session-1:event-1",
            provider: .claude,
            accountID: "claude-account-a",
            timestamp: Date(timeIntervalSince1970: 1_785_000_000),
            inputTokens: 100,
            outputTokens: 25,
            cacheWriteTokens: 10,
            cacheReadTokens: 5,
            totalTokens: 140,
            source: "claude-transcript",
            attribution: .observedActiveSpan))

        let totals = try ledger.totals(
            provider: .claude,
            accountID: "claude-account-a",
            start: Date(timeIntervalSince1970: 1_784_999_000),
            end: Date(timeIntervalSince1970: 1_785_001_000))
        expect(totals.inputTokens == 100, "duplicate events should be ignored")
        expect(totals.outputTokens == 25, "output tokens should be summed")
        expect(totals.cacheWriteTokens == 10, "cache write tokens should be retained")
        expect(totals.cacheReadTokens == 5, "cache read tokens should be retained")
        expect(totals.totalTokens == 140, "total tokens should be retained")

        try ledger.saveCheckpoint(source: "claude-transcript", cursor: "file.jsonl:128")
        let checkpoint = try ledger.checkpoint(source: "claude-transcript")
        expect(
            checkpoint?.cursor == "file.jsonl:128",
            "checkpoint cursor should round-trip")

        print("PASS: usage ledger")
    }
}
